-- balatro-dualscreen-thor -- read the game's hand state into a snapshot.
--
-- Reads only. Nothing here mutates the game; the write side is events.lua.
--
-- Every field is guarded, because set_screen_positions and love.update both
-- run in states where G.hand, G.GAME.current_round and friends do not exist.
-- The null path is needed from the
-- very first adjustment, not eventually.

local snapshot = {}

-- Card:set_edition builds a table with a `type` field ('foil' / 'holo' /
-- 'polychrome' / 'negative'), so read that rather than probing booleans.
local function edition_of(card)
    local e = card.edition
    if type(e) ~= "table" then
        return "none"
    end
    return e.type or "none"
end

local function enhancement_of(card)
    -- The enhancement centre's key, e.g. m_mult / m_gold. config.center_key is
    -- maintained by Card:set_ability.
    local key = card.config and card.config.center_key
    if type(key) ~= "string" or key == "" then
        return "none"
    end
    return key
end

local function is_highlighted(hand, card)
    for _, h in ipairs(hand.highlighted or {}) do
        if h == card then
            return true
        end
    end
    return false
end

--- Which display mode screen 2 should be in, and whether the hand belongs on
--- it.
---
--- The test is NOT "are we in a run". The hand is live in more states than
--- SELECTING_HAND: booster packs let you apply a card to cards in hand
--- (cardarea.lua:436 gives the hand its own layout for TAROT_PACK,
--- SPECTRAL_PACK and PLANET_PACK), and PLAY_TAROT is the same idea outside a
--- pack. Treating those as "not a run" would blank screen 2 exactly when the
--- player needs to pick a card.
---
--- Everything else gets BLACK. A deliberate blank beats a stale hand -- which
--- is precisely the failure Banjo's dedupe rule warns about, and what screen 2
--- did in the shop before this.
local HAND_LIVE = {
    SELECTING_HAND = true,
    DRAW_TO_HAND   = true,
    HAND_PLAYED    = true,   -- cards still animating out of the hand
    PLAY_TAROT     = true,
    TAROT_PACK     = true,
    PLANET_PACK    = true,
    SPECTRAL_PACK  = true,
    STANDARD_PACK  = true,
    BUFFOON_PACK   = true,
    NEW_ROUND      = true,
}

--- Reverse-lookup the current state's name, so the table above can be written
--- in readable terms rather than magic numbers that would silently rot if
--- LocalThunk ever renumbers G.STATES.
---
--- MEMOISED, and it has to be. This is a linear scan over G.STATES, which was
--- fine when hand_is_live() was called once per frame -- but the section
--- registry routes
--- the screen-1 suppression test through sections.owns(), which runs for every
--- drawn object on every frame. That turned one scan per frame into a scan per
--- object per frame, roughly 6000 a second at ~50 objects and 119 fps.
---
--- The result depends only on G.STATE, so caching it by that value is exact,
--- not an approximation.
local state_name_cache = {}

local function state_name()
    if not G or not G.STATE or not G.STATES then return nil end
    local cached = state_name_cache[G.STATE]
    if cached ~= nil then
        return cached
    end
    for name, value in pairs(G.STATES) do
        if value == G.STATE then
            state_name_cache[G.STATE] = name
            return name
        end
    end
    return nil
end

snapshot.state_name = state_name

--- True when screen 2 should show the hand at all.
function snapshot.hand_is_live()
    if not G or G.STAGE ~= G.STAGES.RUN then return false end
    local name = state_name()
    return name ~= nil and HAND_LIVE[name] == true
end

--- Any of the five booster-pack states.
function snapshot.is_pack_state()
    if not G or not G.STATE or not G.STATES then return false end
    return G.STATE == G.STATES.TAROT_PACK
        or G.STATE == G.STATES.SPECTRAL_PACK
        or G.STATE == G.STATES.PLANET_PACK
        or G.STATE == G.STATES.STANDARD_PACK
        or G.STATE == G.STATES.BUFFOON_PACK
end

function snapshot.display_mode()
    if not G or not G.STAGE then
        return "BLACK"
    end
    if G.STAGE == G.STAGES.MAIN_MENU then
        return "MENU"
    end
    if G.STAGE ~= G.STAGES.RUN then
        return "BLACK"
    end
    if snapshot.hand_is_live() then
        return "RUN"
    end
    -- Named rather than lumped into BLACK so the companion can say something
    -- useful, and so later work has the distinction available.
    local name = state_name()
    if name == "SHOP" then return "SHOP" end
    if name == "BLIND_SELECT" then return "BLIND_SELECT" end
    if name == "ROUND_EVAL" then return "ROUND_EVAL" end
    if name == "GAME_OVER" then return "GAME_OVER" end
    return "BLACK"
end

--- Build the current snapshot. Never throws; returns a minimal table if the
--- game is in a state with no hand.
--- `rects` is an optional list of {x,y,w,h} in screen-2 pixel space, produced
--- by render.card_rects(). Under route (b) LOVE renders the hand, so Lua is
--- the only side that knows where each card ended up; Java hit-tests these.
function snapshot.build(generation, rects)
    local snap = {
        generation = generation or 0,
        mode = snapshot.display_mode(),
        hands = 0,
        discards = 0,
        can_play = false,
        can_discard = false,
        cards = {},
    }

    local round = G and G.GAME and G.GAME.current_round
    if round then
        snap.hands = round.hands_left or 0
        snap.discards = round.discards_left or 0
    end

    local hand = G and G.hand
    if not hand or not hand.cards then
        return snap
    end

    local selected = 0
    for i, card in ipairs(hand.cards) do
        local hl = is_highlighted(hand, card)
        if hl then
            selected = selected + 1
        end
        snap.cards[i] = {
            rank = (card.base and card.base.value) or "?",
            suit = (card.base and card.base.suit) or "?",
            enhancement = enhancement_of(card),
            edition = edition_of(card),
            seal = card.seal or "none",
            highlighted = hl,
        }
        local rect = rects and rects[i]
        if rect then
            snap.cards[i].x, snap.cards[i].y = rect.x, rect.y
            snap.cards[i].w, snap.cards[i].h = rect.w, rect.h
        else
            snap.cards[i].x, snap.cards[i].y = 0, 0
            snap.cards[i].w, snap.cards[i].h = 0, 0
        end
    end

    snap.can_play = selected > 0 and snap.hands > 0
    snap.can_discard = selected > 0 and snap.discards > 0

    return snap
end

--- Cheap signature used to decide whether anything actually changed.
--- Deliberately excludes card positions and any time-varying term: the ambient
--- sway in cardarea.lua means the hand is NEVER visually static, so a
--- position-sensitive signature would fire every frame (ADR 0001).
function snapshot.signature(snap)
    local parts = {
        snap.mode, tostring(snap.hands), tostring(snap.discards),
        tostring(#snap.cards),
    }
    for _, c in ipairs(snap.cards) do
        parts[#parts + 1] = c.rank .. c.suit .. c.edition .. c.seal
                            .. (c.highlighted and "*" or ".")
    end
    return table.concat(parts, "/")
end

return snapshot
