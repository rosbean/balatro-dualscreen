-- balatro-dualscreen-thor -- controller navigation for the hand on screen 2.
--
-- WHY THIS EXISTS. Vanilla navigates the hand by focusing card nodes out of
-- G.DRAW_HASH. The hand is deliberately kept OUT of that hash, because
-- leaving it in made invisible cards touchable at their old screen-1
-- positions. So screen-1 focus navigation has nothing to land on and card
-- selection by controller stops working. Putting the cards back is not an
-- option -- that is the phantom-touch bug.
--
-- So this keeps its own cursor over the hand and feeds the SAME semantic
-- events the touch path uses. One handler for "select card 3", whichever
-- device asked.
--
-- THE DIVISION OF LABOUR, which is the part to get right:
--
--   left / right        ours    -- move the hand cursor
--   A                   ours    -- stage / unstage the focused card
--   X                   ours    -- play hand
--   Y                   ours    -- discard
--   up / down           VANILLA -- so the player can still reach screen-1 UI
--   B and everything    VANILLA -- back/cancel keeps its normal meaning
--
-- An earlier version gated on `G.CONTROLLER.focused.target == nil`, reasoning
-- that we should only act when the game's focus was idle. On hardware that is
-- never true -- something on screen 1 always holds focus -- so nothing was
-- ever consumed. Left/right did nothing and B fell through to vanilla's
-- deselect. Hence the explicit split above: we own the horizontal axis and the
-- action buttons, vanilla keeps the vertical axis and cancel.
--
-- INPUT ARRIVES BY MORE THAN ONE ROUTE. On this device the D-pad is delivered
-- as KEYBOARD arrow keys rather than gamepad buttons, and the analog stick as
-- axis events. All three routes are handled, because which one a given pad
-- uses is not knowable in advance.

local gamepad = {}

gamepad.cursor = 1

-- Does the hand cursor own horizontal navigation right now?
--
-- Since panel-drawn nodes became pressable, VANILLA focus
-- navigation genuinely works on jokers, consumables, pack cards -- and on the
-- hand cards themselves, which are in G.MOVEABLES and pass is_node_focusable
-- (`node.area == G.hand`, controller.lua:1090). Two navigation systems were
-- now live at once, and the result was two selections on screen: the
-- stick moved vanilla's focus onto a joker or a second hand card while this
-- module's cursor stayed lit on its own card.
--
-- So ownership is now explicit, one owner at a time:
--
--   engaged       this module owns left/right and A; vanilla's focus target
--                 is kept clear.
--   disengaged    vanilla owns everything; our cursor shows nothing.
--
-- HANDOVERS, all in sync_focus and the input hooks:
--   * vanilla focus MOVES to a non-hand node  -> disengage (the player
--     navigated up/away with the stick).
--   * vanilla focus LANDS on a hand card      -> adopt it: our cursor takes
--     its rank and vanilla's focus is cleared (the player came back down).
--   * the d-pad presses left/right            -> force re-engage. The d-pad
--     is the hand's home input and must never feel dead.
--
-- Change-detected, not presence-detected: something on screen 1 can hold a
-- stale focus target for long stretches (the cursor parked over a focusable),
-- and disengaging on mere existence made the hand cursor unusable.
gamepad.engaged = true

-- OFF for release. This gates the axis dump below, which logs ~2.5 lines a
-- second -- discovery instrumentation from working out this pad's stick
-- mapping, and the loudest thing in logcat by a distance.
--
-- Kept rather than deleted, because the next person with a different
-- controller will need exactly it. Set true, rebuild, and every axis, hat and
-- button is dumped as you move them.
gamepad.DEBUG = false

local function log(msg)
    if gamepad.DEBUG and DS and DS.log then DS.log("gamepad: " .. tostring(msg)) end
end

local function in_hand_context()
    return DS and DS.active
       and G and G.STAGE == G.STAGES.RUN
       and G.hand and G.hand.cards and #G.hand.cards > 0
       and not G.OVERLAY_MENU
       and not (G.SETTINGS and G.SETTINGS.paused)
