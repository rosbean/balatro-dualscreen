-- balatro-dualscreen-thor -- act on semantic events from screen 2.
--
-- the wire table. Java never injects synthetic input; it sends meaning, and
-- this maps meaning onto the globals Balatro already exposes on G.FUNCS.
--
--   TOGGLE_CARD   index      G.hand:add_to_highlighted / remove_from_highlighted
--   PLAY_HAND     -          G.FUNCS.play_cards_from_highlighted
--   DISCARD_HAND  -          G.FUNCS.discard_cards_from_highlighted
--   SORT_RANK     -          G.FUNCS.sort_hand_value
--   SORT_SUIT     -          G.FUNCS.sort_hand_suit
--
-- Generation matching happens before this: bridge.poll_events() drops any
-- event whose generation does not match the current snapshot's.

local events = {}

local function in_run()
    return G and G.STAGE == G.STAGES.RUN and G.hand and G.hand.cards
end

local function log(msg)
    if DS and DS.log then DS.log("events: " .. tostring(msg)) end
end

local handlers = {}

handlers.TOGGLE_CARD = function(arg)
    if not in_run() then
        return false
    end
    local index = tonumber(arg)
    if not index then
        return false
    end
    -- Java indexes from 0, Lua from 1.
    local card = G.hand.cards[index + 1]
    if not card then
        log("TOGGLE_CARD out of range: " .. tostring(index))
        return false
    end

    local highlighted = false
    for _, h in ipairs(G.hand.highlighted or {}) do
        if h == card then highlighted = true break end
    end

    if highlighted then
        G.hand:remove_from_highlighted(card)
    else
        -- add_to_highlighted enforces the 5-card cap itself
        -- (cardarea.lua:142), so do not second-guess it here.
        G.hand:add_to_highlighted(card)
    end
    return true
end

--- Dragging a card around the panel.
---
--- Vanilla lets you pick a card up and move it about -- no mechanical purpose,
--- it is just a pleasant toy. Moveable:drag (engine/moveable.lua:217) does this
--- by reading G.CONTROLLER.cursor_position, which is SCREEN 1 space and would
--- move the real cursor, so instead we do what drag itself ultimately does:
--- set T.x/T.y directly, from the finger position converted into tile space.
---
--- states.drag.is drives the scale bump at moveable.lua:424, so setting it
--- gives the same "picked up" feel the game does.
local dragging = nil

handlers.DRAG_CARD = function(arg)
    if not in_run() then return false end
    -- arg is "index:x:y" in screen-2 pixels.
    local idx, px, py = tostring(arg):match("^(%d+)|(-?%d+)|(-?%d+)$")
    if not idx then return false end
    idx, px, py = tonumber(idx), tonumber(px), tonumber(py)

    -- Resolve by index ONLY on the first event of a drag, then hold the card
    -- OBJECT for the rest of it.
    --
    -- CardArea:align_cards re-sorts the hand by x position every time it runs
    -- (cardarea.lua:448) -- that IS the reorder mechanic. So the moment a drag
    -- carries a card past its neighbour, every index shifts. Continuing to
    -- resolve by index mid-drag means grabbing whichever card now occupies that
    -- slot, which is exactly the glitching seen: the drag jumps between cards.
    local card = dragging
    if not card then
        card = G.hand.cards[idx + 1]
        if not card then return false end
        dragging = card
        if card.states then card.states.drag.is = true end
    end

    local render = require("dualscreen.render")
    local tx, ty = render.panel_to_tile(px, py, DS.panel_w or 0, DS.panel_h or 0)
    if not tx then return false end

    -- Centre the card on the finger.
    card.T.x = tx - card.T.w / 2
    card.T.y = ty - card.T.h / 2
    return true
end

handlers.DRAG_END = function()
    if dragging then
        if dragging.states then dragging.states.drag.is = false end
        dragging = nil
    end
    -- align_cards springs the hand back into its fan, which is exactly what
    -- vanilla does when you let go.
    if in_run() and G.hand.align_cards then
        pcall(G.hand.align_cards, G.hand)
    end
    return true
end

--- Touch hover, so holding a finger on a card shows its tooltip.
---
--- Card:hover (card.lua:4306) builds the tooltip via G.UIDEF.card_h_popup and
--- Node.hover, and also plays the paper1 sound and the juice_up flash -- the
--- same call the controller path uses. Note card.lua:4315 gates the popup on
--- `not self.states.drag.is or G.CONTROLLER.HID.touch`, so a popup while
--- dragging requires touch mode; holding still is the normal case anyway.
local hovering = nil

local function set_hover(card, on)
    if not card then return end
    if on then
        if card.hover then pcall(card.hover, card) end
    else
        if card.stop_hover then pcall(card.stop_hover, card) end
    end
