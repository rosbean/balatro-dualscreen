-- balatro-dualscreen-thor -- the top screen's layout.
--
-- WRAP, DO NOT REPLACE. Nothing here reimplements vanilla's positioning -- it
-- reads the values vanilla just wrote and moves them. A future upstream change
-- to the landscape layout is inherited rather than overwritten.
--
-- Reference (functions/common_events.lua:1-27, vanilla 1.0.1o):
--   hand         x = TILE_W - hand.w - 2.85    y = TILE_H - hand.h
--   play         x = centred on hand           y = hand.y - 3.6
--   jokers       x = hand.x - 0.1              y = 0
--   consumeables x = jokers.x + jokers.w + 0.2 y = 0
--   deck         x = TILE_W - deck.w - 0.5     y = TILE_H - deck.h
--   discard      x = jokers.x + jokers.w/2 + 15.3   y = 4.2
--
-- TWO KINDS OF ADJUSTMENT LIVE HERE, and the split is deliberate:
--
--   * EVENT adjustments (adjust/restore), run from the set_screen_positions
--     wrapper: the play-area drop and the discard-pile move. Vanilla rewrites
--     those transforms itself on every relayout, so re-applying on the same
--     events it uses is correct and cheap.
--
--   * RECONCILED state (reconcile), run EVERY TICK during a run: the joker
--     row's size and the consumables' screen-1 position. These went through
--     five event-driven versions -- pre_restore / restore / per-tick sizing /
--     event-only placement -- and every missed or mis-ordered event produced a
--     stale layout somewhere (a vanilla-sized joker row at the
--     first blind select of a new run). A per-tick reconciler computes the
--     desired state from (settings, game state) and converges on it no matter
--     which events fired or in what order. Every write is behind a tolerance
--     check, so a quiet tick costs comparisons only.

local layout = {}

-- The play area is moved down during hand play: it is the focus during
-- scoring and there is real freed space beneath the jokers for it to occupy.
-- (The joker/consumable TOP ROW is deliberately NOT moved -- a 1.6-tile drop
-- was tried and read as simply too low.)
local PLAY_DROP = 2.4

-- Gap between the joker row and the consumables when they sit beneath it.
local CONSUMABLE_GAP = 0.25

-- Ceiling on the joker scale. 1.45 was tried and is far too much:
-- the cards overflowed the top of the screen and dwarfed everything else.
local JOKER_SCALE_MAX = 1.18

-- Margin held between the joker row and the RIGHT EDGE OF THE ROOM, in tiles.
-- Chosen to match the gap on the left of the side panel, so the two sides of
-- the screen balance. The row runs to the room edge because nothing shares
-- that band -- the deck sits BELOW it, not beside it.
local ROOM_RIGHT_MARGIN = 0.7

--------------------------------------------------------------------------
-- The reconciler.
--------------------------------------------------------------------------

--- Drop a CardArea's translucent backing so the next draw rebuilds it.
---
--- The backing (children.area_uibox) is a SNAPSHOT, not a follower: CardArea
--- builds it lazily on first draw with its dimensions as literals
--- (`minw = self.T.w`, cardarea.lua:294) and an alignment that align_to_major
--- only re-derives when the alignment PARAMETERS change -- it is
--- change-detected on its own offset/type, not on the major's position
--- (moveable.lua:127). So resizing or moving the area updates the cards and
--- the collision box while the visible band stays where and how big it was
--- created -- which is exactly "the toggle only applies next run" and "the
--- consumables area is still beside the row": the transform moved, the
--- rectangle did not.
---
--- Removing it is safe -- it contains only its own label elements, no game
--- objects -- and CardArea:draw recreates it on the next frame through
--- vanilla's own construction, at the current size and spot.
local function drop_backing(area)
    local ab = area.children and area.children.area_uibox
    if ab then
        pcall(ab.remove, ab)
        area.children.area_uibox = nil
    end
end

-- Vanilla dimensions, captured PER AREA INSTANCE. G.jokers is a fresh
-- CardArea every run; keying the capture to the instance means a new run can
-- never inherit a stale capture, and the first sight of each instance is
-- always its untouched vanilla state (T.w is set once at creation,
-- game.lua:2243, before anything of ours runs).
local cap = nil