end

function gamepad.clamp()
    local n = (G and G.hand and G.hand.cards) and #G.hand.cards or 0
    if n == 0 then
        gamepad.cursor = 1
        return
    end
    if gamepad.cursor < 1 then gamepad.cursor = n end
    if gamepad.cursor > n then gamepad.cursor = 1 end
end

--- The card the controller cursor is over, or nil.
function gamepad.focused_card()
    if not in_hand_context() then return nil end
    gamepad.clamp()
    return G.hand.cards[gamepad.cursor], gamepad.cursor
end

--- Move the cursor and drive the GAME'S OWN focus/hover, rather than drawing
--- an indicator of our own.
---
--- Card:hover (card.lua:4306) does all of it: juice_up for the flash, the
--- paper1 sound, focused_ui via G.UIDEF.card_focus_ui when states.focus.is is
--- set, and the tooltip via G.UIDEF.card_h_popup + Node.hover. Replicating any
--- of that by hand would drift from the game; asking the game to do it cannot.
local function set_focus(card, on)
    if not card then return end
    if card.states and card.states.focus then
        card.states.focus.is = on and true or false
    end
    if on then
        if card.hover then pcall(card.hover, card) end
    else
        if card.stop_hover then pcall(card.stop_hover, card) end
    end
end

local function move(delta)
    local prev = gamepad.focused_card()
    gamepad.cursor = gamepad.cursor + delta
    gamepad.clamp()
    local now = gamepad.focused_card()
    if prev ~= now then
        set_focus(prev, false)
        set_focus(now, true)
    end
    log("cursor -> " .. gamepad.cursor)
end

--- Take ownership: our cursor becomes the one selection on screen.
--- Clearing vanilla's focus target is what prevents the double indicator.
function gamepad.engage()
    gamepad.engaged = true
    local c = G and G.CONTROLLER
    local vt = c and c.focused and c.focused.target
    if vt and vt.states and vt.states.focus then
        vt.states.focus.is = false
    end
    if c and c.focused then c.focused.target = nil end
end

-- Vanilla's focus target as of the last tick, for change detection.
local last_vt = nil

--- Per-tick reconciler: negotiate ownership with vanilla's focus, then keep
--- exactly one visual selection alive.
function gamepad.sync_focus()
    local c = G and G.CONTROLLER
    local vt = c and c.focused and c.focused.target or nil

    if vt ~= last_vt then
        last_vt = vt
        if vt and in_hand_context() then
            if vt.area == G.hand then
                -- Vanilla navigated onto a hand card: adopt it. Our cursor
                -- takes over at that card and vanilla's focus is cleared, so
                -- the selection stays singular through the handover.
                for i, cd in ipairs(G.hand.cards) do
                    if cd == vt then gamepad.cursor = i break end
                end
                if vt.states and vt.states.focus then
                    vt.states.focus.is = false
                end
                c.focused.target = nil
                last_vt = nil
                gamepad.engaged = true
            else
                -- Vanilla's focus moved somewhere real -- the player
                -- navigated away from the hand. Stand down.
                gamepad.engaged = false
            end
        end
    end

    local using_pad = c and c.HID and c.HID.controller
    local card = (using_pad and gamepad.engaged) and gamepad.focused_card() or nil
    if card == gamepad._focused then
        return
    end
    set_focus(gamepad._focused, false)
    gamepad._focused = card
    set_focus(card, true)
end

--------------------------------------------------------------------------
-- HOLD A TO CARRY A CARD, left/right to move it.
--
-- Vanilla has no controller reordering at all -- it is a mouse/touch gesture
-- only -- but drag-to-reorder matters mechanically, because hand order decides
-- scoring. With the hand on screen 2 and the pad as the primary input, leaving
-- it out would make the pad strictly worse than the touchscreen.
--
-- HOW THE ORDER IS STORED. CardArea:align_cards assigns each card's T.x FROM
-- ITS ARRAY INDEX and then sorts by T.x (cardarea.lua:455 then :448), so the
-- array order is the hand order and swapping T.x alone achieves nothing -- the
-- next align overwrites it. That is why the TOUCH drag works differently: a
-- dragged card is skipped by that loop (`if not card.states.drag.is`), keeps
-- the x the finger gave it, and the sort picks up the new position. For a
-- discrete swap the array is the thing to change.
--
-- A is press-and-release rather than press-to-act, so one button can do both
-- jobs: release without having moved is a stage/unstage, release after moving
-- is the end of a carry.
--------------------------------------------------------------------------

