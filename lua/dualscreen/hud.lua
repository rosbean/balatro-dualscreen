-- balatro-dualscreen-thor -- the hand score on screen 2.
--
-- MECHANISM: DETACH THE LIVE ELEMENT, DO NOT REBUILD ANYTHING.
--
-- The score readout is one element inside the HUD (id 'hand_text_area',
-- UI_definitions.lua:1341). Every layout pass -- calculate_xywh, set_wh,
-- set_alignments -- walks the element tree through `parent.children`
-- (ui.lua:118 onward), so removing the element from that one array and calling
-- G.HUD:recalculate() makes the left pane repack as though the score were
-- never defined. Putting it back at the same index and recalculating restores
-- vanilla exactly. Both directions are plain table operations on live objects:
-- nothing is constructed, nothing is removed, nothing is re-bound.
--
-- WHY THE DETACHED ELEMENT KEEPS WORKING, which is what makes this safe:
--
--   * Every UIElement is a full Moveable, registered in G.MOVEABLES at
--     creation. The engine's update loop runs :move and :update on ALL of
--     them (game.lua:2626-2632) regardless of tree membership -- so the
--     element keeps following G.HUD (role.major is the UIBox, ui.lua:380)
--     and its per-frame funcs (hand_chip_UI_set and friends) keep running.
--   * G.hand_text_area is bound ONCE, at run start (game.lua:2406), while the
--     element is still attached. The references are to the elements
--     themselves, and detaching does not invalidate them, so every
--     `G.hand_text_area.chips:update(...)` the game makes keeps landing.
--   * Screen 1 cannot draw it: the NODE draw pass skips parented nodes
--     (game.lua:2758) and the tree traversal no longer reaches it. No
--     suppression wrapper is needed -- absence is structural.
--
-- WHY NOT REBUILD THE HUD, at length, because five attempts died here (see
-- docs/decisions/0002-rebuild-the-hud-on-toggle.md). The killer is that
-- UIElement:remove destroys its object node's object
-- (`self.config.object:remove()`, ui.lua:1008) -- and G.GAME.blind IS an
-- object node inside G.HUD_blind (UI_definitions.lua:1232). Any teardown that
-- reaches that box removes the Blind itself, permanently. A UIBox is also
-- positioned by `alignment.major`, a different field from the `role.major`
-- one attempt re-pointed. Detaching one element reaches neither.
--
-- The one vanilla caller that looks the element up mid-run is the first-hand
-- TUTORIAL step (state_events.lua:1384), whose highlight list quietly comes
-- up empty while the element is detached. That is the correct degradation --
-- the box it wants to point at is not on that screen.

local hud = {}

-- Alpha for the score's backing on the panel. Taken from the card areas
-- (CardArea builds its backing with {0,0,0,0.1}, cardarea.lua:294) so the
-- score sits at the same visual weight as the boxes beside it. The vanilla
-- solid fill is stashed and restored on reattach.
local SCORE_ALPHA = 0.1

-- While detached: { e, parent, index, colour }. Nil while attached.
hud.stash = nil

--- The score element while it is detached (and therefore ours to draw on
--- screen 2), or nil.
function hud.element()
    return hud.stash and hud.stash.e or nil
end

local function want_detached()
    local settings = require("dualscreen.settings")
    return DS.active and settings.hand_score()
       and G ~= nil and G.STAGES ~= nil and G.STAGE == G.STAGES.RUN
       and G.HUD ~= nil and not G.HUD.REMOVED
end

--- Drop a stash that belongs to a finished run.
---
--- A detached element is OUTSIDE the tree, so the HUD teardown at run end
--- never reaches it -- without this, every run that ends while the score is
--- on screen 2 would leak the subtree and its DynaTexts. e:remove() disposes
--- of them properly; they belong to the dead run and nothing else references
--- them.
local function dispose_stale()
    local s = hud.stash
    if not s then return end
    local stale = s.parent.REMOVED or s.e.REMOVED
        or not G or not G.HUD or s.e.UIBox ~= G.HUD
    if not stale then return end
    if not s.e.REMOVED then pcall(s.e.remove, s.e) end
    hud.stash = nil
end

local function detach()
    local e = G.HUD:get_UIE_by_ID("hand_text_area")
    if not e or not e.parent or not e.parent.children then
        DS.log("hud: hand_text_area not found; toggle has no effect")
        return
    end
    local parent, index = e.parent, nil
    for i, child in ipairs(parent.children) do
        if child == e then index = i break end
    end
    if not index then return end

    table.remove(parent.children, index)
    hud.stash = { e = e, parent = parent, index = index, colour = e.config.colour }
    e.config.colour = { 0, 0, 0, SCORE_ALPHA }
    G.HUD:recalculate()
    DS.log("hud: score detached, pane repacked")
end