-- Vanilla dimensions PER CARD, same first-sight principle, weak keys so a
-- sold or destroyed card cannot be kept alive by its entry.
--
-- NOT EVERY JOKER IS CARD-SIZED BY DESIGN: Wee Joker, Half Joker
-- and Square Joker ship with their own smaller boxes. The old loop assigned
-- one uniform w x h to every card in the row, which blew the deliberately
-- small ones up to full size -- wrong in the widened row AND quietly wrong in
-- the vanilla-width row, where scale is 1 and the assignment forced them to
-- cap.card_w anyway. Multiplying each card's OWN captured dimensions by the
-- row's scale keeps every card's designed proportion and its size relative to
-- its neighbours, at any row scale.
local card_base = setmetatable({}, { __mode = "k" })

-- Designed-small cards take only HALF the row's enlargement (the square root
-- -- half the zoom in log space). Strictly proportional scaling still read
-- wrong: a Wee Joker at 0.7 x the enlarged size is bigger
-- in absolute terms than the vanilla Wee Joker the eye is calibrated to, and
-- a Square Joker widened past a vanilla card's width read as overflowing the
-- row. The enlargement exists to make STANDARD cards more readable; a card
-- that is small on purpose needs less of it, and none of it at scale 1.
local function card_scale(base, std_w, std_h, scale)
    if scale > 1 and (base.w < std_w * 0.95 or base.h < std_h * 0.95) then
        return math.sqrt(scale)
    end
    return scale
end

--- Converge the joker row and the consumables' screen-1 position on the
--- state the settings ask for. Called every tick during a run.
function layout.reconcile()
    if not G or not G.STAGES or G.STAGE ~= G.STAGES.RUN then return end
    local j, c = G.jokers, G.consumeables
    if not j or not j.T or not c or not c.T then return end

    if not cap or cap.area ~= j then
        cap = {
            area   = j,
            w      = j.T.w,
            h      = j.T.h,
            card_w = j.card_w or G.CARD_W,
            card_h = G.CARD_H,
        }
    end

    local settings = require("dualscreen.settings")
    local snapshot = require("dualscreen.snapshot")

    -- The row's size and the consumables' screen are INDEPENDENT choices.
    -- "Larger joker area" alone decides the width -- it applies whether the
    -- consumables are on screen 2 or sitting underneath the row on screen 1.
    -- DS.active keeps the null path: no companion display, pure vanilla.
    local wide = DS.active and settings.larger_jokers()

    -- The joker row: vanilla, or grown to the room edge with its cards scaled
    -- to fill the space. Card size tracks the LIVE card_limit, so slot-count
    -- changes (vouchers, negative jokers) re-derive the scale by themselves.
    local want_w, scale = cap.w, 1
    if wide then
        local tw = G.TILE_W or 20
        want_w = math.max(cap.w, (tw - ROOM_RIGHT_MARGIN) - j.T.x)
        local limit = (j.config and j.config.card_limit) or 5
        if limit > 0 and cap.card_w > 0 then
            scale = want_w / (limit * cap.card_w)
            if scale > JOKER_SCALE_MAX then scale = JOKER_SCALE_MAX end
            if scale < 1 then scale = 1 end
        end
    end

    -- The ROW grows with the cards, not just the cards: align_cards centres a
    -- card vertically in the area (cardarea.lua:445), so a card taller than
    -- its box overflows both ways -- enlarged jokers were clipped off the top
    -- of the screen until the box scaled with them.
    local want_h = cap.h * scale
    local cw = cap.card_w * scale

    local dirty = false
    if math.abs(j.T.w - want_w) > 0.01
       or math.abs(j.T.h - want_h) > 0.01
       or math.abs((j.card_w or 0) - cw) > 0.01 then
        j.T.w, j.T.h, j.card_w = want_w, want_h, cw
        if j.hard_set_VT then j:hard_set_VT() end
        drop_backing(j)
        dirty = true
    end
    -- Card size is per-card, so each one is told -- including one bought a
    -- moment ago, which arrives at the default size. Collision follows T, so
    -- hover and clicking track the size for free. Each card scales ITS OWN
    -- captured dimensions (see card_base above), so a designed-small joker
    -- stays proportionally small.
    for _, card in ipairs(j.cards or {}) do
        if card.T then
            local base = card_base[card]
            if not base then
                base = { w = card.T.w, h = card.T.h }
                card_base[card] = base
            end
            local cs = card_scale(base, cap.card_w, cap.card_h, scale)
            local tw, th = base.w * cs, base.h * cs
            if math.abs(card.T.w - tw) > 0.01
               or math.abs(card.T.h - th) > 0.01 then
                card.T.w, card.T.h = tw, th
                if card.hard_set_VT then card:hard_set_VT() end
                dirty = true
            end
        end
    end
    if dirty and j.align_cards then pcall(j.align_cards, j) end

    -- The consumables' screen-1 position: ALWAYS ENFORCED, even while the
    -- section is drawing them on screen 2.
    --
    -- An earlier version left the transform alone whenever they were on
    -- screen 2, and that was a bug in waiting: the transform was unowned, and
    -- the relayout at a hand-liveness flip let VANILLA reposition the area
    -- (x = jokers.x + jokers.w + 0.2 -- off the right of a widened row). The
    -- cards followed the area there (CardArea:move re-aligns every frame),
    -- but the panel draw measures its offset from the BACKING, which does not
    -- track area movement -- so the panel showed the empty backing while the
    -- newly bought tarots sat five tiles outside the framed region,
    -- invisible. Parking the area at a defined spot at all times keeps area,
    -- backing and cards coherent, and the panel offset is recomputed from
    -- that coherent position each frame.
    --
    --   row is wide      underneath it, right-aligned -- there is no room
    --                    beside a full-width row.
    --   row is vanilla   beside it, exactly the formula
    --                    set_screen_positions uses.
    local cx, cy
    if wide then
        cx = j.T.x + j.T.w - c.T.w
        cy = j.T.y + j.T.h + CONSUMABLE_GAP
    else
        cx, cy = j.T.x + cap.w + 0.2, 0
    end
    if cx and (math.abs(c.T.x - cx) > 0.01 or math.abs(c.T.y - cy) > 0.01) then
        c.T.x, c.T.y = cx, cy
        if c.hard_set_VT then c:hard_set_VT() end
        drop_backing(c)
        if c.align_cards then pcall(c.align_cards, c) end
    end
