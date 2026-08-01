-- balatro-dualscreen-thor -- overlay entry point.
--
-- Loaded by the single line tools/build.py appends to the game's main.lua:
--
--     require "dualscreen.init"
--
-- That append lands after main.lua's require block (line 29) and before
-- love.load runs, so every class and global callback already exists here, but
-- nothing has executed yet. This is the one place the overlay is entered.
--
-- THE RULE: wrap, do not replace. Capture the original, call through to it,
-- then adjust. A wrapper inherits LocalThunk's future fixes; a wholesale copy
-- silently reverts them and re-imports copyrighted code into this repository.
-- Any wholesale copy needs a written justification in docs/decisions/.

DS = DS or {}

DS.VERSION = "0.5"

-- True while a companion Presentation is actually up on a secondary display.
-- Derived from the Java side, never assumed. Every dual-screen path sits
-- behind this, so a device with one screen behaves exactly like a normal
-- landscape build.
DS.active = false

function DS.log(msg)
    print("[dualscreen] " .. tostring(msg))
end

local bridge   = require("dualscreen.bridge")
local snapshot = require("dualscreen.snapshot")
local events   = require("dualscreen.events")
local render   = require("dualscreen.render")
local layout   = require("dualscreen.layout")
local gamepad  = require("dualscreen.gamepad")
local settings = require("dualscreen.settings")
local buttons  = require("dualscreen.buttons")
local sections = require("dualscreen.sections")
local keyboard = require("dualscreen.keyboard")
local menu     = require("dualscreen.menu")
local led      = require("dualscreen.led")
local hud      = require("dualscreen.hud")

DS.settings = settings
pcall(settings.install)
pcall(buttons.install)
pcall(menu.install)

DS.gamepad = gamepad

DS.bridge = bridge

DS.log("native bridge available: " .. tostring(bridge.native_available))

-- Diagnostic: does LOVE see the Thor's physical controls as a joystick at all?
-- Android exposes them as an "Odin Controller" input device; whether SDL maps
-- it to a gamepad is a separate question, and Balatro's controller support
-- depends on the latter (engine/controller.lua:96 Controller:set_gamepad).
if love.joystick then
    local n = love.joystick.getJoystickCount()
    DS.log("joysticks visible to LOVE: " .. tostring(n))
    for i, j in ipairs(love.joystick.getJoysticks()) do
        DS.log(("  joystick %d: %s  gamepad=%s")
               :format(i, tostring(j:getName()), tostring(j:isGamepad())))
    end
end

--------------------------------------------------------------------------
-- set_screen_positions -- wrapped so the top screen can be relaid out once
-- the hand has moved to the panel.
--------------------------------------------------------------------------

local orig_set_screen_positions = set_screen_positions

if type(orig_set_screen_positions) ~= "function" then
    DS.log("FATAL: set_screen_positions is not a function at load time; "
           .. "injection point or upstream API has changed")
else
    function set_screen_positions()
        orig_set_screen_positions()
        -- With the hand on screen 2, redistribute what is left.
        -- Behind DS.active, so a single-screen device keeps vanilla layout.
        --
        -- The joker row's size and the consumables' position are NOT handled
        -- here any more: they are converged every tick by layout.reconcile,
        -- which is what ended the family of stale-layout bugs caused by
        -- missed relayout events. This wrapper keeps only the event-shaped
        -- work: the play-area drop and the discard move (adjust), and the
        -- card realignment on the null path (restore).
        if DS.active then
            local ok, err = pcall(layout.adjust)
            if not ok then DS.log("layout.adjust failed: " .. tostring(err)) end
        else
            local ok, err = pcall(layout.restore)
            if not ok then DS.log("layout.restore failed: " .. tostring(err)) end
        end
    end
end

--------------------------------------------------------------------------
-- Controller input for the hand.
--
-- The hand is no longer in G.DRAW_HASH, so vanilla's focus-based
-- card navigation has nothing to land on. This routes the pad into the same
-- semantic events screen 2's touch path uses.
--
-- It defers: gamepad.pressed only consumes a button when the game's own
-- controller focus is idle, so navigating to any real UI element restores
-- vanilla behaviour untouched.
--
-- Root-caused along the way: the companion Presentation was taking key focus,
-- so hardware buttons went to the second display's window instead of the game.
-- Balatro drew its controller pips (it could see the pad) but never received a
-- press. Fixed with FLAG_NOT_FOCUSABLE in CompanionPresentation.
--------------------------------------------------------------------------

-- Three routes in, because a pad's horizontal axis may arrive as any of them
-- and which one is not knowable in advance. On this device the D-pad comes
-- through as KEYBOARD arrow keys.
local function hook(name, fn)
    local orig = love[name]
    love[name] = function(a, b, ...)
        local ok, consumed = pcall(fn, a, b)
        if ok and consumed then return end
        if orig then return orig(a, b, ...) end
    end
end

-- Android's soft keyboard produces love.textinput, which vanilla does not
-- implement at all -- see keyboard.lua. Routed into the game's own per-key
-- entry point so a seed can actually be typed on a device with no keys.
hook("textinput", function(text) return keyboard.textinput(text) end)

hook("gamepadpressed", function(_joystick, button) return gamepad.pressed(button) end)
hook("gamepadreleased", function(_joystick, button) return gamepad.released(button) end)
hook("keypressed",     function(key)               return gamepad.keypressed(key) end)
-- Hooked LAST so it is checked FIRST: while the soft keyboard is up it must
-- consume the keypressed twin of each character before anything else sees it.
hook("keypressed",     function(key)               return keyboard.keypressed(key) end)
DS.log("wrapped gamepadpressed / keypressed")

--------------------------------------------------------------------------
-- Take the hand and its buttons off screen 1.
--
-- SUPPRESS THE RENDER, DO NOT REMOVE THE OBJECTS. Game logic reads G.hand
-- constantly -- #G.hand.cards, G.hand.highlighted, the end-of-round checks at
-- game.lua:3056 and :3063 -- and removing it breaks things in delayed,
-- non-obvious ways. G.buttons is bonded to G.hand (major = G.hand, bond =
-- 'Weak'), so it follows the hand rather than needing its own handling.
--
-- Wrapping the class methods rather than touching states.visible, because
-- `visible` is read by game logic as well as by drawing, and this needs to be
-- purely a rendering concern.
--
-- Both wrappers are no-ops unless DS.active, so a single-screen device
-- renders exactly as vanilla does.
--------------------------------------------------------------------------

