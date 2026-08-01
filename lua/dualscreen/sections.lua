-- balatro-dualscreen-thor -- what lives on screen 2, declared once.
--
-- WHY THIS EXISTS. The answer used to be spread across two places that had
-- to agree by hand:
--
--   init.lua   hidden_from_screen1() -- what screen 1 must NOT draw
--   render.lua render.draw()         -- what screen 2 DOES draw
--
-- With one section that was survivable. With the menu, blind select, the shop
-- and booster packs all moving down, each in different game states, it is
-- exactly the shape of thing that drifts: an object hidden from screen 1 but
-- not drawn on screen 2 simply vanishes from the game, and the reverse draws
-- it twice.
--
-- So a SECTION declares itself in one place, and both behaviours are derived
-- from it:
--
--   name      for logging
--   live()    is this section on screen 2 right now?
--   owns(obj) is obj one of ours? -- drives the screen-1 suppression
--   region()  optional; the tile-space rectangle screen 2 should frame
--   draw(ctx) draw it, via ctx.draw(obj, dy)
--
-- RULES.
--
--  * owns() must be allocation-free and cheap. It is called for every object
--    the game draws, every frame, from inside CardArea:draw and UIBox:draw.
--    Identity comparisons only -- do not build tables in it.
--
--  * Sections may be live at once. They are drawn in list order, and the
--    REGION comes from the first live section that supplies one, so more
--    specific sections (booster packs) must be listed before general ones.
--
--  * Anything owned MUST also be drawn, or it disappears from the game
--    entirely. That coupling is the whole point of declaring it once.
--
--  * Every section is behind DS.active, which the caller checks, so a
--    single-screen device keeps vanilla behaviour untouched.

local sections = {}

-- Forward declaration: defined below, used by the hand section's region and
-- draw at call time.
local hand_band_layout

-- Resolved lazily and then held, rather than required at the top: snapshot.lua
-- is free to require this module without a cycle, and owns() is a hot path
-- where even a package.loaded lookup per object per frame is worth avoiding.
local _snapshot
local function snap()
    _snapshot = _snapshot or require("dualscreen.snapshot")
    return _snapshot
end

--------------------------------------------------------------------------
-- Shared tile-space constants.
--
-- These live here rather than in render.lua because they are properties of a
-- SECTION's layout, and a section's region() and draw() both need them.
--------------------------------------------------------------------------

-- The hand's own box is tight: highlighted cards lift above it and G.buttons
-- hangs below it, so both need room or they would be cropped.
local PAD_TOP    = 2.2   -- lifted cards + a little air
local PAD_BOTTOM = 4.2   -- G.buttons sits under the hand
local PAD_SIDE   = 0.6

-- The cluster sits tight under the hand at vanilla's 0.3 tiles, close enough
-- to the cards to invite mis-taps. Pushed down. This is a draw-time
-- offset, so it is passed to ctx.draw as dy and recorded in the hit hash --
-- otherwise the buttons are drawn a tile below where they are touchable.
local BUTTON_DROP = 1.0

-- Blind select. Its UIBox is bonded to G.hand (major = G.hand,
-- bond = 'Weak', game.lua:3284), so it is already laid out relative to the
-- area screen 2 frames; these only add breathing room around its own box.
local BLIND_PAD_TOP    = 0.8
local BLIND_PAD_BOTTOM = 0.8
local BLIND_PAD_SIDE   = 0.8

-- Pack framing is anchored on G.pack_cards. PACK_BAR_BELOW covers the
-- "Choose 1" / "Skip" row, which sits under the cards inside the same UIBox and
-- is not part of the CardArea's own box. Measured from a celestial pack on
-- device: the row's underside is ~1.9 tiles below the cards.
-- Sets where the pack sits VERTICALLY in the panel, and it is not obvious why.
-- The region is centred in the panel, so padding added above the content
-- pushes the content DOWN by half of it. At 0.8 the cards and the "Choose 1"
-- row rode high with dead space beneath; 3.4 drops the whole composition to sit
-- as it does on screen 1, without changing its size (the fit stays
-- width-limited, so the scale is unaffected).
local PACK_CARD_PAD_TOP  = 3.4
-- Generous, and deliberately so: the "Choose 1" row is wider than the cards
-- and the whole composition is scaled to fit the region's WIDTH, so this is
-- the dial that sets how large the pack UI renders. At 0.8 the row came out
-- oversized; this brings it back toward its original size without shrinking
-- the cards much, since they were the thing that needed enlarging.
local PACK_CARD_PAD_SIDE = 1.8
local PACK_BAR_BELOW     = 1.6
-- Lift applied to the PACK CARDS ALONE, in tiles.
--
-- The cards and the "Choose 1" / Skip row are one UIBox, so region framing can
-- only move them together -- it sets where the whole group sits and how big it
-- is. Centring the cards that way would have dragged the row up with them, or
-- required scaling the group up ~34% to spread them apart, which had already
-- been rejected as too large.
--
-- Moveable:move_with_major adds role.offset into the transform every frame
-- (moveable.lua:357), so setting it on G.pack_cards lifts the cards inside the
-- box while the row stays exactly where it is. It is a REAL position change,
-- not a draw-time translate, so hit-testing follows it for free -- the same
-- reasoning as moving the discard pile rather than chasing the card.
--
-- 0.9 tiles is ~103 px on this panel, which was the measured distance from the
-- cards' centre to the centre of the screen.
local PACK_CARD_LIFT     = 0.9