end

--------------------------------------------------------------------------
-- Event adjustments, from the set_screen_positions wrapper.
--------------------------------------------------------------------------

local function shift(area, dy)
    if not area or not area.T then return end
    area.T.y = area.T.y + dy
    if area.hard_set_VT then area:hard_set_VT() end
    -- Moving a CardArea does NOT move the cards in it: they hold their own
    -- transforms and are only brought back into line by align_cards
    -- (cardarea.lua:448).
    if area.align_cards then pcall(area.align_cards, area) end
end

--- After vanilla lays the screen out with the hand ABSENT (it is on screen 2):
--- give the play area the freed space and move the discard pile into the
--- screen-2 region so the whole discard animation happens down there.
function layout.adjust()
    if not G or G.STAGE ~= G.STAGES.RUN then
        return
    end

    local snapshot = require("dualscreen.snapshot")
    if not snapshot.hand_is_live() then
        -- The hand is on screen 1's turf (shop, blind select, round eval):
        -- vanilla positions are correct, just realign the card contents.
        layout.restore()
        return
    end

    shift(G.play, PLAY_DROP)

    -- Move the discard pile ONTO screen 2. draw_card sends a discarded card
    -- toward this pile, so wherever the pile is, that is where the animation
    -- plays out -- the destination has to move, not the card be chased.
    -- Placed just above the right end of the hand, inside the region
    -- render.lua frames.
    if G.discard and G.discard.T and G.hand and G.hand.T then
        G.discard.T.x = G.hand.T.x + G.hand.T.w - G.discard.T.w
        G.discard.T.y = G.hand.T.y - 1.9
        if G.discard.hard_set_VT then G.discard:hard_set_VT() end
    end

    -- G.deck stays anchored bottom-right; G.hand keeps its vanilla transform
    -- because that is what the screen-2 renderer frames. The joker row and
    -- consumables belong to reconcile(), not to this event.
end

--- The null path: vanilla has just rewritten every position; realign the card
--- contents to their boxes. (set_screen_positions restores T absolutely but
--- does not realign cards, so contents could hold a shifted height inside a
--- box that had already moved back.)
function layout.restore()
    if not G or G.STAGE ~= G.STAGES.RUN then
        return
    end
    for _, area in ipairs({ G.jokers, G.consumeables, G.play, G.discard }) do
        if area and area.align_cards then
            pcall(area.align_cards, area)
        end
    end
end

return layout