-- Set only while render.draw is running, so the screen-2 pass draws the very
-- objects screen 1 is skipping.
DS.rendering_screen2 = false

--- Derived from the section registry rather than restated here.
---
--- This list and render.draw's used to be two hardcoded lists that had to
--- agree. They no longer can disagree: an object is hidden from screen 1
--- exactly when a live section claims it, and every section draws what it
--- claims. Getting that wrong makes an object vanish from the game entirely
--- (hidden but not drawn) or appear twice, and neither is obvious in a diff.
local function hidden_from_screen1(obj)
    if not DS.active or DS.rendering_screen2 then
        return false
    end
    return sections.owns(obj)
end

-- Set to a CardArea that its parent UIBox must NOT draw this pass, because the
-- section wants to draw it separately with a different transform: the
-- booster pack scales its cards independently of the pack's own UI.
DS.defer_area = nil

if CardArea and CardArea.draw then
    local orig_cardarea_draw = CardArea.draw
    function CardArea:draw(...)
        if hidden_from_screen1(self) then return end
        if DS.rendering_screen2 and DS.defer_area == self then return end
        return orig_cardarea_draw(self, ...)
    end
    DS.log("wrapped CardArea:draw")
end

-- The screen-2 render pass must not register anything for collision.
--
-- G.DRAW_HASH is the list Controller hit-tests the cursor against
-- (engine/controller.lua:965-973), for touch AND for gamepad focus navigation.
-- Card:draw (card.lua:4571) and CardArea:draw (cardarea.lua:317) add to it.
--
-- Drawing the hand a second time for screen 2 therefore re-registered every
-- card at its SCREEN 1 coordinates: invisible there, but still hittable, so
-- touches on the empty lower third of screen 1 still selected cards, and
-- gamepad focus could snap to something nobody can see.
--
-- The hash is rebuilt once per frame (misc_functions.lua:624), and our pass
-- runs after Game:draw, so our additions survived into the next frame's input
-- handling. Suppressing them during the screen-2 pass is the fix.
-- DIVERT those registrations, do not discard them.
--
-- Suppressing them was right for screen 1 and stays. But they are exactly the
-- collision data screen 2 needs, expressed in the same room coordinates, and
-- throwing them away meant screen-2 input had to be hand-built: four hardcoded
-- rects for the buttons plus card indices. That does not survive a shop or a
-- menu, where the controls are many and change constantly.
--
-- So the screen-2 pass now fills DS.HASH2, a second draw hash, and screen-2
-- touches are resolved against it the same way Controller does against
-- G.DRAW_HASH. Whatever we draw on screen 2 becomes touchable on screen 2, for
-- free, and stays correct as the UI changes.
DS.HASH2 = {}

-- Membership view of the same pass, keyed by object.
--
-- DS.HASH2 is a LIST, walked back-to-front by hit_test because hit order is
-- draw order. The controller fix needs a different question -- "is this
-- particular node one we drew on screen 2?" -- asked once per frame about one
-- node, and answering it by scanning the list would be a linear search for a
-- constant-time fact. Filled and cleared in lockstep with the list.
DS.HASH2_SET = {}

-- Draw-time transform currently in force on the screen-2 pass.
--
--   hash_dy              y offset in tiles
--   hash_s               uniform scale
--   hash_cx / hash_cy    the tile-space point that scale is applied about
--
-- Each hash entry records whatever applied when it registered, and hit_test
-- undoes it. collides_with_point tests a node's REAL transform, so ANY
-- draw-time adjustment has to be reversible here or what is drawn and what is
-- touchable drift apart.
DS.hash_dx = 0
DS.hash_dy = 0
DS.hash_s  = 1
DS.hash_cx = 0
DS.hash_cy = 0

if add_to_drawhash then
    local orig_add_to_drawhash = add_to_drawhash
    function add_to_drawhash(obj)
        if DS.rendering_screen2 then
            DS.HASH2_SET[obj] = true
            DS.HASH2[#DS.HASH2 + 1] = {
                n  = obj,
                dx = DS.hash_dx or 0,
                dy = DS.hash_dy or 0,
                s  = DS.hash_s or 1,
                cx = DS.hash_cx or 0,
                cy = DS.hash_cy or 0,
            }
            return
        end
        return orig_add_to_drawhash(obj)
    end
    DS.log("wrapped add_to_drawhash")
end

--- Topmost node under a screen-2 pixel, or nil.
---
--- Mirrors Controller:get_collision_list (engine/controller.lua:955-983): walk
--- the hash BACKWARDS so the last thing drawn is hit first, skip REMOVED nodes,
--- and require states.collide.can just as the controller does before treating a
--- node as a collision target.
function DS.hit_test(px, py, want_hover)
    if not DS.active or #DS.HASH2 == 0 then return nil end
    local tx, ty = render.panel_to_tile(px, py, DS.panel_w or 0, DS.panel_h or 0)
    if not tx then return nil end

    -- COORDINATE SPACE. collides_with_point wants the point in the same space
    -- vanilla passes, which is G.CURSOR.T -- and that is ABSOLUTE tiles:
    --
    --     G.CURSOR.T.x = cursor_position.x / (G.TILESCALE * G.TILESIZE)
    --                                                (engine/controller.lua:178)
    --
    -- Node transforms, by contrast, are ROOM-RELATIVE; the conversion between
    -- them is visible at button_callbacks.lua:504, which writes
    -- `G.CURSOR.T.x - e.parent.T.x - G.ROOM.T.x`. collides_with_point does that
    -- subtraction itself, via the container translation.
    --
    -- panel_to_tile returns ROOM-RELATIVE tiles, because its original caller is
    -- the drag path, which assigns straight to card.T and therefore wants
    -- room-relative. So it must NOT change -- the room origin is added here,
    -- for collision only.
    --
    -- Getting this wrong is not subtle in effect but is very subtle to spot:
    -- every hit test was short by G.ROOM.T, about 135 px left and 64 px up on
    -- this panel, so taps quietly resolved to whatever sat up and to the left.
    -- It surfaced as one button in a row of four appearing dead.
    local room_x = (G.ROOM and G.ROOM.T and G.ROOM.T.x) or 0
    local room_y = (G.ROOM and G.ROOM.T and G.ROOM.T.y) or 0

    local point = { x = 0, y = 0 }
    for i = #DS.HASH2, 1, -1 do
        local e = DS.HASH2[i]
        local v = e.n
        -- Undo whatever draw-time offset was in force when v registered, so
        -- the point is compared in the space v was actually drawn in.
        -- Undo the draw-time transform, in the order it was applied: the
        -- scale about (cx, cy) first, then the y offset.
        local px2, py2 = tx, ty
        local sc = e.s or 1
        if sc ~= 1 and sc > 0 then
            px2 = (e.cx or 0) + (px2 - (e.cx or 0)) / sc
            py2 = (e.cy or 0) + (py2 - (e.cy or 0)) / sc
        end
        point.x = px2 - (e.dx or 0) + room_x
        point.y = py2 - (e.dy or 0) + room_y
        if not v.REMOVED
           and v.states
           and ((want_hover and v.states.hover and v.states.hover.can)
                or (not want_hover
                    and v.states.collide and v.states.collide.can))
           and v:collides_with_point(point) then
            return v
        end
    end
    return nil