end

--- Hover by COORDINATE, resolved through the screen-2 hash.
---
--- Replaces the old index-into-G.hand version. That only ever worked for the
--- hand, so once the shop and booster packs moved down, touching one of their
--- cards produced no tooltip -- while the controller, which drives Card:hover
--- through its own focus, showed the full description. Same information, only
--- available to one input device.
---
--- Resolving through DS.hit_test makes it work for every relocated card area
--- at once, exactly as CLICK does, and the hand keeps working because its
--- cards are in the same hash.
handlers.HOVER_AT = function(arg)
    local px, py = tostring(arg):match("^(-?%d+)|(-?%d+)$")
    if not px then return false end

    -- A finger on the panel is touch input; say so before anything reads the
    -- flag. See DS.mark_touch_input.
    DS.mark_touch_input()

    -- The HOVER predicate, not the click one: see DS.hover_test.
    local node = DS.hover_test(tonumber(px), tonumber(py))

    -- Walk up to the Card, if the tap landed on one of its children.
    -- `ability` is present on every Card and on nothing else we hit-test.
    local card, guard = node, 0
    while card and card.ability == nil and guard < 8 do
        card = card.parent
        guard = guard + 1
    end
    if card and card.ability == nil then card = nil end

    -- Not a card? Hover the node itself. hover_test guarantees it CAN hover;
    -- the concrete case is the skip TAGS on blind select, whose sprite
    -- installs its own hover that builds the tooltip (tag.lua:513) -- the
    -- controller was the only input that could reach it. A node with a
    -- hover.can but no tooltip (container rows advertise it too) gets a
    -- harmless no-op hover, same as vanilla's mouse would give it.
    if not card and node and node.hover then
        card = node
    end

    if card == hovering then return false end
    set_hover(hovering, false)
    hovering = card
    set_hover(card, true)
    return card ~= nil
end

handlers.HOVER_END = function()
    if not hovering then return false end
    set_hover(hovering, false)
    hovering = nil
    return true
end

--- A generic tap, resolved against the screen-2 draw hash.
---
--- Replaces the four hardcoded button rects. Java no longer decides WHAT was
--- tapped -- it reports WHERE, and DS.click_at resolves it through the same
--- collision walk the controller uses on screen 1, then calls the node's own
--- click(). Anything drawn on screen 2 is therefore clickable on screen 2
--- without further plumbing, which is what makes moving the shop and the menus
--- down tractable at all.
---
--- Deliberately NOT gated on in_run(): the point is that this also works at the
--- main menu, in the shop and in a booster pack. DS.click_at is itself gated on
--- DS.active and on the hash being non-empty.
handlers.CLICK = function(arg)
    local px, py = tostring(arg):match("^(-?%d+)|(-?%d+)$")
    if not px then return false end
    return DS.click_at(tonumber(px), tonumber(py)) and true or false
end

handlers.PLAY_HAND = function()
    if not in_run() or not G.FUNCS or not G.FUNCS.play_cards_from_highlighted then
        return false
    end
    if #(G.hand.highlighted or {}) < 1 then
        return false
    end
    G.FUNCS.play_cards_from_highlighted()
    return true
end

handlers.DISCARD_HAND = function()
    if not in_run() or not G.FUNCS or not G.FUNCS.discard_cards_from_highlighted then
        return false
    end
    if #(G.hand.highlighted or {}) < 1 then
        return false
    end
    G.FUNCS.discard_cards_from_highlighted()
    return true
end

handlers.SORT_RANK = function()
    if not in_run() or not G.FUNCS or not G.FUNCS.sort_hand_value then
        return false
    end
    G.FUNCS.sort_hand_value()
    return true
end

handlers.SORT_SUIT = function()
    if not in_run() or not G.FUNCS or not G.FUNCS.sort_hand_suit then
        return false
    end
    G.FUNCS.sort_hand_suit()
    return true
end

--- Dispatch one event. Returns true if it mutated the hand, so the caller
--- knows to bump the generation and push a fresh snapshot.
function events.dispatch(ev)
    local h = handlers[ev.name]
    if not h then
        log("unknown event: " .. tostring(ev.name))
        return false
    end

    -- pcall so a bad event can never take the game down. Screen 2 is an
    -- input surface; a malformed message from it is a bug to log, not a crash.
    local ok, changed = pcall(h, ev.arg)
    if not ok then
        log(("handler %s errored: %s"):format(tostring(ev.name), tostring(changed)))
        return false
    end
    if changed then
        log(("%s%s applied"):format(ev.name,
            (ev.arg ~= nil and ev.arg ~= "") and (" " .. tostring(ev.arg)) or ""))
    end
    return changed and true or false
end

return events