-- The pack region's width is a CONSTANT, fixing the UI scale for every pack:
-- the cards and the "Choose N" / Skip row share one UIBox, so a region fitted
-- to the cards made the ROW change size with the card count (a buffoon pack's
-- row came out 34% oversized, a jumbo's 27% under). With a constant width both
-- render at the same scale in every pack.
--
-- Cards themselves are NOT scaled up when a pack holds few of them. That was
-- tried and reversed: vanilla renders the focused card through a separate
-- draw pass (game.lua:2889), which cannot inherit the enlargement, so the
-- SELECTED card dropped to its true size while its neighbours stayed large --
-- selecting a card made it visibly shrink. Cards draw at their vanilla size
-- inside the fixed-scale UI, exactly as screen 1 shows them.
local PACK_WIDTH     = 10.86   -- constant UI scale (the tuned 3-card value)

-- Overflow guard for WIDE packs. A jumbo celestial's CardArea is wider than
-- the fixed region, and its end cards clip off both panel edges without
-- this.
-- Cards at or under this span draw at vanilla size -- NEVER enlarged -- and a
-- wider row is scaled down just enough to fit.
local PACK_CARD_SPAN = 10.20

-- Hand-present layout (arcana and spectral). The pack cards sit above and the
-- hand below, and cardarea.lua:444 lifts the hand's own cards several tiles
-- above hand.T.y, so the band has to reach well up from the hand box.
local PACK_HAND_PAD_TOP    = 1.0
local PACK_HAND_PAD_BOTTOM = 1.2

-- Fraction of the panel width an overlay should occupy. The crop is sized from
-- the overlay's own width to hit this, so every menu lands the same size on
-- screen regardless of how wide it is in room tiles.
--
-- 0.80 is set from the New Run dialog, which was already right: it looked
-- correct in the 13.79-tile crop the fixed zoom gave it.
local OVERLAY_FILL = 0.80

-- Fallback when the overlay reports no usable width, and the tightest crop
-- allowed -- a narrow menu should not be blown up past this.
local OVERLAY_ZOOM = 1.45

-- The panel's top band: the hand score (left) and consumables (right).
--
-- HUD_SIDE_ROOM keeps the consumables clear of the panel edge -- selecting a
-- consumable opens its USE/SELL buttons off the card's RIGHT edge
-- (Card:highlight, align "cr", a 1.25-tile box, card.lua:4584) and lifts the
-- card, and both clipped off-screen when the area sat flush at the inset. The
-- score mirrors the same inset on the left, so the two read as a symmetric
-- pair.
local HUD_SIDE_ROOM = 1.1
local HUD_TOP_ROOM  = 0.5

-- The hand score at nine-tenths size: full size it visually outweighed the
-- consumables opposite, four-fifths read as slightly too small.
local SCORE_SCALE = 0.9

-- Vertical space reserved for that top band by the hand layout below, in
-- tiles: the consumables area's height (2.61, the taller of the two pieces)
-- plus clearance. RESERVED WHETHER OR NOT the pieces are currently on this
-- screen -- the hand and button placement must not jump when those toggles
-- flip.
local TOP_BAND_CONTENT_H = 2.61
local TOP_BAND_MARGIN    = 0.35

-- The consumables area drawn slightly under full size, so its displayed
-- height sits with the hand score's and the two top pieces read as one row.
-- 0.85 was the arithmetic match to the score box; in practice it read as a
-- smidge too small beside it, and 0.9 -- the same factor the score itself
-- uses -- is what looks right.
local CONS_SCALE = 0.9

-- Inset of the optional HUD pieces from the PANEL's top corners, in pixels.
-- Pixels for the same reason as the menu's corner pieces: it is a screen-space
-- margin, and the room's letterboxing makes equal tile insets unequal on screen.
local HUD_EDGE_PX = 20

-- Inset for the menu's corner pieces, in PANEL PIXELS.
--
-- Pixels, not tiles, because it is a screen-space margin: the eye judges it
-- against the panel edge, and the room's letterboxing means equal tile insets
-- are unequal pixel ones. Converted to tiles at draw time via DS.panel_tile.
local MENU_EDGE_PX = 20

-- The main menu. Padding only; the room clamp does the rest, and a UIBox
-- transform is an alignment box rather than a visible extent.
-- The shop. Only breathing room -- the room clamp decides the rest.
local SHOP_PAD = 0.4

-- The round-end Cash Out panel. Same idea.
local EVAL_PAD = 0.8

-- Booster packs: cards are drawn well above the hand box (cardarea.lua:444).
local PACK_PAD_TOP    = 6.4
local PACK_PAD_BOTTOM = 0.8

sections.BUTTON_DROP = BUTTON_DROP

--------------------------------------------------------------------------

--- Any of the five booster-pack states. One definition, in snapshot.lua --
--- layout.lua needs the same test and duplicates drift.
local function is_pack_state()
    return snap().is_pack_state()
end

--- The VISIBLE width of the open overlay menu, in tiles, or nil.
---
--- Not from G.OVERLAY_MENU.T. Measured on device, that is
---     overlay T=(-40.00,-23.00 100.00x57.50)   room=20.0x11.5
--- -- a backdrop five times the size of the room, not the dialog. Note that
--- a UIBox's T is an alignment box rather than a visible extent; this is the
--- most extreme example of it so far, and sizing from it collapsed every menu
--- to the fallback zoom.
---
--- The dialog is the ROOT's child, so the union of the root's children is the
--- box actually drawn. Anything as wide as the room is treated as another
--- backdrop and rejected, which sends the caller to the fixed-zoom fallback.
local function overlay_width()
    local o = G and G.OVERLAY_MENU
    local root = type(o) == "table" and o.UIRoot or nil
    if not root or not root.children then return nil end

    local tw = (G and G.TILE_W) or 20
    local x0, x1
    for _, c in pairs(root.children) do
        if type(c) == "table" and c.T and (c.T.w or 0) > 0 and (c.T.w or 0) < tw * 1.5 then
            x0 = math.min(x0 or c.T.x, c.T.x)
            x1 = math.max(x1 or (c.T.x + c.T.w), c.T.x + c.T.w)
        end
    end
    if not x0 or not x1 then return nil end

    local w = x1 - x0
    if w <= 0 or w >= tw then return nil end
    return w
end

--- Where the optional HUD pieces are anchored: the PANEL's top corners.
--- Returns left x, top y, and right x, in room-relative tiles.
---
--- Anchored to the panel, not to the framed region. The region during a round
--- measured 13.49 x 6.41 tiles, which the aspect fit letterboxes with about
--- 245 px of slack above and below -- so "the top of the region" is a quarter
--- of the way down the screen, which is where these first landed. The same
--- reasoning as the main menu's corner pieces.
local function hud_corner()
    if not DS.panel_tile or (DS.panel_w or 0) <= 0 then return nil end
    local lx, ty = DS.panel_tile(HUD_EDGE_PX, HUD_EDGE_PX)
    local rx = DS.panel_tile((DS.panel_w or 0) - HUD_EDGE_PX, 0)
    if not lx or not ty or not rx then return nil end
    return lx, ty, rx
end

--- The hand-score element while hud.lua has it detached from the HUD, or nil.
local function hud_element()
    local ok, m = pcall(require, "dualscreen.hud")
    return ok and m and m.element() or nil
end

--- The HUD element wrapping the hand-score readout, or nil.
---
--- 'hand_text_area' is a named node in create_UIBox_HUD
--- (UI_definitions.lua:1341) holding the hand name, level, chip total and the
--- chips x mult pair. G.hand_text_area is a TABLE OF SEPARATE ELEMENTS built
--- from that box (game.lua:2406) and is not itself drawable, so the wrapper is
--- what has to be found.
local function hand_score_uie()
    local hud = G and G.HUD
    if not hud or not hud.get_UIE_by_ID then return nil end
    local ok, e = pcall(hud.get_UIE_by_ID, hud, "hand_text_area")
    return ok and e or nil
end

--- Does the open pack put the HAND in play as well as its own cards?
---
--- Arcana and spectral packs contain tarots and spectrals that act on selected
--- playing cards, so the game deals the hand alongside them. Celestial,
--- standard and buffoon packs do not. The two need different framing, and the
--- card lift only makes sense for the second group.
---
--- Tested by state rather than by `#hand.cards > 0`: the hand is dealt a beat
--- after the pack opens, and a liveness test that flips mid-animation would
--- re-frame the panel underneath the player.
function sections.pack_uses_hand()
    if not G or not G.STATE or not G.STATES then return false end
    return G.STATE == G.STATES.TAROT_PACK
        or G.STATE == G.STATES.SPECTRAL_PACK
end

--- The booster pack card mid-explosion, if any.
---
--- Card:open sets `self.opening = true` (card.lua:1685) and the card is by
--- then detached from its area, so this identity test is both precise and the
--- only handle available.
local function opening_card()
    if not G or not G.I or not G.I.CARD then return nil end
    for _, c in pairs(G.I.CARD) do
        if c.opening and not c.REMOVED then return c end
    end
    return nil
end

--- The consumables' draw-time offset onto the panel's top-right, or nil.
--- One computation, shared by the section's draw and its tooltip overlay --
--- the tooltips must ride the same offset as the cards or they render at the
--- area's parked screen-1 position instead of under the card the player is
--- touching.
local function cons_panel_offset()
    local c = G and G.consumeables
    if not c or not c.T then return nil end
    local tx, ty, rx = hud_corner()
    if not tx then return nil end
    local ab = c.children and c.children.area_uibox
    local ref = (ab and ab.T and ab.T.w > 0) and ab.T or c.T
    -- Offset, then the scale anchor: the ref's TOP-RIGHT corner, so the right
    -- inset and top edge hold still as the box scales down toward them.
    return (rx - HUD_SIDE_ROOM - ref.w) - ref.x,
           (ty + HUD_TOP_ROOM) - ref.y,
           ref.x + ref.w,
           ref.y
end

--- The three-band panel layout for the hand view. Returns the region, and
--- (as a second value) the draw offset that puts the button cluster on the
--- bottom band. nil when the panel dimensions are not known yet.
hand_band_layout = function()
    local hand = G and G.hand
    if not hand or not hand.T then return nil end
    if not DS or (DS.panel_w or 0) <= 0 or (DS.panel_h or 0) <= 0 then
        return nil
    end

    local w = hand.T.w + 2 * PAD_SIDE
    local h = w * DS.panel_h / DS.panel_w
    local px_per_tile = DS.panel_w / w
    local inset = HUD_EDGE_PX / px_per_tile

    local top_band = inset + HUD_TOP_ROOM + TOP_BAND_CONTENT_H + TOP_BAND_MARGIN

    local btn_h = (G.buttons and G.buttons.T and G.buttons.T.h) or 1.8
    local buttons_top = h - inset - btn_h

    local hand_top = top_band + ((buttons_top - top_band) - hand.T.h) / 2

    local region = {
        x = hand.T.x - PAD_SIDE,
        y = hand.T.y - hand_top,
        w = w,
        h = h,
    }

    local drop = nil
    if G.buttons and G.buttons.T then
        drop = (region.y + buttons_top) - G.buttons.T.y
    end
    return region, drop
end

--- The band screen 2 frames during a booster pack.
---
--- ANCHORED ON G.pack_cards, not on the hand and not on the UIBox.
---
--- G.pack_cards is a real CardArea built with explicit dimensions
--- (UI_definitions.lua:1815 for celestial: `_size*G.CARD_W*1.1 + 0.5` wide by
--- `1.05*G.CARD_H` tall), so unlike a UIBox transform it genuinely describes
--- its content -- which a UIBox's T does not.
---
--- Framing on the hand instead is wrong for packs opened from the shop:
--- the hand is EMPTY there, so the region reserved ~4.7 tiles
--- of dead space above the cards and the whole selection sat squashed against
--- the bottom of the panel.
---
--- Two cases, because the hand may or may not be part of the interaction:
---
---   * Arcana and spectral packs let you select cards FROM YOUR HAND, and
---     cardarea.lua:444 lifts those ~5-6 tiles above the hand's own box. The
---     region has to span from the lifted band down past the hand.
---   * Celestial, standard and buffoon packs do not involve the hand. Framing
---     only the pack content lets it fill the panel properly.
local function pack_region()
    local hand = G and G.hand
    if not hand or not hand.T then return nil end

    local pc = G.pack_cards
    if not pc or not pc.T or pc.T.w <= 0 or pc.T.h <= 0 then
        sections._pack_logged = nil   -- log afresh for the next pack
        -- The pack UI does not exist yet: this is the opening explosion.
        --
        -- DO NOT FRAME THE EXPLODING CARD. An earlier version did, and it
        -- centred and magnified the pack card in the panel the instant it was
        -- tapped -- so the pack "appeared in the middle of the screen" at a
        -- size it never has on screen 1, and the explosion then played over
        -- that. It also meant the framing changed twice in quick succession,
        -- once onto the card and again onto the pack UI.
        --
        -- Returning nil hands framing to the room view, so the card explodes
        -- where it actually is, at the scale everything else is drawn at, and
        -- the panel zooms in once when the pack proper arrives.
        return nil
    end

    local top, bottom, left, right

    if sections.pack_uses_hand() then
        -- ARCANA / SPECTRAL: the pack cards and the hand are both in play, so
        -- the band spans both. No card lift here -- that exists to centre a
        -- lone pack row, and there is nothing to centre when the hand is
        -- sharing the panel.
        top    = math.min(pc.T.y, hand.T.y - PACK_PAD_TOP) - PACK_HAND_PAD_TOP
        bottom = hand.T.y + hand.T.h + PACK_HAND_PAD_BOTTOM
        left   = math.min(pc.T.x, hand.T.x) - PAD_SIDE
        right  = math.max(pc.T.x + pc.T.w, hand.T.x + hand.T.w) + PAD_SIDE
    else
        -- CELESTIAL / STANDARD / BUFFOON: the pack row alone.
        --
        -- Anchor on the cards' UNLIFTED position. pc.T.y already includes
        -- PACK_CARD_LIFT once the lift is applied, and framing on the lifted
        -- value would move the region up, which moves the content down, which
        -- moves the region again -- the framing would chase itself.
        local anchor = pc.T.y + PACK_CARD_LIFT
        top    = anchor - PACK_CARD_PAD_TOP
        bottom = anchor + pc.T.h + PACK_BAR_BELOW

        -- Constant width, centred on the cards: identical scale and identical
        -- vertical placement in every pack. See PACK_WIDTH.
        local cx = pc.T.x + pc.T.w / 2
        left, right = cx - PACK_WIDTH / 2, cx + PACK_WIDTH / 2
    end

    if DS.PACK_DEBUG and not sections._pack_logged then
        sections._pack_logged = true
        DS.log(("pack: cards T=(%.2f,%.2f %.2fx%.2f) hand T=(%.2f,%.2f %.2fx%.2f) n=%d")
            :format(pc.T.x, pc.T.y, pc.T.w, pc.T.h,
                    hand.T.x, hand.T.y, hand.T.w, hand.T.h, #(hand.cards or {})))
        DS.log(("  region=(%.2f,%.2f %.2fx%.2f)")
            :format(left, top, right - left, bottom - top))
    end

    return { x = left, y = top, w = right - left, h = bottom - top }
end

--- Is obj a card sitting in `area`?
---
--- Needed because Game:draw renders the controller's focused and dragged
--- targets EXPLICITLY, outside the `if not v.parent` loops (game.lua:2889 and
--- 2897). A card inside one of our UIBoxes is normally drawn by that box and
--- never reaches screen 1 -- but the moment the controller focuses it, it is
--- drawn again by that separate path, and owning the parent box is not enough
--- to stop it. Reported as "the selected pack moves to the top screen" when
--- navigating a booster pack with the stick.
local function card_in(obj, area)
    return area ~= nil and obj.area == area
end

--- Is obj the hover tooltip or use-button of a card in `area`?
---
--- Popups live in G.I.POPUP and are drawn by their own pass (game.lua:2901),
--- so they do not follow their card's parent either.
local function popup_of(obj, area)
    if not area or not area.cards then return false end
    for _, c in ipairs(area.cards) do
        local ch = c.children
        if ch and (ch.h_popup == obj or ch.d_popup == obj
                   or ch.use_button == obj or ch.buy_button == obj) then
            return true
        end
    end
    return false
end

--- Is obj a tooltip anchored somewhere inside the blind-select boxes?
---
--- The skip tags' tooltips need this: tag_sprite.hover builds an h_popup
--- UIBox whose major is the SPRITE (tag.lua:525-527), the sprite's major is
--- its host element, and only that element's UIBox is one of the boxes this
--- section knows -- G.blind_select or the per-blind option boxes in
--- G.blind_select_opts (their own top-level UIBoxes, UI_definitions.lua:1447).
--- So membership is a role.major/parent chain walk, gated on instance_type
--- 'POPUP' so the hot owns() path pays it only for actual tooltips.
local function blind_popup(obj)
    -- instance_type lives on the box's CONFIG -- UIBox:init reads
    -- args.config.instance_type to pick its G.I table (ui.lua:93) and never
    -- copies it onto the object. Testing obj.instance_type matched nothing,
    -- which shipped as "the fix didn't take": no ownership, no overlay draw.
    if not obj.config or obj.config.instance_type ~= "POPUP" then
        return false
    end
    local opts = G.blind_select_opts
    local function is_box(b)
        if not b then return false end
        if b == G.blind_select then return true end
        if opts then
            for _, v in pairs(opts) do
                if v == b then return true end
            end
        end
        return false
    end
    local m, guard = obj, 0
    while m and guard < 10 do
        if is_box(m) or is_box(m.UIBox) then return true end
        m = (m.role and m.role.major) or m.parent
        guard = guard + 1
    end
    return false
end

--- Is obj an attention_text UIBox anchored inside the DETACHED score subtree?
---
--- level_up_hand's "+chips / +mult / level" flashes are
--- attention_text UIBoxes whose uibox_config.major is the chips/mult element's
--- parent INSIDE the hand-text area (update_hand_text, common_events.lua:513
--- and 542; attention_text stores it via set_alignment -> role.major,
--- ui.lua:216). With the score detached to the panel, those boxes kept
--- appearing on screen 1 at the element's vanilla-side position -- the one
--- place nothing is drawn. The anchor element's `.parent` chain still reaches
--- the detached root (detaching removes the element from its parent's
--- children ARRAY; the child's own .parent reference is untouched), so chain
--- membership is the ownership test, at any depth.
local function attention_on_score(obj)
    if not obj or not obj.attention_text then return false end
    local e = hud_element()
    if not e then return false end
    local m = obj.role and obj.role.major
    local guard = 0
    while m and guard < 16 do
        if m == e then return true end
        m = m.parent
        guard = guard + 1
    end
    return false
end

--- Is obj one of the Particles bursts attention_text attaches to such a box?
--- (One attaches to the box's UIRoot, the backdrop variant to the box itself;
--- UI_definitions.lua:931 and 944.)
local function attention_particles_on_score(obj)
    local m = obj.role and obj.role.major
    if not m then return false end
    if m.attention_text then return attention_on_score(m) end
    return m.UIBox ~= nil and attention_on_score(m.UIBox)
end

--- Draw a focused or dragged card in `area`, plus every card's furniture.
---
--- CardArea:draw DELIBERATELY SKIPS the focused and dragged targets
--- (`if self.cards[i] ~= G.CONTROLLER.focused.target`, cardarea.lua:333) so
--- that Game:draw can render them last, on top of everything. That means
--- suppressing the explicit pass -- which we must, or the card appears on
--- screen 1 -- also removes it from screen 2, because the card area never drew
--- it in the first place. Observed as the focused pack card vanishing from
--- both screens.
---
--- So it is drawn here instead, last, which is where vanilla puts it too.
--- Tooltips and use/buy buttons are drawn for the same reason: they live in
--- G.I.POPUP with their own pass (game.lua:2901) and do not follow their card's
--- parent.
local function draw_card_furniture(ctx, area, sc, scx, scy)
    if not area or not area.cards then return end

    -- DO NOT draw use_button / buy_button here. They are UIBoxes whose config
    -- carries `parent = self` (card.lua:4589), so Card:draw already renders
    -- them as children -- and Game:draw skips parented UIBoxes for exactly that
    -- reason. Drawing one again applies the container transform a second time,
    -- which showed up as a stretched grey slab over the selected tarot card
    -- instead of a USE button.
    --
    -- Popups are different and ARE drawn, but in the overlay pass below: they
    -- have to come after every section or the hand paints over them.

    local C = G.CONTROLLER
    if not C then return end
    local focused  = C.focused  and C.focused.target
    local dragging = C.dragging and C.dragging.target
    -- Optional draw-time scale, matching whatever transform the area itself
    -- was drawn with -- a focused card must render at exactly its neighbours'
    -- size or selecting a card visibly resizes it.
    local function put(card)
        if sc and sc ~= 1 then
            ctx.draw_scaled(card, sc, scx, scy)
        else
            ctx.draw(card, 0)
        end
    end
    if focused and card_in(focused, area) then
        put(focused)
    end
    if dragging and dragging ~= focused and card_in(dragging, area) then
        put(dragging)
    end
end

--- Tooltips for a card area, drawn in the overlay pass.
---
--- UIBox:draw deliberately skips h_popup in its children loop (ui.lua:288) --
--- the engine draws popups separately, from G.I.POPUP, so that they land on
--- top of everything. Doing the same here matters most in an arcana pack,
--- where the tarot cards and the hand are both on screen: drawing a popup
--- during its own section put it underneath the hand, which is drawn later.
local function draw_popups(ctx, area, sc, scx, scy)
    if not area or not area.cards then return end
    for _, c in ipairs(area.cards) do
        local ch = c.children
        if ch then
            -- Ride the area's draw-time scale, if any: a popup anchors to its
            -- card's REAL transform, and the visible card may have been drawn
            -- scaled about the row's centre.
            if sc and sc ~= 1 then
                ctx.draw_scaled(ch.h_popup, sc, scx, scy)
                ctx.draw_scaled(ch.d_popup, sc, scx, scy)
            else
                ctx.draw(ch.h_popup, 0)
                ctx.draw(ch.d_popup, 0)
            end
        end
    end
end

--- Is this UIBox the hover tooltip of a card in the hand?
---
--- Tooltips are not children of anything else we own: Node:hover puts them in
--- G.I.POPUP with instance_type = 'POPUP' (engine/node.lua:270), a separate
--- instance table from I.NODE / I.MOVEABLE, so the draw wrappers never saw them
--- and they kept rendering on screen 1.
---
--- Matched by identity against the hand's own cards rather than by type, so
--- joker and consumable tooltips on screen 1 are untouched.
local function is_hand_popup(obj)
    local hand = G and G.hand
    if not hand or not hand.cards then return false end
    for _, card in ipairs(hand.cards) do
        local ch = card.children
        if ch and (ch.h_popup == obj or ch.d_popup == obj) then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------
-- The sections.
--
-- Ordered. More specific regions first -- see the region rule above.
--------------------------------------------------------------------------

sections.list = {
    -- The main menu.
    --
    -- G.MAIN_MENU_UI is the button cluster (common_events.lua:754), bonded to
    -- G.ROOM_ATTACH rather than to the hand, since there is no hand here.
    -- G.PROFILE_BUTTON is a separate UIBox created a moment later in the same
    -- function, so it needs naming explicitly or it would be left on screen 1
    -- by itself.
    --
    -- Deliberately NOT owning G.title_top or G.SPLASH_LOGO: the animated title
    -- and its card fan are the backdrop of the top screen and should stay
    -- there. Only the things you press move down.
    {
        name = "main_menu",

        live = function()
            return G and G.STAGES and G.STAGE == G.STAGES.MAIN_MENU
               and G.MAIN_MENU_UI ~= nil
        end,

        owns = function(obj)
            return obj == G.MAIN_MENU_UI
                or obj == G.PROFILE_BUTTON
        end,

        -- NO REGION: the whole room is framed instead.
        --
        -- Framing the button box alone cropped everything outside it, and the
        -- two corner pieces are outside it -- G.PROFILE_BUTTON is a separate
        -- UIBox entirely (common_events.lua:765), and the language selector
        -- sits in its own column aligned bottom-right. Returning nil hands
        -- framing to the room view, so the panel shows the same field the top
        -- screen does: stack in the middle, profile bottom-left, language
        -- bottom-right, each where the game already puts it.
        region = nil,

        draw = function(ctx)
            -- Nothing while an overlay is up. The overlay's crop is tighter
            -- than the room, so the menu behind it renders MAGNIFIED -- a
            -- giant PLAY looming behind the Options popup, corner buttons
            -- pushed off-frame. Vanilla dims its
            -- backdrop for the same reason overlays exist: the thing behind a
            -- modal is noise. The section stays live, so ownership still
            -- keeps the menu off screen 1.
            if G.OVERLAY_MENU then return end

            -- Lift the button cluster off the bottom edge so the stack sits in
            -- the middle of the panel rather than hugging the floor. Vanilla
            -- aligns it 'bmi' against G.ROOM_ATTACH with offset.y = 0
            -- (common_events.lua:757), which is right for a horizontal strip
            -- and wrong for a tall column.
            --
            -- Set every frame: the menu rebuilds itself on profile changes and
            -- on returning from a run, and the assignment is idempotent.
            -- Hold both corner pieces a fixed number of PIXELS off the panel
            -- edge, computed from the actual mapping rather than assumed.
            --
            -- A tile inset does not work here. The room is letterboxed into the
            -- panel -- its 11.5-tile height maps to about 896 px of a 1080 px
            -- panel -- so sitting on the room's floor leaves ~184 px of
            -- background below, and an inset that is 20 px on the left edge is
            -- something else entirely on the bottom. Measured before fixing:
            -- profile 20 px from the left but 212 px from the bottom.
            --
            -- So the anchors are derived: ask where the panel's 20 px inset
            -- falls in room tiles, and put the boxes there. Aspect-independent,
            -- and no panel dimension appears as a constant.
            local bx = DS.panel_tile and DS.panel_tile(MENU_EDGE_PX, MENU_EDGE_PX)
            local _, by = DS.panel_tile(0, (DS.panel_h or 0) - MENU_EDGE_PX)
            local rx = DS.panel_tile((DS.panel_w or 0) - MENU_EDGE_PX, 0)
            local _, cy = DS.panel_tile(0, (DS.panel_h or 0) / 2)
            local tw = (G.TILE_W or 20)
            local th = (G.TILE_H or 11.5)
            --
            -- menu.lua sizes the menu's ROOT to the room less MENU_EDGE_PAD, so
            -- the language selector is already inset on the right -- but the
            -- box is aligned 'bmi', which puts its bottom ON the room floor.
            -- Lifting it by the same pad insets it at the bottom too.
            --
            -- G.PROFILE_BUTTON is a SEPARATE UIBox aligned 'bli' with zero
            -- offset (common_events.lua:767), so it sits flush in the corner
            -- and has to be nudged on its own. Doing it here rather than in
            -- menu.lua because it is not part of that definition at all.
            --
            -- Set every frame: both boxes are rebuilt on profile changes and on
            -- returning from a run, and the assignment is idempotent.
            local m = G.MAIN_MENU_UI
            if m and bx and by and rx and cy then
                -- 'bmi' puts the box's bottom on the room floor, so the offset
                -- is the gap between that floor and where we want the bottom.
                if m.alignment and m.alignment.offset then
                    m.alignment.offset.y = by - th
                end

                -- Size the ROOT so its right edge lands on the 20 px inset and
                -- the button stack -- centred inside it -- lands on the panel's
                -- centre. Both follow from the box being horizontally centred
                -- and bottom-aligned.
                -- Nothing else to do here. The box's SIZE is set on the
                -- definition in menu.lua, which is the only place the layout
                -- reads it from -- writing UIRoot.config after construction and
                -- recalculating does not stick, and nudging a laid-out element
                -- by its role offset moved the element's own background while
                -- its children stayed put. Layout belongs to the definition.
            end

            local pb = G.PROFILE_BUTTON
            if pb and pb.alignment and pb.alignment.offset and bx and by then
                -- 'bli' anchors bottom-left of the room, so both offsets are
                -- straight gaps from that corner.
                pb.alignment.offset.x = bx
                pb.alignment.offset.y = by - th
            end

            ctx.draw(m, 0)
            ctx.draw(pb, 0)
        end,
    },

    -- Listed before "hand" so its region wins if both were ever
    -- live at once; in practice they cannot be, because BLIND_SELECT is not in
    -- snapshot.lua's HAND_LIVE set.
    {
        name = "blind_select",

        -- G.blind_select is created on entering the state and removed on
        -- leaving it (button_callbacks.lua:2542), so existence plus state is
        -- the whole test. It is deliberately NOT gated on the UIBox having
        -- eased into place: the game slides it in from off-screen, and that
        -- animation should play out on screen 2 like any other.
        live = function()
            return G and G.STATE and G.STATES
               and G.STATE == G.STATES.BLIND_SELECT
               and G.blind_select ~= nil
        end,

        owns = function(obj)
            return obj == G.blind_select
                or blind_popup(obj)
        end,

        region = function()
            local b = G.blind_select
            if not b or not b.T or b.T.w <= 0 or b.T.h <= 0 then
                return nil
            end
            return {
                x = b.T.x - BLIND_PAD_SIDE,
                y = b.T.y - BLIND_PAD_TOP,
                w = b.T.w + 2 * BLIND_PAD_SIDE,
                h = b.T.h + BLIND_PAD_TOP + BLIND_PAD_BOTTOM,
            }
        end,

        draw = function(ctx)
            ctx.draw(G.blind_select, 0)
        end,

        -- The skip tags' tooltips. A tag's hover builds an h_popup UIBox
        -- (tag.lua:525) that lands in G.I.POPUP with the SPRITE as its major
        -- -- reachable through no object this section draws, so it kept
        -- rendering on the top screen. Owned by chain (blind_popup above) and
        -- drawn here in the overlay pass, where popups belong.
        overlay = function(ctx)
            for _, p in ipairs(G.I.POPUP or {}) do
                if not p.REMOVED and blind_popup(p) then
                    ctx.draw(p, 0)
                end
            end
        end,
    },

    -- G.booster_pack is the UIBox for all five pack types
    -- (game.lua:3364 and friends), bonded to G.hand like the shop and blind
    -- select. G.pack_cards is an object node inside it
    -- (UI_definitions.lua:1642 and friends), so -- as with the shop -- owning
    -- the UIBox carries the cards, the Skip button and the pack header
    -- together, and Game:draw's `if not v.parent` guard keeps it from being
    -- drawn twice.
    --
    -- FIRST IN THE LIST, because during an arcana pack the hand section is
    -- ALSO live (all five pack states are in HAND_LIVE -- you pick cards from
    -- your hand), and the pack band is the region that has to win.
    {
        name = "booster_pack",

        -- LIVE BY STATE, plus the card that is mid-explosion.
        --
        -- An earlier version keyed on the existence of G.booster_pack or any of
        -- the particle globals, on the belief that the particles are created
        -- before G.STATE moves to the pack state. THAT IS NOT TRUE: Card:open
        -- sets the state at card.lua:1693 and only calls explode() at :1721, so
        -- the state is always there first. (The real cause of the animation
        -- appearing on screen 1 was the SHOP section going dormant at that same
        -- instant, and the exploding card being a parentless top-level Card --
        -- both fixed separately.)
        --
        -- The existence test bought nothing and cost correctness: the particle
        -- globals OUTLIVE the pack, so the section stayed live afterwards and
        -- kept drawing celestial sparkles over the panel long after the pack
        -- was gone. Vanilla leaves them lying around too; it simply stops
        -- treating them as pack content.
        --
        -- opening_card() stays as the one genuine edge: it costs a cheap
        -- G.I.CARD walk only while a card is actually exploding.
        live = function()
            return is_pack_state() or opening_card() ~= nil
        end,

        owns = function(obj)
            return obj == G.booster_pack
                or obj == G.booster_pack_sparkles
                or obj == G.booster_pack_stars
                or obj == G.booster_pack_meteors
                or obj.opening == true
                or card_in(obj, G.pack_cards)
                or popup_of(obj, G.pack_cards)
        end,

        -- Region only once the pack proper exists. During the hand-over from
        -- the shop the particles are already ours to draw, but the SHOP should
        -- still decide the framing -- otherwise the panel jumps to a hand-based
        -- fallback for a few frames mid-animation.
        region = function()
            if not is_pack_state() or not G.pack_cards then return nil end
            -- A pack whose cards have ALL been taken is visually over -- only
            -- the transparent bar remains, and vanilla may hold the state for
            -- seconds while a planet's level-up animation plays out. Keeping
            -- the tight pack crop through that showed the score floating on a
            -- near-black starfield. Yielding
            -- the region here hands framing to the shop underneath, so the
            -- level-up plays over the context that is actually returning.
            -- Gated on the pack having ever HELD cards: during the opening
            -- deal the area is briefly empty too, and yielding then would
            -- wobble the frame on every pack open.
            local pc = G.pack_cards
            if pc.cards and #pc.cards > 0 then
                sections._pack_had_cards = pc
            elseif sections._pack_had_cards == pc then
                return nil
            end
            return pack_region()
        end,

        draw = function(ctx)
            -- Lift the cards inside the box. Re-applied every frame because
            -- UIElement:set_role rebuilds the role table without an offset
            -- (ui.lua:394) whenever the box re-lays-out; the assignment is
            -- idempotent and costs nothing.
            local pc = G.pack_cards
            if pc and pc.role and pc.role.offset then
                pc.role.offset.y =
                    sections.pack_uses_hand() and 0 or -PACK_CARD_LIFT
            end

            -- Particles first, so the opening animation reads as behind the
            -- pack contents rather than over them.
            ctx.draw(G.booster_pack_sparkles, 0)
            ctx.draw(G.booster_pack_stars, 0)
            ctx.draw(G.booster_pack_meteors, 0)
            ctx.draw(opening_card(), 0)

            -- Cards draw at vanilla size, EXCEPT when the row is too wide
            -- for the fixed region -- then it is scaled DOWN to fit. The scale
            -- is draw-time and recorded in the hit hash, and the focused-card
            -- pass and tooltips ride the same transform so selection cannot
            -- change a card's size -- the wart that killed the enlargement.
            local sc, scx, scy = 1, 0, 0
            if pc and pc.T and pc.T.w > PACK_CARD_SPAN then
                sc  = PACK_CARD_SPAN / pc.T.w
                scx = pc.T.x + pc.T.w / 2
                scy = pc.T.y + pc.T.h / 2
            end

            if sc < 1 and pc and pc.cards and not pc.REMOVED then
                DS.defer_area = pc
                ctx.draw(G.booster_pack, 0)
                DS.defer_area = nil
                ctx.draw_scaled(pc, sc, scx, scy)
            else
                ctx.draw(G.booster_pack, 0)
            end

            draw_card_furniture(ctx, G.pack_cards, sc, scx, scy)
        end,

        overlay = function(ctx)
            local pc = G.pack_cards
            if pc and pc.T and pc.T.w > PACK_CARD_SPAN then
                draw_popups(ctx, pc, PACK_CARD_SPAN / pc.T.w,
                            pc.T.x + pc.T.w / 2, pc.T.y + pc.T.h / 2)
            else
                draw_popups(ctx, pc)
            end
        end,
    },

    -- The round-end "Cash Out" panel. Same construction as blind select: a
    -- UIBox bonded to G.hand (game.lua:3317), eased in by alignment offset,
    -- and REMOVED on the cash-out click (button_callbacks.lua:2925). Existence
    -- is therefore the honest liveness test -- the object spans exactly the
    -- window the panel should be visible, including the slide-in animation,
    -- and outlives no state (the lesson the shop taught in 8.7).
    {
        name = "round_eval",

        live = function()
            return G and G.round_eval ~= nil
        end,

        -- Owned BY RELATIONSHIP as well as by name. The Cash Out button is an
        -- ANONYMOUS UIBox -- add_round_eval_row builds it with
        -- `major = G.round_eval` and assigns it to nothing
        -- (common_events.lua:1066) -- so there is no global to test. Anything
        -- bonded to the panel is part of the panel.
        owns = function(obj)
            return obj == G.round_eval
                or (obj.role ~= nil and obj.role.major == G.round_eval)
        end,

        -- Framed on its transform with breathing room; the room clamp corrects
        -- for a UIBox's T being an alignment box rather than a visible extent
        -- exactly as it does for blind select.
        region = function()
            local r = G.round_eval
            if not r or not r.T or r.T.w <= 0 or r.T.h <= 0 then
                return nil
            end
            return {
                x = r.T.x - EVAL_PAD,
                y = r.T.y - EVAL_PAD,
                w = r.T.w + 2 * EVAL_PAD,
                h = r.T.h + 2 * EVAL_PAD,
            }
        end,

        draw = function(ctx)
            ctx.draw(G.round_eval, 0)
            -- The bonded anonymous boxes too -- the Cash Out button chief
            -- among them. Top-level boxes only: anything parented inside the
            -- panel is already drawn by it.
            for _, v in pairs(G.I.UIBOX or {}) do
                if v ~= G.round_eval and not v.parent
                   and v.role and v.role.major == G.round_eval then
                    ctx.draw(v, 0)
                end
            end
        end,
    },

    -- The shop's three CardAreas -- G.shop_jokers, G.shop_vouchers,
    -- G.shop_booster -- are OBJECT NODES INSIDE this UIBox
    -- (UI_definitions.lua:719, 727, 731), and Game:draw's top-level card-area
    -- loop skips anything with a parent (game.lua:2803, `if not v.parent`).
    -- So they are drawn by the UIBox, and owning G.shop alone takes the whole
    -- shop -- sign, buttons, jokers, vouchers and boosters -- across together.
    {
        name = "shop",

        -- LIVE WHILE G.shop EXISTS, not while the state is SHOP.
        --
        -- Why this matters: Card:open() sets G.STATE to the
        -- pack state at card.lua:1693 and only THEN calls self:explode() --
        -- so gating on the state meant the shop stopped being ours the instant
        -- the pack was tapped, and popped back to screen 1 carrying the
        -- exploding pack card with it. That was the "opening animation plays on
        -- the top screen" report; the sparkles had already been moved, but the
        -- explosion is the card dissolving inside the shop, and Card:explode's
        -- own particles use `attach = self` (card.lua:1996) so they follow it.
        --
        -- Existence is the right test: G.shop is removed only when leaving for
        -- blind select (button_callbacks.lua:2500), and it deliberately
        -- persists behind an open pack -- which is why you return to it
        -- afterwards. During a pack both sections are live, the pack is listed
        -- first and wins the region, and the shop renders behind it exactly as
        -- it does on screen 1.
        live = function()
            return G.shop ~= nil
        end,

        owns = function(obj)
            return obj == G.shop
                or card_in(obj, G.shop_jokers)
                or card_in(obj, G.shop_vouchers)
                or card_in(obj, G.shop_booster)
                or popup_of(obj, G.shop_jokers)
                or popup_of(obj, G.shop_vouchers)
                or popup_of(obj, G.shop_booster)
        end,

        -- Framed on the UIBox and then clamped to the room by sections.region.
        --
        -- The clamp is doing the real work here. A UIBox's T is an
        -- alignment box rather than a visible extent -- blind
        -- select's options measured 30.16 tiles tall in an 11.5-tile room --
        -- so this deliberately does not try to be clever about the true bounds.
        -- Clamped, it resolves to the part of the room the shop occupies, which
        -- is what screen 1 would have shown.
        -- FROZEN AGAINST THE SHOP'S OWN SLIDES. A region that tracks its
        -- anchor stabilises it -- that is what makes a sliding pack appear
        -- still. For the shop that inversion is exactly wrong: entering and
        -- leaving a pack slides the shop up or down through the room, and a
        -- frame riding the slide pins the shop on screen while the whole
        -- world zooms around it -- a "bounce out" in place of
        -- vanilla's slide. So the rect only updates while the shop is
        -- STATIONARY (same T two frames running, and not parked behind a
        -- pack); while it moves, the last settled rect holds and the shop
        -- visibly slides within it, exactly as on screen 1. Relies on
        -- render.active_region calling this once per frame.
        region = function()
            local sh = G.shop
            if not sh or not sh.T or sh.T.w <= 0 or sh.T.h <= 0 then
                return nil
            end
            local st = sections._shop_still
            if not st or st.sh ~= sh then
                st = { sh = sh, y = sh.T.y, rect = nil }
                sections._shop_still = st
            end
            local moving = math.abs(sh.T.y - st.y) > 0.005
            st.y = sh.T.y
            local parked = sh.alignment and sh.alignment.offset
                           and sh.alignment.offset.py ~= nil
            if not moving and not parked then
                st.rect = {
                    x = sh.T.x - SHOP_PAD,
                    y = sh.T.y - SHOP_PAD,
                    w = sh.T.w + 2 * SHOP_PAD,
                    h = sh.T.h + 2 * SHOP_PAD,
                }
            end
            return st.rect
        end,

        draw = function(ctx)
            ctx.draw(G.shop, 0)
            draw_card_furniture(ctx, G.shop_jokers)
            draw_card_furniture(ctx, G.shop_vouchers)
            draw_card_furniture(ctx, G.shop_booster)
        end,

        overlay = function(ctx)
            draw_popups(ctx, G.shop_jokers)
            draw_popups(ctx, G.shop_vouchers)
            draw_popups(ctx, G.shop_booster)
        end,
    },

    {
        name = "hand",

        live = function()
            return snap().hand_is_live()
        end,

        owns = function(obj)
            return obj == G.hand
                or obj == G.buttons
                or obj == G.discard
                or is_hand_popup(obj)
        end,

        -- The panel is composed as three bands, derived rather than tuned:
        --
        --   top     the score / consumables strip (reserved even when those
        --           are on the top screen, so nothing jumps when they toggle)
        --   middle  the hand, vertically centred between the bands
        --   bottom  the play / sort / discard cluster, inset from the bottom
        --           edge by the same distance the top pieces are from the top
        --
        -- The region is given the PANEL'S OWN ASPECT, so the aspect fit
        -- introduces no letterbox slack and distances in tiles map linearly
        -- to panel pixels -- which is what makes the band arithmetic exact.
        -- The width is unchanged from the old framing, so the overall scale
        -- of cards and buttons is identical; only vertical placement moved.
        --
        -- The hand itself is NOT drawn with an offset: the region is placed
        -- around it. That keeps drag's panel-to-room mapping exact -- a
        -- dragged card stays under the finger -- and keeps tooltips anchored.
        -- The buttons are the one offset element, and the offset is recorded
        -- in the hit hash as always.
        region = function()
            local hand = G and G.hand
            if not hand then return nil end

            if is_pack_state() then
                return pack_region()
            end

            local r = hand_band_layout()
            if r then return r end

            -- Panel dimensions not known yet: the old hand-centric shape.
            return {
                x = hand.T.x - PAD_SIDE,
                y = hand.T.y - PAD_TOP,
                w = hand.T.w + 2 * PAD_SIDE,
                h = hand.T.h + PAD_TOP + PAD_BOTTOM + BUTTON_DROP,
            }
        end,

        -- Trusted region: computed above from the hand's real transform and
        -- the panel's aspect, not read from a UIBox alignment box. The room
        -- clamp exists to defend against the latter, and would amputate this
        -- region's lower band (the panel is taller than the room's remaining
        -- height below the hand).
        no_clamp = true,

        draw = function(ctx)
            ctx.draw(G.hand, 0)
            local _, drop = hand_band_layout()
            ctx.draw(G.buttons, drop or BUTTON_DROP)

            -- The discard pile lives inside this region (layout.lua), so
            -- drawing it here keeps the whole discard animation on screen 2.
            -- Plays are deliberately NOT drawn here: a played hand should read
            -- as travelling up to screen 1, and letting those cards go
            -- immediately is what sells it.
            ctx.draw(G.discard, 0)

        end,

        overlay = function(ctx)
            draw_popups(ctx, G.hand)
        end,
    },

    -- Two optional HUD pieces, each behind its own toggle in
    -- Options > Settings > Dual Screen and each defaulting OFF.
    --
    -- Neither supplies a region: they are placed into the corners of whatever
    -- region the hand section has already chosen, so turning them on cannot
    -- disturb a layout that is already right.
    --
    -- Listed AFTER the hand so they are drawn after it. Placed before, the
    -- cards painted straight over the score box.
    --
    -- Both are drawn with a computed OFFSET rather than being moved. They live
    -- inside layouts the game owns -- the score is a node in the HUD, the
    -- consumables row is positioned by set_screen_positions -- and nudging a
    -- laid-out element by its role offset moves the element and leaves its
    -- children behind. The offset is recorded in the hit
    -- hash, so collision follows the pixels.
    {
        name = "hand_score",

        -- The score is the LIVE element, detached from
        -- the HUD's tree by hud.lua while the toggle is on. A detached element
        -- is reached by no screen-1 draw route at all -- the NODE pass skips
        -- parented nodes and the HUD's traversal no longer includes it -- so
        -- there is nothing to own or suppress; this section only supplies the
        -- screen-2 draw.
        -- Live during rounds -- plus a short window around HAND-LEVEL
        -- ACTIVITY, so a planet or Black Hole used in the shop or from a
        -- celestial pack shows its level-up animation HERE, where the score
        -- lives, then yields the panel back. (An always-on score in shops and
        -- packs was tried and rejected: the animation should visit, not move
        -- in.) Activity is detected by hud.lua from the score's own displayed
        -- strings, which update_hand_text rewrites through the whole
        -- animation -- mult, then chips, then level.
        live = function()
            if hud_element() == nil then return false end
            if snap().hand_is_live() and not is_pack_state() then
                return true
            end
            -- The visit window applies only where a hand can actually be
            -- levelled -- shops and packs. hud.lua stamps activity under the
            -- same condition; this end keeps the section honest even if a
            -- stale stamp survives a state change.
            if not (is_pack_state()
                    or (G.STATE ~= nil and G.STATES ~= nil
                        and G.STATE == G.STATES.SHOP)) then
                return false
            end
            local ok, recent = pcall(function()
                return require("dualscreen.hud").recent_score_activity()
            end)
            return ok and recent or false
        end,

        -- The score element itself needs no owning (detached = unreachable
        -- on screen 1), but the level-up attention flashes anchored inside it
        -- do: they are separate top-level UIBoxes, drawn by Game:draw's own
        -- passes unless suppressed here.
        owns = function(obj)
            return attention_on_score(obj)
                or attention_particles_on_score(obj)
        end,

        region = nil,

        draw = function(ctx)
            local e = hud_element()
            if not e or not e.T then return end
            -- Panel top-left, same inset as the consumables opposite. The
            -- element's T stays valid while detached: it is still a Moveable
            -- following G.HUD, so the offset is recomputed from wherever it
            -- happens to sit.
            -- Flush to the panel's left inset -- the mirrored side room was
            -- tried and read as too far in -- but level with the consumables'
            -- top edge, so the band still reads as one row.
            local tx, ty = hud_corner()
            if not tx then return end
            -- Left edge on the HAND's left edge, not the panel inset. Both
            -- are drawn in the same tile space, so matching tile x matches
            -- pixels -- and the score visibly lining up with the cards below
            -- it is what reads as aligned (the panel-inset placement sat a
            -- little left of the hand). Fallback to the inset when there is
            -- no hand to align with (the shop/pack visit window).
            local hx = G.hand and G.hand.T and G.hand.T.x or tx
            local dx = hx - e.T.x
            local dy = (ty + HUD_TOP_ROOM) - e.T.y
            ctx.draw_uie(e, dx, dy, SCORE_SCALE)

            -- The level-up flashes, riding the exact transform the score was
            -- drawn with: draw_offset anchored at e's corner is the same
            -- translate-then-scale draw_uie just applied, so a box that
            -- covers the chips element on screen 1 covers it here too. The
            -- boxes follow their anchor element by role.major, so no
            -- positions are computed -- only the score's own draw offset is
            -- re-used. Particles after their boxes, matching vanilla's order.
            for _, b in ipairs(G.I.UIBOX or {}) do
                if b.attention_text and not b.REMOVED
                   and attention_on_score(b) then
                    ctx.draw_offset(b, dx, dy, SCORE_SCALE, e.T.x, e.T.y)
                end
            end
            for _, m in ipairs(G.I.MOVEABLE or {}) do
                if not m.REMOVED and attention_particles_on_score(m) then
                    ctx.draw_offset(m, dx, dy, SCORE_SCALE, e.T.x, e.T.y)
                end
            end
        end,
    },

    {
        name = "consumables",

        -- DURING ROUNDS ONLY. In the shop the consumables row belongs back on
        -- the top screen: the shop fills the panel, and this is the same
        -- overlap that once put the joker row on top of the shop.
        -- hand_is_live() is exactly "a round is being played", so it is the
        -- test rather than a list of states to exclude.
        -- Not during booster packs either: the whole shop phase, packs
        -- included, keeps the consumables on the top screen -- they sit parked
        -- under (or beside) the joker row, where layout.reconcile always
        -- maintains a coherent position for them.
        live = function()
            return sections.consumables_on_panel()
        end,

        -- The cards' tooltips too: Card:hover parks them in G.I.POPUP, which
        -- Game:draw renders in its own pass (game.lua:2901) -- owning the area
        -- alone left them appearing on the top screen.
        owns = function(obj)
            return obj == G.consumeables
                or popup_of(obj, G.consumeables)
        end,

        region = nil,

        draw = function(ctx)
            local c = G.consumeables
            if not c or not c.T then return end

            -- A PURE DRAW-TIME OFFSET. No transforms are written at all.
            --
            -- Four attempts at positioning this by transform failed, each one
            -- layer deeper: the area's T was right but its backing lagged;
            -- hard-setting the backing left it 1.8 tiles right; centring it by
            -- hand was still off; bonding the area to the room moved it but
            -- not correctly. The cause is that a CardArea is a CHAIN -- the
            -- backing bonds to the area (cardarea.lua:310) and the cards bond
            -- to it in turn -- so writing any one link's transform leaves the
            -- others to catch up, or not.
            --
            -- A canvas translation sidesteps the whole chain: everything drawn
            -- inside it moves by exactly the same amount, backing and cards
            -- included, and nothing is left to follow. It is the same mechanism
            -- as BUTTON_DROP, and the
            -- offset is recomputed from the current T each frame so it cannot
            -- drift no matter what else moves the area.
            --
            -- My first attempt DID use this and looked wrong -- but for an
            -- unrelated reason: it targeted the corner of the framed REGION
            -- rather than of the PANEL, which is a quarter of the way down the
            -- screen. That was fixed separately in hud_corner.
            -- Offset measured against the BACKING, not the area.
            --
            -- The area's box and the rectangle you can see are not the same
            -- rect: CardArea centres the backing on the area and it carries the
            -- card-count row, so it is taller than the area and sits at a
            -- different origin. Aligning the area's corner to the panel's put
            -- the visible rectangle somewhere else -- which is the whole story
            -- of this element. Align what is drawn.
            local dx, dy, ax, ay = cons_panel_offset()
            if not dx then return end
            ctx.draw_offset(c, dx, dy, CONS_SCALE, ax, ay)
        end,

        -- Tooltips last, above everything, riding the same offset as the
        -- cards they describe. Vanilla's own placement logic puts the popup
        -- below a card this near the top of the room.
        overlay = function(ctx)
            local c = G.consumeables
            if not c or not c.cards then return end
            local dx, dy, ax, ay = cons_panel_offset()
            if not dx then return end
            for _, card in ipairs(c.cards) do
                local ch = card.children
                if ch then
                    if ch.h_popup then
                        ctx.draw_offset(ch.h_popup, dx, dy, CONS_SCALE, ax, ay)
                    end
                    if ch.d_popup then
                        ctx.draw_offset(ch.d_popup, dx, dy, CONS_SCALE, ax, ay)
                    end
                end
            end
        end,
    },

    -- Overlay menus -- New Run, Collection, Profile, Language, the
    -- pause menu, and everything else that opens over the game.
    --
    -- LAST IN THE LIST, so it is DRAWN LAST and therefore on top.
    --
    -- Sections are drawn in list order, so an overlay placed first rendered
    -- underneath the very thing it had opened over -- the main-menu stack
    -- painted straight across it. An overlay is modal and belongs on top of
    -- everything.
    --
    -- Being last costs nothing in region priority, because this section
    -- supplies no region. If it ever needs one, the list will have to stop
    -- meaning two things at once: draw order and region precedence want
    -- opposite ends for a modal layer.
    --
    -- G.OVERLAY_MENU is excluded from Game:draw's UIBOX pass by name
    -- (game.lua:2796) and drawn on its own afterwards (game.lua:2863), so the
    -- UIBox:draw wrapper sees it and the suppression works; we simply draw it
    -- ourselves instead.
    {
        name = "overlay_menu",

        -- OUTSIDE A RUN ONLY.
        --
        -- At the menu the panel is where the player is already looking, so an
        -- overlay belongs there. In a run it does not: the bottom screen is the
        -- hand, and pausing to open Options should not take it over -- the top
        -- screen is free and is where a modal over gameplay reads correctly.
        --
        -- Keyed on the STAGE rather than on a list of states, so the shop,
        -- blind select and packs are all covered by the same rule.
        live = function()
            return G and G.OVERLAY_MENU ~= nil
               and G.STAGES and G.STAGE ~= G.STAGES.RUN
        end,

        owns = function(obj)
            return obj == G.OVERLAY_MENU
        end,

        -- MODAL: this section's region wins over whatever it opened on top of,
        -- even though it is drawn last. See sections.region.
        modal = true,

        -- FIT EACH OVERLAY TO THE PANEL, rather than one zoom for all.
        --
        -- Overlays are all aligned 'cm' against G.ROOM_ATTACH
        -- (button_callbacks.lua:1339), so a centred crop of the room magnifies
        -- them about their own middle and keeps them centred. The question is
        -- how much, and a single figure cannot serve: at the zoom that suits
        -- New Run, Settings / Stats / Credits / Language are all wider than the
        -- panel.
        --
        -- Per-menu constants are not an option either -- G.FUNCS.overlay_menu
        -- stores no identifier, so there is nothing to key them on, and any
        -- overlay added later would be unhandled.
        --
        -- So the crop is derived from the overlay's own width: frame
        -- `T.w / OVERLAY_FILL` tiles and it occupies OVERLAY_FILL of the panel
        -- whatever its size. Wide menus get a wider crop and land smaller;
        -- New Run is unchanged, because OVERLAY_FILL is set from what it
        -- already measured at.
        --
        -- T.w only. A UIBox's T is an alignment box rather
        -- than a visible extent -- blind select measured 31 tiles tall in an
        -- 11.5-tile room -- so the height is not trusted, and the crop keeps the
        -- room's aspect instead.
        region = function()
            local tw = (G and G.TILE_W) or 20
            local th = (G and G.TILE_H) or 11.5

            local w = overlay_width() or 0
            if w > 0 then
                w = w / OVERLAY_FILL
            end

            -- Fall back to the fixed zoom when the measurement is not usable --
            -- and clamp at both ends, so a bad reading can only ever give the
            -- behaviour we already had rather than something worse.
            local wmin = tw / OVERLAY_ZOOM
            if w < wmin then w = wmin end
            if w > tw then w = tw end

            local h = w * (th / tw)
            return { x = (tw - w) / 2, y = (th - h) / 2, w = w, h = h }
        end,

        draw = function(ctx)
            ctx.draw(G.OVERLAY_MENU, 0)
        end,
    },

}

--------------------------------------------------------------------------
-- Derived behaviour. Both callers go through these.
--------------------------------------------------------------------------

--- Are the consumables being shown on the panel right now?
---
--- One definition, because two places must agree exactly: the section's
--- liveness, and the Card:align_h_popup wrapper in init.lua that flips a
--- consumable's tooltip to open BELOW the card while it is panel-drawn --
--- vanilla decides above-or-below from the card's ROOM position
--- (card.lua:4278), which is its parked screen-1 spot, not where the player
--- is actually touching it.
function sections.consumables_on_panel()
    return DS.active and DS.settings and DS.settings.consumables()
       and snap().hand_is_live()
       and not snap().is_pack_state()
       and G.consumeables ~= nil
end

--- Does any live section own this object? Drives screen-1 suppression.
--- Hot path: called for every drawn object, every frame. No allocation.
function sections.owns(obj)
    for i = 1, #sections.list do
        local s = sections.list[i]
        if s.live() and s.owns(obj) then
            return true
        end
    end
    return false
end

--- The tile-space rectangle screen 2 should frame, or nil if no live section
--- supplies one (in which case the caller falls back to the background view).
--- Clamp a region to the room.
---
--- Nothing outside the room is ever drawn, so a region that extends past it
--- only buys black bands -- and worse, it inflates the aspect fit and shrinks
--- everything that IS visible. G.blind_select's
--- transform is an alignment box 18.4 x 15.82 tiles starting 2.16 tiles ABOVE
--- the room, so framing on it produced a 20 x 17.42 region against an 11.5-tile
--- room, and the blind panels were squeezed into the top half of the panel.
---
--- A UIBox's T is not its visible extent. Clamping makes that harmless for
--- every section rather than something each one has to know about.
--- Allowed overshoot, in tiles, beyond each room edge.
---
--- NOT zero. The booster pack's "Choose 1" / "Skip" row
--- genuinely sits partly below the room's bottom edge, so clamping hard to the
--- room made the aspect fit believe the content was shorter than it is: it
--- over-zoomed, and the row spilled off the bottom of the panel at a size that
--- read as broken.
---
--- The clamp still does its job -- blind select's 20 x 17.42 alignment box is
--- cut down heavily -- it just no longer amputates content that is only
--- slightly outside.
local ROOM_OVERSHOOT = 1.6

local function clamp_to_room(r)
    if not r or not G then return r end
    local tw = G.TILE_W or 20
    local th = G.TILE_H or 11.5
    local x0 = math.max(-ROOM_OVERSHOOT, r.x)
    local y0 = math.max(-ROOM_OVERSHOOT, r.y)
    local x1 = math.min(tw + ROOM_OVERSHOOT, r.x + r.w)
    local y1 = math.min(th + ROOM_OVERSHOOT, r.y + r.h)
    if x1 <= x0 or y1 <= y0 then return nil end
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

--- The region, preferring any live MODAL section.
---
--- The list used to mean two things at once -- draw order and region
--- precedence -- and a modal layer wants opposite ends of each: drawn last so
--- it is on top, but framed first because it is what the player is looking at.
--- Putting the overlay first drew it underneath the menu it had opened over;
--- putting it last left it framed by whatever was behind it.
---
--- So `modal` names the second thing explicitly, and the list keeps meaning
--- only the first.
--- Returns the region AND the name of the section that supplied it. The name
--- is the ease gate in render.active_region: a region tracks moving anchors
--- (the pack box slides in, the region follows, the content thereby appears
--- STILL on the panel), so within one source the frame must snap exactly --
--- easing it turns every vanilla slide into visible swimming. Only a SOURCE
--- change is a cut worth smoothing.
function sections.region()
    for i = 1, #sections.list do
        local s = sections.list[i]
        if s.modal and s.region and s.live() then
            local r = s.region()
            if not s.no_clamp then r = clamp_to_room(r) end
            if r then return r, s.name end
        end
    end
    for i = 1, #sections.list do
        local s = sections.list[i]
        if s.region and s.live() then
            local r = s.region()
            if not s.no_clamp then r = clamp_to_room(r) end
            if r then return r, s.name end
        end
    end
    return nil
end

--- Draw every live section, in order. `ctx.draw(obj, dy)` handles the
--- transform, the draw-offset bookkeeping and the hit hash.
--- Draw every live section, then every live section's OVERLAY.
---
--- Two phases, because tooltips must sit above all sections rather than above
--- only the one that owns them. In an arcana pack the pack section draws
--- first and the hand second, so a popup drawn inside the pack's own pass ends
--- up underneath the hand -- which is exactly how the engine avoids the same
--- problem, by drawing G.I.POPUP after everything else.
function sections.draw(ctx)
    for i = 1, #sections.list do
        local s = sections.list[i]
        if s.live() then
            s.draw(ctx)
        end
    end
    for i = 1, #sections.list do
        local s = sections.list[i]
        if s.overlay and s.live() then
            s.overlay(ctx)
        end
    end
end

return sections