end

--- Topmost node under a screen-2 pixel that CAN HOVER, or nil.
---
--- A separate predicate from DS.hit_test, and the distinction is the fix for
--- the skip tags' tooltips. `collide.can` is the CLICK/controller contract,
--- and the blind-select tag sprites sit in the hash without it -- so the
--- collide-gated walk skipped them and touch-hover landed on some ancestor
--- row with no tooltip to give. The honest question for a HOLD is "what is
--- the topmost thing here that responds to hover", which is exactly
--- states.hover.can. Topmost still wins, so a card's own hover beats its
--- area's, and the tag sprite -- drawn after everything it sits on -- beats
--- its containers.
function DS.hover_test(px, py)
    return DS.hit_test(px, py, true)
end

--- Room-relative tile coordinates for a point in panel pixels.
---
--- Exposed because layout in ROOM space is not enough on its own: the room is
--- letterboxed into the panel, so a fixed tile inset lands at a different pixel
--- inset on each edge. Anything that wants to sit a set number of PIXELS from
--- the panel edge has to ask where that is.
function DS.panel_tile(px, py)
    return render.panel_to_tile(px, py, DS.panel_w or 0, DS.panel_h or 0)
end

--- Click whatever is under a screen-2 pixel.
---
--- EVERY node has a click(): UIElement:click (ui.lua:965) runs the debounce,
--- one_press, G.FUNCS[button], choice groups, sound and jiggle; Card:click
--- (card.lua:4610) toggles highlight through can_highlight and guards
--- HAND_PLAYED; CardArea:click (cardarea.lua:613) handles areas; and
--- Node:click (node.lua:383) is an empty default for everything else.
---
--- So this dispatches polymorphically and inherits all of that, rather than
--- reimplementing any of it. It is also strictly better than the old
--- TOGGLE_CARD path, which duplicated the highlight toggle WITHOUT
--- can_highlight or the HAND_PLAYED guard.
--- Tell the game the active input device is TOUCH, exactly as a real touch on
--- screen 1 would.
---
--- Two places in vanilla gate on this, and both broke screen-2 touch on a
--- device that always has a gamepad attached:
---
---   cardarea.lua:113  can_highlight -- with HID.controller set, ONLY a 'hand'
---                     area may be highlighted, so taps on pack, shop and
---                     joker cards were refused outright.
---   cardarea.lua:264  every frame, `if G.CONTROLLER.HID.controller and
---                     self ~= G.hand then self:unhighlight_all() end` -- so
---                     even a highlight that did get through was wiped on the
---                     very next frame.
---
--- An earlier attempt flipped the flags only for the duration of the click and
--- restored them immediately. That got past can_highlight but walked straight
--- into the second rule: the selection appeared and vanished as the finger
--- lifted. The flag is not a per-call detail, it is the game's record of which
--- device the player is using, and it has to persist.
---
--- Going through set_HID_flags rather than writing the fields keeps every
--- derived flag (pointer, dpad, cursor visibility) consistent, and it is
--- self-correcting: the next controller press calls it again with 'button'.
function DS.mark_touch_input()
    local c = G and G.CONTROLLER
    if c and c.set_HID_flags then
        pcall(c.set_HID_flags, c, "touch")
    end
end

local NODE_CLICK = Node and Node.click   -- the empty default, to skip past

DS.CLICK_DEBUG = false
DS.HUD_DEBUG = false
DS.PACK_DEBUG = false

local function describe(v)
    if not v then return "nil" end
    local kind = (v.config and v.config.button) and ("button:" .. tostring(v.config.button))
        or (v.ability and "card")
        or (v.cards and "cardarea")
        or (v.UIRoot and "uibox")
        or "node"
    local t = v.T or {}
    return ("%s T=(%.2f,%.2f %.2fx%.2f) collide=%s")
        :format(kind, t.x or -1, t.y or -1, t.w or -1, t.h or -1,
                tostring(v.states and v.states.collide and v.states.collide.can))
end