local function reattach()
    local s = hud.stash
    hud.stash = nil
    if s.parent.REMOVED or s.e.REMOVED then return end
    s.e.config.colour = s.colour
    table.insert(s.parent.children,
                 math.min(s.index, #s.parent.children + 1), s.e)
    G.HUD:recalculate()
    DS.log("hud: score reattached, pane vanilla")
end

--- The five strings the score displays. When any changes, the subtree needs
--- the same relayout the box would have given it.
local function score_text_signature()
    local h = G and G.GAME and G.GAME.current_round
              and G.GAME.current_round.current_hand
    if not h then return "" end
    return tostring(h.handname_text) .. "|" .. tostring(h.chip_text)
        .. "|" .. tostring(h.mult_text) .. "|" .. tostring(h.chip_total_text)
        .. "|" .. tostring(h.hand_level)
end

local last_sig = nil

-- When the displayed strings last changed, for the level-up visibility
-- window. update_hand_text rewrites them through a planet's whole animation
-- (mult at ~0.2s, chips at ~1.1s, level at ~2.0s, common_events.lua:476-487),
-- so "changed recently" spans the animation wherever it was triggered from.
local last_change_at = -math.huge

-- Measured from the LAST string change -- and the animation stamps three of
-- them (mult, chips, level), so this only needs to outlast the FINAL flash's
-- ~1s hold, not the whole sequence. It cannot go much below the ~0.9s stamp
-- spacing or the score blinks between the flashes.
local ACTIVITY_WINDOW = 1.0

--- Did the score's displayed text change within the last few seconds?
function hud.recent_score_activity()
    return hud.stash ~= nil
       and (love.timer.getTime() - last_change_at) < ACTIVITY_WINDOW
end

--- Re-run the engine's own layout passes over the DETACHED subtree.
---
--- Vanilla keeps the attached HUD tidy through UIElement:update_text and
--- update_object, which call `self.UIBox:recalculate()` whenever a bound
--- string or object changes (ui.lua:626, 634). The detached elements still
--- make those calls -- their UIBox field still points at G.HUD -- but the
--- box's recalculate walks the ATTACHED tree and never reaches them, so the
--- level / name / chips drifted out of place as their text changed.
---
--- This applies recalculate's exact passes, scoped to the subtree and
--- anchored at its current box-relative offset, so the internal layout is
--- re-derived just as it would have been in place.
local function relayout_subtree(e)
    local origin = { x = e.role.offset.x, y = e.role.offset.y, w = 0, h = 0 }
    G.HUD:calculate_xywh(e, origin, true)
    e:set_wh()
    e:set_alignments()
    e:initialize_VT()
end

--- Per-tick reconciler. Idempotent; acts only when desired and actual state
--- differ, so the cost of a quiet tick is two nil checks -- and a toggle
--- callback that fires many times per tap (a create_toggle habit this project
--- has measured) cannot cause churn.
function hud.reconcile()
    dispose_stale()
    local want = want_detached()
    if want ~= (hud.stash ~= nil) then
        local ok, err = pcall(want and detach or reattach)
        if not ok then
            DS.log("hud: reconcile failed: " .. tostring(err))
        end
        last_sig = nil
    end

    -- While detached, track the displayed strings and re-derive the subtree's
    -- internal layout when they change -- the box-side recalculate that would
    -- normally do this cannot reach a detached element.
    if hud.stash then
        local sig = score_text_signature()
        if sig ~= last_sig then
            -- The very first signature after a detach is bookkeeping, not
            -- activity -- counting it would flash the score on every toggle.
            --
            -- And only changes made IN A SHOP OR PACK count at all. The
            -- window exists so a planet used where the score is not normally
            -- shown brings it along; string changes during play are already
            -- on display, and counting them made the score linger into the
            -- round-eval screen after the final hand, where it covered the
            -- Cash Out panel for a moment, oversized by that region's zoom.
            -- And only while the display actually NAMES a hand. The use
            -- sequence ends with vanilla resetting the readout to idle --
            -- `{mult = 0, chips = 0, handname = '', level = ''}`
            -- (card.lua:1176) -- and that reset is itself a string change,
            -- which re-stamped the window after it had expired: score
            -- disappears, blinks back for a second showing the zeroed text,
            -- disappears again (most visible at slow game speed). The reset
            -- blanks `handname` instantly, so gating on it also blocks the
            -- follow-on stamps from the chip numbers easing down to zero.
            local snapshot = require("dualscreen.snapshot")
            local ch = G.GAME and G.GAME.current_round
                       and G.GAME.current_round.current_hand
            local naming = ch ~= nil and ch.handname ~= nil
                           and ch.handname ~= ""
            if last_sig ~= nil and naming
               and (snapshot.is_pack_state()
                    or (G.STATE ~= nil and G.STATES ~= nil
                        and G.STATE == G.STATES.SHOP)) then
                last_change_at = love.timer.getTime()
            end
            last_sig = sig
            local ok, err = pcall(relayout_subtree, hud.stash.e)
            if not ok then
                DS.log("hud: subtree relayout failed: " .. tostring(err))
            end
        end
    end
end

return hud