local a_held = false
local a_moved = false

--- Swap the focused card with its neighbour and keep the cursor on it.
local function carry(delta)
    local cards = G and G.hand and G.hand.cards
    if not cards then return false end
    local i = gamepad.cursor
    local j = i + delta
    if j < 1 or j > #cards then return false end

    cards[i], cards[j] = cards[j], cards[i]
    gamepad.cursor = j
    if G.hand.align_cards then pcall(G.hand.align_cards, G.hand) end
    log(("carried card %d -> %d"):format(i, j))
    return true
end

local function act(name, arg)
    local events = require("dualscreen.events")
    log(name .. " at cursor " .. gamepad.cursor)
    events.dispatch({ name = name, arg = arg })
end

--- Shared handler. `code` is already normalised to one of
--- left / right / a / x / y. Returns true if consumed.
local function handle(code)
    if not in_hand_context() then
        return false
    end
    -- Disengaged: vanilla owns navigation and the press. Only X and Y stay
    -- ours -- play/discard are global actions, not selections.
    if not gamepad.engaged and (code == "left" or code == "right" or code == "a") then
        return false
    end
    gamepad.clamp()

    if code == "left" then
        if a_held then a_moved = carry(-1) or a_moved else move(-1) end
        return true
    elseif code == "right" then
        if a_held then a_moved = carry(1) or a_moved else move(1) end
        return true
    elseif code == "a" then
        -- Press only ARMS the carry. The stage/unstage happens on release, and
        -- only if the card was not moved -- see gamepad.released.
        a_held, a_moved = true, false
        return true
    elseif code == "x" then
        act("PLAY_HAND"); return true
    elseif code == "y" then
        act("DISCARD_HAND"); return true
    end
    return false
end

--- love.gamepadpressed route.
function gamepad.pressed(button)
    log("gamepadpressed " .. tostring(button))
    local code =
        (button == "dpleft"  and "left")  or
        (button == "dpright" and "right") or
        (button == "a" and "a") or
        (button == "x" and "x") or
        (button == "y" and "y") or nil
    if not code then return false end
    -- The d-pad's horizontal is the hand's home input: it re-engages the hand
    -- cursor no matter where vanilla's focus wandered.
    if (code == "left" or code == "right") and in_hand_context() then
        gamepad.engage()
    end
    return handle(code)
end

--- Route for synthetic dpleft/dpright presses -- the analog stick, which
--- vanilla converts to button presses in handle_axis_buttons. Called from the
--- Controller:button_press_update wrap in init.lua. Deliberately does NOT
--- force-engage: the stick is also how the player navigates the rest of the
--- UI, so when disengaged it stays vanilla's.
function gamepad.route(code)
    return handle(code)
end

--- Does the hand cursor currently own horizontal presses?
function gamepad.owns_horizontal()
    return gamepad.engaged and in_hand_context()
end

--- Release route. A that never moved a card is an ordinary stage/unstage.
function gamepad.released(button)
    if button ~= "a" then return false end
    local was_held, moved = a_held, a_moved
    a_held, a_moved = false, false
    if not was_held then return false end
    if not in_hand_context() or not gamepad.engaged then return false end
    if moved then
        log("carry ended")
        return true
    end
    -- 0-based over the wire, so touch and pad share one handler.
    act("TOGGLE_CARD", tostring(gamepad.cursor - 1))
    return true
end