function DS.click_at(px, py)
    -- THE INTRO IS NOT MADE OF NODES. During the splash there is nothing on
    -- screen 2 to hit-test against, and vanilla does not resolve a node there
    -- either: Controller:queue_L_cursor_press special-cases the state and
    -- sends itself an escape key press (controller.lua:1018-1024), which is
    -- what makes a tap anywhere on screen 1 skip to the menu. A tap down here
    -- was falling through the hit test and doing nothing. Route it into the
    -- game's own skip rather than calling delete_run/main_menu ourselves, so
    -- the two screens skip by exactly the same path.
    --
    -- UNCONDITIONAL, with no setting behind it. Skipping the intro is what a
    -- tap already means on screen 1; making the panel agree is restoring an
    -- expectation, not adding a feature, and there is nothing else a tap
    -- during the splash could plausibly mean.
    if G and G.STATE and G.STATES
       and G.STATE == G.STATES.SPLASH and G.CONTROLLER then
        pcall(function() G.CONTROLLER:queue_L_cursor_press(0, 0) end)
        return true
    end

    local node = DS.hit_test(px, py)
    if DS.CLICK_DEBUG then
        local tx, ty = render.panel_to_tile(px, py, DS.panel_w or 0, DS.panel_h or 0)
        DS.log(("click %d,%d -> tile %.2f,%.2f  hash=%d  hit=%s")
            :format(px, py, tx or -1, ty or -1, #DS.HASH2, describe(node)))
        if not node then
            -- What WAS registered near there? Dump the button-bearing entries.
            for i = #DS.HASH2, 1, -1 do
                local e = DS.HASH2[i]
                if e.n and e.n.config and e.n.config.button then
                    DS.log(("   cand %s dy=%.2f"):format(describe(e.n), e.dy or 0))
                end
            end
        end
    end
    local guard = 0
    while node and guard < 32 do
        guard = guard + 1

        -- Find the nearest ancestor that will ACTUALLY DO SOMETHING.
        --
        -- Two cases, and the distinction matters. A UIElement's click is inert
        -- unless config.button is set (ui.lua:966 gates the whole body on it),
        -- so decorative elements -- labels, container rows, the box around the
        -- sort buttons -- have a click method that does nothing. Stopping at
        -- one of those swallows the tap instead of letting it reach the button
        -- underneath. Observed: a tap near the sort buttons resolving to
        --     hit=node T=(9.83,10.92 0.75x0.35)
        -- which was the "Sort Hand" label, so the tap did nothing at all.
        --
        -- Cards and card areas are the other case: Card:click (card.lua:4610)
        -- and CardArea:click (cardarea.lua:613) are real overrides with no
        -- config.button, and must be taken as-is.
        local cfg = node.config
        local is_ui_element = cfg ~= nil and node.UIBox ~= nil
        local actionable
        if is_ui_element then
            actionable = cfg.button ~= nil
        else
            actionable = node.click ~= nil and node.click ~= NODE_CLICK
        end

        if actionable then
            DS.mark_touch_input()
            local ok, err = pcall(node.click, node)
            if not ok then
                DS.log("click failed: " .. tostring(err))
            end
            if DS.CLICK_DEBUG and node.ability then
                local ch = node.children or {}
                DS.log(("  after click: highlighted=%s use_button=%s area=%s hid.ctrl=%s")
                    :format(tostring(node.highlighted),
                            tostring(ch.use_button ~= nil),
                            tostring(node.area and node.area.config
                                     and node.area.config.type),
                            tostring(hid and hid.controller)))
            end
            return true
        end
        node = node.parent
    end
    return false
end

-- Individual Cards too.
--
-- G.FUNCS.use_card removes the booster pack from its area before opening it
-- (`if card.area then card.area:remove_card(card) end`,
-- button_callbacks.lua:2210), and slides the shop off-screen just above. So
-- the card that plays the opening explosion is a PARENTLESS, TOP-LEVEL Card,
-- rendered by Game:draw's I.CARD pass -- reachable through neither the
-- CardArea wrapper nor the UIBox one. It kept exploding on screen 1 while the
-- pack opened on screen 2.
if Card and Card.draw then
    local orig_card_draw = Card.draw
    function Card:draw(...)
        if hidden_from_screen1(self) then
            -- STILL REGISTER FOR COLLISION, even though nothing is drawn.
            --
            -- Card:draw is what calls add_to_drawhash (card.lua:4571), so
            -- suppressing it outright also removed these cards from
            -- G.DRAW_HASH -- and vanilla's CONTROLLER focus walks that list.
            -- The result was pack cards that could not be reached with the
            -- stick at all, because focus had nothing to land on.
            --
            -- This is the exact inverse of the phantom-touch bug, and
            -- the trade is deliberately the opposite way round. There the hand
            -- had to leave the hash, because leaving it in made invisible cards
            -- touchable at their old screen-1 positions across the whole lower
            -- third of the screen. Here the cards are small, the region is one
            -- the player is not touching, and the alternative -- teaching
            -- gamepad.lua to navigate every relocated card area itself -- is a
            -- great deal of machinery to replace something the game already
            -- does correctly.
            if add_to_drawhash then add_to_drawhash(self) end
            return
        end
        return orig_card_draw(self, ...)
    end
    DS.log("wrapped Card:draw")
end

-- A consumable's tooltip opens BELOW the card while it is on the panel.
--
-- Vanilla picks the direction from the card's ROOM y -- below when
-- `T.y < G.CARD_H*0.8`, above otherwise (Card:align_h_popup, card.lua:4278).
-- The consumables' room position is their PARKED screen-1 spot under the
-- joker row (y ~ 3.9), so vanilla chose "above" -- correct for where the
-- transform is, wrong for the panel, where the cards sit at the top edge and
-- the tooltip landed on top of them. The wrapper post-processes the returned
-- config, so every other case keeps vanilla's decision, offsets included.
if Card and Card.align_h_popup then
    local orig_align_h_popup = Card.align_h_popup
    function Card:align_h_popup(...)
        local conf = orig_align_h_popup(self, ...)
        if conf and conf.type == "tm"
           and self.area == G.consumeables
           and sections.consumables_on_panel() then
            conf.type = "bm"
            -- Mirror vanilla's own 'bm' y-offsets (card.lua:4295-4299).
            conf.offset.y = (self.children and self.children.focused_ui)
                            and 0.12 or 0.1
        end
        return conf
    end
    DS.log("wrapped Card:align_h_popup")
end

-- Particles too.
--
-- The booster-pack opening animation is three Particles objects --
-- G.booster_pack_sparkles / _stars / _meteors (game.lua:3351, 3539, 3550) --
-- and Particles extends Moveable, so Game:draw renders them from the
-- I.MOVEABLE pass rather than through CardArea or UIBox. Owning them was
-- therefore not enough to hide them: the pack opened on screen 2 while its
-- animation played on screen 1.
if Particles and Particles.draw then
    local orig_particles_draw = Particles.draw
    function Particles:draw(...)
        if hidden_from_screen1(self) then return end
        return orig_particles_draw(self, ...)
    end
    DS.log("wrapped Particles:draw")
end

if UIBox and UIBox.draw then
    local orig_uibox_draw = UIBox.draw
    function UIBox:draw(...)
        if hidden_from_screen1(self) then return end
        return orig_uibox_draw(self, ...)
    end
    DS.log("wrapped UIBox:draw")
end

--------------------------------------------------------------------------
-- The per-frame loop: poll events in, push snapshots out.
--
-- love.update is the right hook: it runs every frame regardless of game
-- state, and acting on input before the frame is drawn keeps the round trip
-- to a single frame.
--
-- Pushing is EVENT DRIVEN, not per frame. ADR 0001 measured full-panel
-- readback at 3.71 ms, affordable per frame but pointless -- the hand only
-- changes on deal, select, sort, play and discard. The signature check below
-- deliberately excludes card positions, because the ambient sway in
-- cardarea.lua means the hand is never *visually* static, and a
-- position-sensitive check would fire every single frame.
--------------------------------------------------------------------------

local orig_update = love.update
--- Is it safe to call set_screen_positions right now?
---
--- STAGE == RUN is NOT sufficient. Vanilla's RUN branch dereferences G.hand,
--- G.play, G.jokers, G.consumeables, G.deck and G.discard unconditionally
--- (common_events.lua:2-26), and the stage flips to RUN before those areas
--- exist. Observed during run start-up as
---     relayout on hand liveness failed:
---         functions/common_events.lua:3: attempt to index field 'hand' (a nil value)
--- Harmless because the call is pcall'd, but the relayout it was meant to do
--- silently did not happen, which is the failure mode worth avoiding.
local function can_relayout()
    if type(set_screen_positions) ~= "function" then return false end
    if not G or not G.STAGES or G.STAGE ~= G.STAGES.RUN then return false end
    return G.hand and G.play and G.jokers and G.consumeables
       and G.deck and G.discard and true or false
end

local last_signature = nil
local last_hand_live = nil
local last_active = nil

-- Panel size is re-queried rather than cached: the Presentation is recreated
-- by lifecycle events, and a recreated one may differ.
DS.panel_w, DS.panel_h = 0, 0

function love.update(dt)
    if orig_update then
        orig_update(dt)
    end

    -- Axis handling. The stick produces no callback events on this pad, so it
    -- is polled -- the same way Controller:update_axis does
    -- (engine/controller.lua:589). Called before every gate so the diagnostic
    -- reports regardless of game state.
    pcall(gamepad.dump_axes)
    pcall(gamepad.sync_focus)
    pcall(keyboard.update)

    -- The top-screen layout and the hand score are RECONCILED every
    -- tick rather than adjusted on events. Both are idempotent -- a quiet tick
    -- costs comparisons -- and both gate themselves on game state internally,
    -- including the null paths (toggle off, companion gone), so they are not
    -- behind DS.active here.
    pcall(layout.reconcile)
    pcall(hud.reconcile)

    -- The frame-rate cap. One idempotent assignment per tick:
    -- vanilla's love.run sleeps the remainder of 1/G.FPS_CAP each frame
    -- (main.lua:81-82) and nothing else writes the global, so this is the
    -- entire mechanism. 60 halves CPU/GPU work against the ~119 fps
    -- free-run; "off" means 120 -- the panel's refresh -- rather than
    -- vanilla's unbounded 500, which the menu was measured wasting at
    -- 142 fps once the frame path stopped throttling it.
    G.FPS_CAP = settings.fps60() and 60 or 120

    -- THE CONTROLLER PRESS ON A SCREEN-2 SECTION.
    --
    -- Focus navigation on blind select and the cash-out screen worked while
    -- pressing A did nothing, and the split is exactly where the two systems
    -- get their facts from. Focus is built from G.MOVEABLES
    -- (controller.lua:1150), which every element is in whether we draw it or
    -- not -- so the highlight moves correctly. The PRESS resolves through
    -- L_cursor_press, whose target is `self.hovering.target or
    -- self.focused.target` (controller.lua:1049); hovering comes from
    -- set_cursor_hover, which trusts the focused node only when
    -- `focused.target.states.collide.is` is set; and that flag is set by
    -- get_cursor_collision walking G.DRAW_HASH -- which is exactly what Task
    -- 6.1 diverts for anything we draw on screen 2, so their screen-1 ghosts
    -- are not touchable. The flag stayed false, hover resolved elsewhere, and
    -- the click went somewhere harmless.
    --
    -- THE TEST IS HASH MEMBERSHIP, NOT OWNERSHIP. The first attempt asked
    -- sections.owns(node) and sections.owns(node.UIBox), and was a no-op: the
    -- blind's Select button lives in G.blind_select_opts.small/big/boss, which
    -- are their OWN UIBoxes nested as object nodes inside G.blind_select
    -- (UI_definitions.lua:1447-1449), so neither the element nor its box is
    -- the object the section names. Ownership is about top-level draw objects
    -- and the focused node is a leaf several boxes down. DS.HASH2_SET answers
    -- the question that actually matters -- did WE draw this node -- for any
    -- depth, in any section, with no per-section knowledge.
    --
    -- Two wraps, because the flag alone is not enough. Restoring collide.is
    -- fixes hover (and so tooltips and highlight states) by letting vanilla's
    -- own branch fire. The press wraps then pin cursor_down/cursor_up to the
    -- focused node, which is what vanilla would have resolved to had the node
    -- been in the hash. Both are one-field corrections after vanilla has done
    -- its work, and both are inert on the null path: with no companion display
    -- nothing is drawn on screen 2, the set is empty, and neither fires.
    -- A vanilla crash guard: can_skip_booster on a dead pack.
    --
    --   functions/button_callbacks.lua:2133: attempt to index field 'cards'
    --   (a nil value)
    --
    -- Reported after buying in the shop and opening the pack that came with it.
    -- The line is
    --
    --   if G.pack_cards and (G.pack_cards.cards[1]) and ...
    --
    -- which assumes that a non-nil G.pack_cards is a live one. It is not. Vanilla
    -- NEVER assigns nil to G.pack_cards -- it is only ever overwritten by the next
    -- pack (UI_definitions.lua:1631 and its four siblings) -- while CardArea:remove
    -- sets `self.cards = nil` (cardarea.lua:657-659). So the instant a pack closes,
    -- G.pack_cards is a removed area whose `.cards` is nil, and the guard in front
    -- of the index tests the wrong thing.
    --
    -- What makes that reachable is UIElement:update calling the element's func
    -- every frame (ui.lua:948) for every element in G.MOVEABLES -- tree membership
    -- is irrelevant, the same fact the hand-score detach in hud.lua relies on. So
    -- any Skip button that outlives its pack's CardArea by even one frame crashes
    -- the game. Vanilla normally removes both together inside G.booster_pack:remove
    -- (button_callbacks.lua:2576), which is why this is rare rather than constant.
    --
    -- Wrapped, not patched: when the state is sane this calls straight through and
    -- vanilla decides everything. It only intervenes in the state vanilla cannot
    -- survive, and does what the missing guard would have done -- the button is
    -- not skippable when there is no pack.
    --
    -- Installed lazily: G.FUNCS.can_skip_booster is assigned while the game
    -- starts up, after this file is required, so there is nothing to wrap yet
    -- at load time.
    if not DS._skip_guard and G.FUNCS and G.FUNCS.can_skip_booster then
        DS._skip_guard = true
        local orig_can_skip = G.FUNCS.can_skip_booster
        local warned = false
        G.FUNCS.can_skip_booster = function(e)
            if G.pack_cards and not G.pack_cards.cards then
                if not warned then
                    warned = true
                    DS.log(("can_skip_booster on a dead pack area"
                            .. " (booster_pack=%s state=%s) -- guarded")
                           :format(tostring(G.booster_pack ~= nil),
                                   tostring(G.STATE)))
                end
                if e and e.config then
                    e.config.colour = G.C.UI.BACKGROUND_INACTIVE
                    e.config.button = nil
                end
                return
            end
            return orig_can_skip(e)
        end
        DS.log("wrapped can_skip_booster (dead-pack guard)")
    end

    if not DS._controller_wrapped and Controller and Controller.set_cursor_hover
       and Controller.L_cursor_press and Controller.L_cursor_release then
        DS._controller_wrapped = true

        --- The node the pad has focused, if we drew it on screen 2.
        local function focused_on_panel(self)
            local f = self.focused and self.focused.target
            if not f or f.REMOVED then return nil end
            if not (self.HID and self.HID.controller) then return nil end
            if not DS.HASH2_SET[f] then return nil end
            return f
        end

        local orig_hover = Controller.set_cursor_hover
        Controller.set_cursor_hover = function(self, ...)
            local f = focused_on_panel(self)
            if f and f.states and f.states.collide and not f.states.collide.is then
                f.states.collide.is = true
            end
            return orig_hover(self, ...)
        end

        local orig_press = Controller.L_cursor_press
        Controller.L_cursor_press = function(self, ...)
            orig_press(self, ...)
            local f = focused_on_panel(self)
            if f and f.states and f.states.click and f.states.click.can
               and self.cursor_down.target ~= f then
                self.cursor_down.target = f
            end
        end

        local orig_release = Controller.L_cursor_release
        Controller.L_cursor_release = function(self, ...)
            orig_release(self, ...)
            local f = focused_on_panel(self)
            if f and self.cursor_up.target ~= f then
                self.cursor_up.target = f
            end
        end

        -- The analog stick's route into the hand cursor. Vanilla
        -- converts stick deflection to dpleft/dpright button presses
        -- (handle_axis_buttons, controller.lua:561-573), which arrive here --
        -- NOT through love.gamepadpressed, so the hook in gamepad.lua never
        -- sees them. While the hand cursor owns horizontal navigation, those
        -- presses are its; otherwise vanilla navigates as normal. This is the
        -- single interception point that ends the stick being handled by both
        -- systems at once.
        local orig_bpu = Controller.button_press_update
        Controller.button_press_update = function(self, button, dt)
            if (button == "dpleft" or button == "dpright")
               and gamepad.owns_horizontal() then
                -- Vanilla would have stamped this for its hold-repeat
                -- machinery (button_hold_update re-calls press_update);
                -- keeping the stamp keeps hold-to-scroll working for ours.
                self.held_button_times[button] = 0
                pcall(gamepad.route, button == "dpleft" and "left" or "right")
                return
            end
            return orig_bpu(self, button, dt)
        end

        DS.log("wrapped Controller hover/press for screen-2 sections")
    end

    -- Companion present is a hardware/lifecycle fact; DS.active additionally
    -- respects the player's Options > Settings > Dual Screen toggle. Keeping
    -- them separate matters: when the toggle is off we still want to PAINT the
    -- panel (black), which needs the companion to be present, while the hand
    -- goes back to screen 1.
    DS.companion_present = bridge.companion_showing()
    DS.active = DS.companion_present and settings.enabled()
    if DS.active ~= last_active then
        last_active = DS.active
        DS.log("companion active: " .. tostring(DS.active))
        last_signature = nil
        DS.panel_w, DS.panel_h = 0, 0

        -- DS.active going false -- because the player double-tapped
        -- screen 2 away, or the companion vanished -- must put the hand back on
        -- screen 1, or the game is unplayable with no way to recover.
        --
        -- The draw suppression already keys off DS.active, so the hand
        -- reappears by itself. What does NOT happen by itself is the layout:
        -- set_screen_positions only runs on stage change, so without this the
        -- hand would return into a screen still laid out as though it were
        -- absent. Re-running it restores vanilla positions (or re-applies the
        -- layout adjustment) immediately.
        -- Only in a run. set_screen_positions' MAIN_MENU branch dereferences
        -- G.title_top (common_events.lua:33), which does not exist while the
        -- menu is still building -- and the layout only matters in a run
        -- anyway, since that is the only place the hand moves between screens.
        if can_relayout() then
            local ok, err = pcall(set_screen_positions)
            if not ok then DS.log("relayout on toggle failed: " .. tostring(err)) end
        end
    end

    -- Relayout when the HAND'S LIVENESS changes, not only on stage change.
    --
    -- set_screen_positions is called by the game on STAGE transitions, and
    -- moving between hand play and the shop is a STATE transition inside
    -- STAGE.RUN -- so it never fired, and whatever layout was in force when the
    -- run started simply persisted.
    --
    -- That is what put the joker row on top of the shop. layout.adjust drops
    -- the top row by 1.6 tiles because the hand has vacated the bottom of
    -- screen 1, which is true during hand play and false in the shop, where the
    -- shop's own panel fills that space. Without a relayout on the transition,
    -- the drop applied in the shop too and the jokers overlapped it while the
    -- top third of the screen sat empty.
    local live_now = DS.active and snapshot.hand_is_live() or false
    if live_now ~= last_hand_live then
        last_hand_live = live_now
        if can_relayout() then
            local okl, errl = pcall(set_screen_positions)
            if not okl then DS.log("relayout on hand liveness failed: " .. tostring(errl)) end
        else
            -- Not ready yet: leave last_hand_live unset so the transition is
            -- retried once the areas exist, rather than being consumed here.
            last_hand_live = nil
        end
    end

    if not DS.companion_present then
        return
    end

    -- Re-read the panel size EVERY tick, not just once.
    --
    -- This used to be `if DS.panel_w == 0`, so the size was latched on first
    -- sight and never revisited. But the Java side tears the Presentation down
    -- and rebuilds it whenever the display changes (CompanionDisplayManager
    -- .onDisplayChanged), and the rebuilt window can come back a different
    -- size -- transposed, in the rotation case, since the panel is natively
    -- portrait and presented rotated.
    --
    -- When that happened, LOVE carried on rendering and pushing at the OLD
    -- dimensions into a differently-shaped view: garbage on screen 2, with
    -- nothing in the log to say why. Re-reading makes it self-healing, and
    -- render.get_canvas already rebuilds when w/h change.
    --
    -- Cheap enough to do unconditionally: a JNI getter returning a short
    -- string, at most once per push (30 Hz).
    local w, h = bridge.panel_size()
    if w and w > 0 and (w ~= DS.panel_w or h ~= DS.panel_h) then
        DS.log(("panel size %dx%d (was %dx%d)"):format(w, h, DS.panel_w, DS.panel_h))
        DS.panel_w, DS.panel_h = w, h
        last_signature = nil   -- geometry changed, so the last snapshot is stale
    end

    -- 1. Drain events from screen 2 and apply them.
    local applied = false
    for _, ev in ipairs(bridge.poll_events()) do
        if events.dispatch(ev) then
            applied = true
        end
    end

    -- 2. Any mutation invalidates the generation the companion was working
    --    against, so bump before the next push.
    if applied then
        bridge.bump()
        last_signature = nil
    end

    -- 3. Push the snapshot if the *meaning* changed. Card rects come from the
    --    renderer, since under route (b) Lua is the only side that knows where
    --    each card ended up on the panel.
    -- No more ui= rects. Java hit-tests nothing now; it reports the
    -- tap coordinate and DS.click_at resolves it. Card rects stay, because a
    -- DRAG still has to follow one specific card across frames.
    -- pcall'd, like every other overlay entry point. render.draw has been
    -- protected from the start, but this path was not, and it matters: a
    -- stale call to a removed local resolved as a nil global,
    -- and took the WHOLE GAME down to Balatro's crash screen rather than
    -- degrading to a blank panel. An overlay fault must never do that.
    local rects = nil
    if DS.panel_w > 0 then
        local okr, res = pcall(render.card_rects, DS.panel_w, DS.panel_h)
        if okr then
            rects = res
        else
            DS.log("card_rects failed: " .. tostring(res))
        end
    end
    local snap = snapshot.build(bridge.generation, rects)
    local sig = snapshot.signature(snap)
    if sig ~= last_signature then
        last_signature = sig
        if not applied then
            snap.generation = bridge.bump()
        end
        bridge.push(snap)
    end
end

--------------------------------------------------------------------------
-- Skip-tag tooltips open ABOVE their tag on the panel.
--
-- The tag sprite's own hover positions its tooltip to the LEFT
-- (h_popup_config align 'cl', tag.lua:526) -- sensible where vanilla shows
-- tags, and wrong on the panel, where the Small Blind column sits near the
-- left edge and the tooltip landed off-screen. Every tag sprite carries its
-- own hover CLOSURE, so the one shared seam they all pass through is
-- Node.hover itself: rewrite the placement just before the tooltip is
-- constructed. Tag sprites are identified by config.tag, which Tag:generate_UI
-- sets on exactly them (tag.lua:511). Null path: no companion, vanilla
-- placement untouched.
--------------------------------------------------------------------------

if Node and Node.hover then
    local orig_node_hover = Node.hover
    function Node:hover(...)
        if DS.active and self.config and self.config.tag
           and self.config.h_popup_config then
            self.config.h_popup_config.align = "tm"
            self.config.h_popup_config.offset =
                self.config.h_popup_config.offset or {}
            self.config.h_popup_config.offset.x = 0
            self.config.h_popup_config.offset.y = -0.13
        end
        return orig_node_hover(self, ...)
    end
    DS.log("wrapped Node:hover (tag tooltips above)")
end

--------------------------------------------------------------------------
-- The frame push.
--
-- Hooked on love.draw rather than love.update because the game objects must
-- have been laid out for this frame before we render them, and because
-- Game:draw leaves the canvas and shader unset -- a clean state to start from.
--
-- Rate-capped rather than every frame. ADR 0001's amendment measured the full
-- pipeline at 3.75 ms for the whole panel, which is affordable at 30 Hz
-- (~11% of a 60 fps budget) and wasteful at 60.
--------------------------------------------------------------------------

-- Pace by COUNTING FRAMES, not by watching the clock.
--
-- This used to be a wall-clock deadline:
--
--     DS.PUSH_HZ = 30
--     if now - last_push < (1 / DS.PUSH_HZ) then return end
--     last_push = now
--
-- which aliases against the frame clock and was the whole cause of the jitter
-- on screen 2.
--
-- MEASURED, not assumed: the game does NOT run at 60 fps here. It runs at
-- ~119 fps, because the Thor's panels are 120 Hz. So love.draw fires every
-- ~8.4 ms and the old gate wanted 33.3 ms: four frames is 33.6 ms, clearing
-- the deadline by 0.3 ms. Any frame arriving a hair early, or any noise in
-- getTime(), missed and waited a fifth. The real rate flapped between 30 Hz
-- and 24 Hz, frame to frame, and that is what read as stutter. The top screen
-- looked fine because it is not gated at all.
--
-- Counting frames cannot alias: every Nth frame is every Nth frame. The push
-- is phase-locked to the game's own render clock -- the clock the animation is
-- authored against, and the same one the top screen obeys. So screen 2 is as
-- smooth as screen 1 by construction rather than by tuning.
--
-- N=2 CHOSEN ON MEASUREMENT. Over 5-second windows on device:
--
--   N=1   game 82-111 fps and falling,  450-566 pushes/window
--   N=2   game 119 fps rock steady,     297 pushes/window, every window
--
-- Pushing every frame costs enough to drag the game's own frame rate down and
-- makes the cadence irregular as a result. N=2 leaves the game at the panel's
-- 120 Hz cap and still pushes at ~59 Hz, which is far more than a card game
-- needs. Raising it further only trades smoothness for headroom we are not
-- short of.
DS.PUSH_EVERY = 2

-- Interval statistics, for tuning this number only. Off in normal builds; see
-- An armed debug flag is not a harmless thing to leave in.
DS.PACING_DEBUG = false

local orig_draw = love.draw
local frame_n = 0
local force_push = true

-- Pacing stats (only touched when DS.PACING_DEBUG).
local st_last, st_n, st_sum, st_min, st_max, st_report = 0, 0, 0, 1e9, 0, 0

-- Frame counter for once-per-frame work in other modules (render's region
-- ease advances on it; timestamps within one frame are not distinct enough).
DS.FRAME = 0

function love.draw()
    DS.FRAME = DS.FRAME + 1
    -- CLEAR THE BACKBUFFER. Vanilla never does, and on this platform that is
    -- what put a green fringe outside the CRT curve on the right of screen 1.
    --
    -- The chain: G.AA_CANVAS is only created on Windows behind a disabled
    -- branch (main.lua:370-384), so on Android it is nil and
    -- `setCanvas(G.AA_CANVAS)` means "draw to the backbuffer". The CRT pass
    -- therefore composites straight to the screen, and CRT.fs ends with
    -- `return (...)*mask` -- so outside the curved edge it writes ALPHA ZERO
    -- and leaves those pixels alone. Balatro's love.run has no
    -- love.graphics.clear (main.lua:33-83), so what shows there is whatever
    -- that buffer happened to hold: black down the left, a stale un-CRT'd
    -- strip of table felt down the right. That is why the fringe was
    -- asymmetric, why it was raw green rather than the shader's darkened
    -- green, and why painting the canvas edge black did not touch it -- the
    -- region is not sampled from the canvas at all, it is simply never drawn.
    --
    -- One clear per frame makes it defined black. Free on a tile GPU, and at
    -- crt = 0 the mask is 1 everywhere so nothing changes.
    love.graphics.clear(0, 0, 0, 1)

    if orig_draw then
        orig_draw()
    end

    -- The frame is in G.CANVAS now: the one moment it is complete and has not
    -- yet been through the CRT pass. Sampling here rather than in the update
    -- tick is what lets the LEDs read the real picture.
    pcall(led.reconcile)

    if not DS.companion_present or DS.panel_w == 0 then
        return
    end

    -- A mode change must repaint even if nothing else did, or the panel holds
    -- the last hand until something happens to force a push.
    local mode_now = snapshot.display_mode()
    if mode_now ~= DS.last_mode then
        DS.last_mode = mode_now
        DS.log("display mode -> " .. tostring(mode_now))
        force_push = true
    end

    frame_n = frame_n + 1
    -- At the 60 fps cap the panel pushes EVERY frame: 60 Hz on the panel,
    -- same smoothness as the uncapped 119/2. Every-frame pushes were
    -- unaffordable when N=2 was measured -- that was the old string-copy
    -- path; the zero-copy handoff fits easily in a 16.6 ms frame.
    local n = (G.FPS_CAP and G.FPS_CAP <= 70) and 1 or DS.PUSH_EVERY
    if n < 1 then n = 1 end
    if not force_push and (frame_n % n) ~= 0 then
        return
    end
    force_push = false

    if DS.PACING_DEBUG then
        local now = love.timer.getTime()
        if st_last > 0 then
            local dt = (now - st_last) * 1000
            st_n, st_sum = st_n + 1, st_sum + dt
            if dt < st_min then st_min = dt end
            if dt > st_max then st_max = dt end
        end
        st_last = now
        if now - st_report > 5 and st_n > 0 then
            st_report = now
            DS.log(("pacing: n=%d mean=%.1f min=%.1f max=%.1f ms  game=%d fps")
                :format(st_n, st_sum / st_n, st_min, st_max, love.timer.getFPS()))
            st_n, st_sum, st_min, st_max = 0, 0, 1e9, 0
        end
    end

    local canvas = render.get_canvas(DS.panel_w, DS.panel_h)
    if not canvas then
        return
    end

    -- The hash is rebuilt every pass, exactly as the game rebuilds
    -- G.DRAW_HASH every frame (misc_functions.lua:624). Clearing in place keeps
    -- the table identity stable for anything holding a reference.
    for i = #DS.HASH2, 1, -1 do DS.HASH2[i] = nil end
    for k in pairs(DS.HASH2_SET) do DS.HASH2_SET[k] = nil end

    local ok, drew = pcall(render.draw, canvas, DS.panel_w, DS.panel_h)
    -- Belt and braces: render.draw clears this itself, but if it ever errors
    -- mid-pass the flag would stay set and add_to_drawhash would be suppressed
    -- forever -- leaving the whole game uninteractive with no obvious cause.
    DS.rendering_screen2 = false
    -- Same belt and braces for the other draw-pass state. DS.defer_area in
    -- particular is latched by a section mid-draw; if a throw escaped before it
    -- was cleared, that card area would be skipped by its parent UIBox forever
    -- and simply never appear again.
    DS.defer_area = nil
    DS.hash_dx, DS.hash_dy = 0, 0
    DS.hash_s, DS.hash_cx, DS.hash_cy = 1, 0, 0
    if not ok then
        DS.log("render failed: " .. tostring(drew))
        DS.RENDER_BROKEN = true
        return
    end
    if not drew then
        return
    end

    local okp, err = pcall(function()
        -- Optional CRT pass: the panel gets the same shader, same settings,
        -- as the top screen. Nil means off; push the plain canvas.
        local src = render.apply_crt(canvas, DS.panel_w, DS.panel_h) or canvas
        local img = src:newImageData()
        -- Zero-copy first; the string path remains as the
        -- fallback for a native module that predates push_pixels2.
        if not bridge.push_pixels_data(img, DS.panel_w, DS.panel_h) then
            bridge.push_pixels(img:getString(), DS.panel_w, DS.panel_h)
        end
        if img.release then img:release() end
    end)
    if not okp then
        DS.log("frame push failed: " .. tostring(err))
    end
end

DS.log("overlay loaded, version " .. DS.VERSION)

return DS