--- love.keypressed route. This device delivers the D-pad as arrow keys.
function gamepad.keypressed(key)
    local code =
        (key == "left"  and "left")  or
        (key == "right" and "right") or nil
    if not code then return false end
    log("keypressed " .. tostring(key))
    -- This device's d-pad arrives as arrow keys; same home-input rule as the
    -- real-button route above.
    if in_hand_context() then
        gamepad.engage()
    end
    return handle(code)
end

--- Unconditional axis dump. Runs before ANY gating, because an earlier
--- version sat behind in_hand_context() and logged nothing whenever the player
--- was not already in a dealt hand -- which is exactly when you are trying to
--- discover the mapping.
function gamepad.dump_axes()
    if not gamepad.DEBUG then return end

    -- HEARTBEAT. Logs once a second no matter what, so "no output" can be told
    -- apart from "this function is never called" -- which is the ambiguity that
    -- has cost several rounds here.
    local t = love.timer.getTime()
    if not gamepad._hb or t - gamepad._hb > 1.0 then
        gamepad._hb = t
        local src = "none"
        local pad0 = G and G.CONTROLLER and G.CONTROLLER.GAMEPAD and G.CONTROLLER.GAMEPAD.object
        if pad0 then src = "CONTROLLER.GAMEPAD.object" end
        if not pad0 then
            for _, j in ipairs(love.joystick and love.joystick.getJoysticks() or {}) do
                if j:isGamepad() then pad0 = j; src = "getJoysticks fallback" break end
            end
        end
        local lx = "n/a"
        if pad0 and pad0.getGamepadAxis then
            local okx, v = pcall(pad0.getGamepadAxis, pad0, "leftx")
            if okx then lx = string.format("%.2f", v) end
        end
        log(("HB pad=%s src=%s leftx=%s hand=%s active=%s")
            :format(tostring(pad0 ~= nil), src, lx,
                    tostring(in_hand_context()), tostring(DS and DS.active)))
    end

    local pad = G and G.CONTROLLER and G.CONTROLLER.GAMEPAD and G.CONTROLLER.GAMEPAD.object
    if not pad then
        for _, j in ipairs(love.joystick and love.joystick.getJoysticks() or {}) do
            if j:isGamepad() then pad = j break end
        end
    end
    if not pad then return end

        local moved, parts = false, {}
        local n = pad.getAxisCount and pad:getAxisCount() or 0
        for i = 1, n do
            local okr, v = pcall(pad.getAxis, pad, i)
            if okr and type(v) == "number" then
                if math.abs(v) > 0.5 then moved = true end
                parts[#parts + 1] = ("raw%d=%.2f"):format(i, v)
            end
        end
        for _, nm in ipairs({ "leftx", "lefty", "rightx", "righty",
                              "triggerleft", "triggerright" }) do
            local okn, v = pcall(pad.getGamepadAxis, pad, nm)
            if okn and type(v) == "number" then
                if math.abs(v) > 0.5 then moved = true end
                parts[#parts + 1] = ("%s=%.2f"):format(nm, v)
            end
        end
        local hats = {}
        local hn = pad.getHatCount and pad:getHatCount() or 0
        for i = 1, hn do
            local okh, h = pcall(pad.getHat, pad, i)
            if okh then
                hats[#hats + 1] = ("hat%d=%s"):format(i, tostring(h))
                if h and h ~= "c" then moved = true end
            end
        end
        if moved and (not gamepad._last_dump or
                      love.timer.getTime() - gamepad._last_dump > 0.4) then
            gamepad._last_dump = love.timer.getTime()
            log("AXES " .. table.concat(parts, " ") ..
                (#hats > 0 and ("  " .. table.concat(hats, " ")) or ""))
        end
end

--- The analog stick needs no polling here any more.
---
--- poll_axis is retired. Vanilla already converts stick deflection
--- into dpleft/dpright button presses every frame (update_axis ->
--- handle_axis_buttons, controller.lua:561-573), and those now arrive at this
--- module through the Controller:button_press_update wrap in init.lua. Polling
--- the axis here AS WELL meant one stick flick was handled twice -- once by
--- us, once by vanilla's conversion -- which is precisely the "second
--- selection appears when moving left/right on the stick" report.

return gamepad
