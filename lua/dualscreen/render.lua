-- balatro-dualscreen-thor -- render the hand region for screen 2.
--
-- ADR 0001 route (b): draw the real game objects into an off-screen canvas and
-- ship the pixels. Not a reimplementation -- these are Balatro's own draw
-- calls, so card art, fonts, the selection lift and the foil/holo/polychrome
-- edition shaders all come through exactly as the game renders them.
--
-- How the transform works. All Balatro geometry is in TILES, and one tile is
-- G.TILESCALE * G.TILESIZE pixels. Objects position themselves at
-- T.x * scale inside their container, with Node:translate_container()
-- (engine/node.lua:307) applying the container's offset first. So to show a
-- chosen tile-space region on a differently-sized panel we only need to wrap
-- the game's own draw calls in one scale + translate:
--
--     love.graphics.scale(k, k)
--     love.graphics.translate(-origin_px, -origin_py)
--     obj:translate_container()
--     obj:draw()
--
-- which maps the pixel at (origin_px, origin_py) to the canvas origin and
-- magnifies by k.

local render = {}

local sections = require("dualscreen.sections")

render.CALIBRATE = false

-- Section layout constants (padding, button drop, pack framing) moved to
-- sections.lua: they are properties of a section's layout, and its
-- region() and draw() both need them.

render.canvas = nil
render.canvas_w = 0
render.canvas_h = 0

--- Get (or lazily create) the off-screen canvas.
---
--- {dpiscale = 1} is NOT optional. LOVE defaults a canvas's pixel dimensions
--- to w*dpiscale x h*dpiscale, and this device reports 2.3077, so an unpinned
--- canvas would be 5.3x the pixels and 5.3x the cost -- silently.
--- See ADR 0001's amendment.
-- Second cached canvas, for the optional CRT pass over the panel.
local crt_canvas, crt_w, crt_h = nil, 0, 0

function render.get_crt_canvas(w, h)
    if crt_canvas and crt_w == w and crt_h == h then
        return crt_canvas
    end
    if crt_canvas then
        crt_canvas:release()
        crt_canvas = nil
    end
    local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
    if not ok or not c then return nil end
    crt_canvas, crt_w, crt_h = c, w, h
    return c
end

--- Apply the game's own CRT shader to the panel canvas, mirroring the uniform
--- block Game:draw sends for the top screen (game.lua:2940-2951), including
--- its curious crt*0.3 pre-scale. Returns the CRT'd canvas, or nil when the
--- effect is off or unavailable -- the caller then pushes the plain canvas.
---
--- The panel-specific uniforms: scanline count derives from the PANEL height
--- (vanilla uses its own canvas height), and the "mouse" position -- which
--- the shader uses for a subtle hover warp -- is pinned to the panel centre,
--- since the player's cursor has no meaning on this screen.
function render.apply_crt(canvas, w, h)
    local settings = require("dualscreen.settings")
    if not settings.crt2() then return nil end
    local crt = G and G.SETTINGS and G.SETTINGS.GRAPHICS
                and G.SETTINGS.GRAPHICS.crt or 0
    if crt <= 0 then return nil end
    local shader = G.SHADERS and G.SHADERS["CRT"]
    if not shader then return nil end

    local out = render.get_crt_canvas(w, h)
    if not out then return nil end

    -- Edge-smear guard: inside the feather band the shader samples with
    -- CLAMPED texture coords, so the canvas's outermost pixel column gets
    -- dragged outward. Two pixels of black on the source is enough to make
    -- those samples black, and narrow enough not to eat visible content.
    --
    -- This is NOT the fix for the top screen's green fringe -- that was an
    -- uncleared backbuffer, see the love.draw wrapper in init.lua. It cannot
    -- happen here in the first place, because `out` is cleared to OPAQUE black
    -- below, so the masked-off region has something defined under it.
    local B = 2
    local prev_canvas = love.graphics.getCanvas()
    love.graphics.push()
    love.graphics.origin()
    love.graphics.setCanvas(canvas)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", 0, 0, w, B)
    love.graphics.rectangle("fill", 0, h - B, w, B)
    love.graphics.rectangle("fill", 0, 0, B, h)
    love.graphics.rectangle("fill", w - B, 0, B, h)

    local c = crt * 0.3
    shader:send("distortion_fac", { 1.0 + 0.07 * c / 100, 1.0 + 0.1 * c / 100 })
    shader:send("scale_fac", { 1.0 - 0.008 * c / 100, 1.0 - 0.008 * c / 100 })
    shader:send("feather_fac", 0.01)
    shader:send("bloom_fac", (G.SETTINGS.GRAPHICS.bloom or 1) - 1)
    shader:send("time", 400 + G.TIMERS.REAL)
    shader:send("noise_fac", 0.001 * c / 100)
    shader:send("crt_intensity", 0.16 * c / 100)
    shader:send("glitch_intensity", 0)
    shader:send("scanlines", h * 0.75)
    shader:send("mouse_screen_pos", { w / 2, h / 2 })
    shader:send("screen_scale", G.TILESCALE * G.TILESIZE)
    shader:send("hovering", 1)

    love.graphics.setCanvas(out)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(shader)
    love.graphics.draw(canvas, 0, 0)
    love.graphics.setShader()
    love.graphics.setCanvas(prev_canvas)
    love.graphics.pop()
    return out
end

function render.get_canvas(w, h)
    if render.canvas and render.canvas_w == w and render.canvas_h == h then
        return render.canvas
    end
    if render.canvas then
        render.canvas:release()
        render.canvas = nil
    end
    local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
    if not ok or not c then
        DS.log("render: newCanvas failed: " .. tostring(c))
        return nil
    end
    render.canvas = c
    render.canvas_w, render.canvas_h = w, h
    DS.log(("render: canvas %dx%d"):format(w, h))
    return c
end

--- Region to show when the hand is not live (menu, blind select, shop...).
---
--- Centred on the room and fitted to the panel aspect, so the same animated
--- background the top screen is showing fills the bottom one. Derived from
--- G.TILE_W / G.TILE_H rather than any panel-specific constant.
local function background_region(w, h)
    local tw = (G and G.TILE_W) or 20
    local th = (G and G.TILE_H) or 11.5
    -- Fit the room's full width, then take whatever height the panel aspect
    -- implies, centred vertically on the room.
    local rw = tw
    local rh = (w > 0) and (rw * h / w) or th
    return { x = 0, y = th / 2 - rh / 2, w = rw, h = rh }
end

--- The region screen 2 is actually showing, in ROOM-relative tiles.
---
--- ONE function, used by the draw, by panel_to_tile and by card_rects. They
--- must agree: the draw decides where things appear, and the other two decide
--- where they can be touched. A draw/collision mismatch has already cost one
--- debugging round, and was nearly reintroduced by leaving
--- three callers pointing at a region() that no longer existed -- which at
--- least crashed loudly rather than going subtly wrong.
---
--- nil from sections.region() means no live section wants particular framing,
--- so fall back to the room background and keep the two panels
--- reading as one surface.
-- Region transition ease.
--
-- The first attempt eased the region toward its target EVERY frame, and the
-- user report was immediate: "the interface has gotten a lot more wooshy and
-- zoomy... UI elements whizzing around". Root cause: regions are supposed to
-- TRACK moving anchors. The pack region follows the pack box through
-- vanilla's slide-in, and because the frame moves with the content, the
-- content appears STILL on the panel -- the tracking is the stabiliser. An
-- eased frame lags the anchor, so every vanilla slide became visible
-- swimming.
--
-- So the ease is gated on the region's SOURCE (which section supplied it):
--   same source  -> snap to the live target, exactly the old behaviour;
--   new source   -> ease from where the frame was to the new target
--                   (~150 ms), which is the one real cut worth smoothing --
--                   the shop-balloons-during-pack-handover glitch.
local sm = nil            -- current region {x,y,w,h}
local sm_src = nil        -- name of the section that supplied the target
local sm_easing = false
local sm_frame = -1       -- DS.FRAME the ease last advanced on
local sm_t = 0
local SMOOTH_RATE = 14    -- 1/s; ~150ms to settle visually

function render.active_region(w, h)
    -- One evaluation per frame, served to every caller. This is not only a
    -- cost saving: section region() functions may keep per-frame state (the
    -- shop's slide detector below relies on being asked once per frame).
    local frame = DS.FRAME or -1
    if frame == sm_frame then
        return sm
    end
    sm_frame = frame

    local target, src = sections.region()
    if not target then
        target, src = background_region(w, h), "background"
    end
    if not target then
        sm, sm_src = nil, nil
        return nil
    end

    local now = love.timer.getTime()
    local dt = math.min(now - sm_t, 0.05)
    sm_t = now

    if not sm or (src == sm_src and not sm_easing) then
        -- Same source: locked tracking. (Also the first frame ever.)
        sm = sm or {}
        sm.x, sm.y, sm.w, sm.h = target.x, target.y, target.w, target.h
        sm_src = src
        return sm
    end

    if src ~= sm_src then
        -- Ease ONLY the pack handovers. They are the transitions where two
        -- differently-zoomed UIs are visible at once mid-slide -- the case the
        -- ease exists for. Everywhere else a switch is a clean content swap,
        -- and easing it just animates artifacts: opening Options on the main
        -- menu visibly ZOOMED the menu up behind the popup (the overlay's
        -- tighter crop magnifies the backdrop; snapping hides that, animating
        -- it advertises it).
        sm_easing = (src == "booster_pack" or sm_src == "booster_pack")
        sm_src = src
        if not sm_easing then
            sm.x, sm.y, sm.w, sm.h = target.x, target.y, target.w, target.h
            return sm
        end
    end

    local k = 1 - math.exp(-SMOOTH_RATE * dt)
    sm.x = sm.x + (target.x - sm.x) * k
    sm.y = sm.y + (target.y - sm.y) * k
    sm.w = sm.w + (target.w - sm.w) * k
    sm.h = sm.h + (target.h - sm.h) * k
    if math.abs(sm.x - target.x) < 0.01 and math.abs(sm.y - target.y) < 0.01
       and math.abs(sm.w - target.w) < 0.01 and math.abs(sm.h - target.h) < 0.01 then
        sm.x, sm.y, sm.w, sm.h = target.x, target.y, target.w, target.h
        sm_easing = false
    end
    return sm
end

--- Draw one game object the way Game:draw does: container transform, then draw.
---
--- UIBox:draw (engine/ui.lua:284) opens with a once-per-frame guard:
---
---     if self.FRAME.DRAW >= G.FRAMES.DRAW and not G.OVERLAY_TUTORIAL then return end
---
--- Game:draw has already drawn G.buttons this frame for screen 1, so a second
--- call returns immediately and the buttons never appear on screen 2. Clearing
--- FRAME.DRAW first lets it draw again. CardArea has no such guard, which is
--- why the hand rendered and the buttons did not.
local function draw_obj(obj)
    if not obj then return end
    if obj.FRAME and obj.FRAME.DRAW then
        obj.FRAME.DRAW = -1
    end
    love.graphics.push()
    if obj.translate_container then obj:translate_container() end
    obj:draw()
    love.graphics.pop()
end

--- Render the hand region into `canvas`. Returns true if anything was drawn.
function render.draw(canvas, w, h)
    -- Screen 2 always shows the same animated background as screen 1,
    -- so the two panels read as one surface whatever the game is doing. What
    -- changes by state is only whether the HAND is drawn on top of it -- a
    -- stale hand in the shop is the failure Banjo's dedupe rule warns about,
    -- and blanking to pure black turned out to look worse than the background.
    -- Toggle off (Options > Settings > Dual Screen): the hand is being played
    -- on screen 1, so this panel goes black rather than showing a background
    -- that implies it is still part of the game.
    if not DS.active then
        local prev = love.graphics.getCanvas()
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 1)
        love.graphics.setCanvas(prev)
        return true
    end

    -- Liveness is each section's own business, so there is no
    -- hand_live flag here any more. A nil region means no section wants the
    -- panel framed on anything in particular -- menus, the shop, between hands
    -- -- so fall back to showing the room background, which is what keeps the
    -- two panels reading as one surface.
    local r = render.active_region(w, h)
    if not r or not G.ROOM then
        return false
    end

    local S = (G.TILESCALE or 1) * (G.TILESIZE or 20)
    if S <= 0 then
        return false
    end

    -- Fit the region to the panel, preserving aspect. Letterboxing is
    -- preferable to distorting card art.
    local k = math.min(w / (r.w * S), h / (r.h * S))

    -- Region origin in pre-scale pixels, including the ROOM offset that
    -- translate_container will re-apply inside the push.
    local ox = (G.ROOM.T.x + r.x) * S
    local oy = (G.ROOM.T.y + r.y) * S

    -- Centre whatever slack the aspect fit leaves over.
    local slack_x = (w - r.w * S * k) * 0.5
    local slack_y = (h - r.h * S * k) * 0.5

    if not render._logged and G.hand and G.hand.T then
        render._logged = true
        DS.log(("render geom: TILESCALE=%.3f S=%.1f | hand T=(%.2f,%.2f %.2fx%.2f) "
                .. "| ROOM T=(%.2f,%.2f %.2fx%.2f) | region=(%.2f,%.2f %.2fx%.2f) "
                .. "| panel=%dx%d k=%.3f ox=%.1f oy=%.1f")
               :format(G.TILESCALE or -1, S,
                       G.hand.T.x, G.hand.T.y, G.hand.T.w, G.hand.T.h,
                       G.ROOM.T.x, G.ROOM.T.y, G.ROOM.T.w, G.ROOM.T.h,
                       r.x, r.y, r.w, r.h, w, h, k, ox, oy))
    end

    local prev_canvas = love.graphics.getCanvas()
    local prev_shader = love.graphics.getShader()

    -- Suppress the card tilt/skew for this render.
    --
    -- Balatro's 3D card effect is computed in SCREEN space, not in ours:
    --   engine/sprite.lua:93  feeds the tilt shader
    --                         G.CONTROLLER.cursor_position.x * G.CANV_SCALE,
    --                         i.e. absolute screen pixels
    --   engine/moveable.lua:461  shadow_parrallax scales with the card's
    --                         distance from ROOM centre
    --
    -- Neither knows about the zoom we apply here, so at k > 1 the effect is
    -- magnified, and because the parallax term grows with distance from centre
    -- it grows across the hand -- cards distort progressively left to right.
    --
    -- engine/sprite.lua:74 is the switch: reduced_motion forces _no_tilt.
    -- ADR 0001 earmarked this flag for suppressing ambient sway; it turns out
    -- to disable the tilt path too, which is what makes route (b) viable at a
    -- zoom. Restored immediately, and screen 1 has already drawn this frame,
    -- so its own rendering is untouched.
    local prev_reduced = G.SETTINGS and G.SETTINGS.reduced_motion
    if G.SETTINGS then G.SETTINGS.reduced_motion = true end

    -- Tells the draw wrappers that this pass is the screen-2 one, so
    -- the hand and buttons they hide from screen 1 are drawn here instead.
    DS.rendering_screen2 = true

    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setColor(1, 1, 1, 1)

    love.graphics.push()
    -- Reset to identity FIRST. love.draw has just run Game:draw, which leaves
    -- its own transform on the stack; without this our scale composes with
    -- whatever it left behind.
    love.graphics.origin()
    love.graphics.translate(slack_x, slack_y)
    love.graphics.scale(k, k)
    love.graphics.translate(-ox, -oy)

    -- Background first. G.SPLASH_BACK is the same Sprite the game draws at
    -- game.lua:2745-2751, running background.fs with uniforms from
    -- G.C.BACKGROUND -- which the game eases per blind through
    -- ease_background_colour_blind. Drawing it here means screen 2 tracks
    -- screen 1's blind colour for free.
    if G.SPLASH_BACK then
        draw_obj(G.SPLASH_BACK)
    end

    -- Then whatever the registry says belongs on screen 2.
    --
    -- ctx.draw applies the section's draw-time y offset and records it in the
    -- hit hash, so what is drawn and what is touchable can never disagree --
    -- collides_with_point tests a node's REAL T, and a draw-only translate
    -- would otherwise put the two a tile apart.
    -- EVERY ctx draw is pcall'd, and every push is popped on the way out.
    --
    -- This matters. Drawing a card area directly (rather
    -- than through its parent UIBox) meant we could hand a REMOVED area to
    -- CardArea:draw, which crashed on `#self.cards`. render.draw is pcall'd, so
    -- that alone would have been survivable -- but the throw escaped between a
    -- push and its pop, leaving the graphics transform stack unbalanced, and
    -- the game died on the next frame instead. A failure here must cost one
    -- object, not the run.
    local ctx = {}

    local function safe_draw(obj)
        local ok, err = pcall(draw_obj, obj)
        if not ok then
            DS.log("draw failed: " .. tostring(err))
        end
    end

    function ctx.draw(obj, dy)
        if not obj then return end
        if dy and dy ~= 0 then
            love.graphics.push()
            love.graphics.translate(0, dy * S)
            DS.hash_dy = dy
            safe_draw(obj)
            DS.hash_dy = 0
            love.graphics.pop()
        else
            safe_draw(obj)
        end
    end

    -- The region and scale this pass is drawing at, so a section can place
    -- something relative to the panel rather than to the room.
    ctx.r = r
    ctx.S = S

    --- Draw `obj` shifted by (dx, dy) tiles, recording the shift for the hash.
    ---
    --- Used to place a HUD element into a corner of the panel without moving
    --- the object itself. Moving it for real is not an option: these are nodes
    --- inside the HUD's layout, and nudging a
    --- laid-out element by its role offset moves the element and leaves its
    --- children behind.
    function ctx.draw_offset(obj, dx, dy, sc, ax, ay)
        if not obj then return end
        love.graphics.push()
        love.graphics.translate(dx * S, dy * S)
        -- Optional uniform scale about the room-space anchor (ax, ay) -- the
        -- corner the caller aligned, so it stays put while the box shrinks
        -- away from it.
        if sc and sc ~= 1 and ax then
            local px = (G.ROOM.T.x + ax) * S
            local py = (G.ROOM.T.y + ay) * S
            love.graphics.translate(px, py)
            love.graphics.scale(sc, sc)
            love.graphics.translate(-px, -py)
        end
        DS.hash_dx, DS.hash_dy = dx, dy
        if sc and sc ~= 1 and ax then
            -- The hash inversion undoes the scale about (cx, cy) BEFORE
            -- subtracting the offset; for that order to invert
            -- translate-then-scale exactly, the recorded centre must be the
            -- anchor in POST-translate coordinates: cx = ax + dx.
            DS.hash_s, DS.hash_cx, DS.hash_cy = sc, ax + dx, ay + dy
        end
        safe_draw(obj)
        DS.hash_dx, DS.hash_dy = 0, 0
        DS.hash_s, DS.hash_cx, DS.hash_cy = 1, 0, 0
        love.graphics.pop()
    end

    --- Draw a UIElement subtree. UIElement:draw is empty -- a UIBox renders its
    --- tree with draw_self + draw_children (ui.lua:293), so do the same.
    function ctx.draw_uie(e, dx, dy, sc)
        if not e then return end
        love.graphics.push()
        love.graphics.translate((dx or 0) * S, (dy or 0) * S)
        -- Optional uniform scale about the element's own top-left, so the
        -- anchor the caller positioned stays put and the box shrinks away
        -- from it. Recorded in the hit hash like every draw-time transform.
        local cx, cy = e.T.x, e.T.y
        if sc and sc ~= 1 then
            local ax = (G.ROOM.T.x + cx) * S
            local ay = (G.ROOM.T.y + cy) * S
            love.graphics.translate(ax, ay)
            love.graphics.scale(sc, sc)
            love.graphics.translate(-ax, -ay)
        end
        DS.hash_dx, DS.hash_dy = dx or 0, dy or 0
        DS.hash_s, DS.hash_cx, DS.hash_cy = sc or 1, cx + (dx or 0), cy + (dy or 0)
        local ok, err = pcall(function()
            if e.translate_container then e:translate_container() end
            if e.draw_self then e:draw_self() end
            if e.draw_children then e:draw_children() end
        end)
        if not ok then DS.log("draw_uie failed: " .. tostring(err)) end
        DS.hash_dx, DS.hash_dy = 0, 0
        DS.hash_s, DS.hash_cx, DS.hash_cy = 1, 0, 0
        love.graphics.pop()
    end

    --- Draw `obj` scaled by `sc` about the tile-space point (cx, cy).
    ---
    --- Lets a section size one element independently of the rest of its UIBox
    --- -- the booster pack scales its cards to the number on offer while its
    --- "Choose N" row stays a fixed size. The scale is recorded in the hit hash
    --- so collision follows it; see DS.hash_s.
    function ctx.draw_scaled(obj, sc, cx, cy)
        if not obj then return end
        if not sc or sc == 1 then return ctx.draw(obj, 0) end
        love.graphics.push()
        -- Scale about (cx, cy), expressed in the room-relative tile space this
        -- pass is already drawing in.
        local ax, ay = (G.ROOM.T.x + cx) * S, (G.ROOM.T.y + cy) * S
        love.graphics.translate(ax, ay)
        love.graphics.scale(sc, sc)
        love.graphics.translate(-ax, -ay)
        DS.hash_s, DS.hash_cx, DS.hash_cy = sc, cx, cy
        safe_draw(obj)
        DS.hash_s, DS.hash_cx, DS.hash_cy = 1, 0, 0
        love.graphics.pop()
    end

    sections.draw(ctx)


    if render.CALIBRATE then
        -- Magenta box on the region bounds. If the transform is right this
        -- hugs the canvas edges (horizontally, given the aspect fit).
        love.graphics.setLineWidth(3)
        -- region bounds
        love.graphics.setColor(1, 0, 1, 1)
        love.graphics.rectangle("line",
            (G.ROOM.T.x + r.x) * S, (G.ROOM.T.y + r.y) * S, r.w * S, r.h * S)
        -- the hand's own box
        love.graphics.setColor(0, 1, 1, 1)
        love.graphics.rectangle("line",
            (G.ROOM.T.x + G.hand.T.x) * S, (G.ROOM.T.y + G.hand.T.y) * S,
            G.hand.T.w * S, G.hand.T.h * S)
        -- every card's declared rect
        love.graphics.setColor(1, 1, 0, 1)
        for _, card in ipairs(G.hand.cards or {}) do
            love.graphics.rectangle("line",
                (G.ROOM.T.x + card.T.x) * S, (G.ROOM.T.y + card.T.y) * S,
                card.T.w * S, card.T.h * S)
        end
        love.graphics.setColor(1, 1, 1, 1)
        if not render._logged2 then
            render._logged2 = true
            local c1 = G.hand.cards and G.hand.cards[1]
            if c1 then
                DS.log(("card1 T=(%.2f,%.2f %.2fx%.2f)  VT=(%.2f,%.2f %.2fx%.2f)")
                       :format(c1.T.x, c1.T.y, c1.T.w, c1.T.h,
                               c1.VT and c1.VT.x or -1, c1.VT and c1.VT.y or -1,
                               c1.VT and c1.VT.w or -1, c1.VT and c1.VT.h or -1))
            end
        end
    end

    love.graphics.pop()

    DS.rendering_screen2 = false
    if G.SETTINGS then G.SETTINGS.reduced_motion = prev_reduced end

    love.graphics.setCanvas(prev_canvas)
    love.graphics.setShader(prev_shader)
    love.graphics.setColor(1, 1, 1, 1)
    return true
end

--- Shared region->panel mapping. Returns a function (tx,ty) -> canvas x,y
--- plus the scale, so rect producers cannot drift apart from render.draw.
local function panel_mapping(w, h)
    local r = render.active_region(w, h)
    if not r then return nil end
    local S = (G.TILESCALE or 1) * (G.TILESIZE or 20)
    if S <= 0 then return nil end
    local k = math.min(w / (r.w * S), h / (r.h * S))
    local slack_x = (w - r.w * S * k) * 0.5
    local slack_y = (h - r.h * S * k) * 0.5
    return function(tx, ty)
        return slack_x + (tx - r.x) * S * k, slack_y + (ty - r.y) * S * k
    end, S * k
end

--- Inverse of the panel mapping: screen-2 pixels -> ROOM-RELATIVE tiles.
---
--- Room-relative is what the DRAG path wants, since it assigns the result
--- straight to card.T. Collision wants ABSOLUTE tiles instead -- DS.hit_test
--- adds G.ROOM.T itself. Do not "fix" that here; it would break dragging.
--- Needed for dragging, where a finger position on the panel has to become a
--- card position in the game's own coordinate space.
function render.panel_to_tile(px, py, w, h)
    local r = render.active_region(w, h)
    if not r then return nil end
    local S = (G.TILESCALE or 1) * (G.TILESIZE or 20)
    if S <= 0 then return nil end
    local k = math.min(w / (r.w * S), h / (r.h * S))
    if k <= 0 then return nil end
    local slack_x = (w - r.w * S * k) * 0.5
    local slack_y = (h - r.h * S * k) * 0.5
    return r.x + (px - slack_x) / (S * k),
           r.y + (py - slack_y) / (S * k)
end

--- Map a point in canvas pixels back to a card index, for hit testing.
--- Screen 2 sends taps in its own pixel space, so the rects we publish in the
--- snapshot must be in that same space.
function render.card_rects(w, h)
    local r = render.active_region(w, h)
    local out = {}
    if not r or not G.hand or not G.hand.cards then
        return out
    end

    local map, scale = panel_mapping(w, h)
    if not map then return out end

    for i, card in ipairs(G.hand.cards) do
        -- Cards live in ROOM space like the hand, so subtracting the region
        -- origin (also ROOM-relative) is the whole conversion.
        local cx, cy = map(card.T.x, card.T.y)
        out[i] = { x = cx, y = cy, w = card.T.w * scale, h = card.T.h * scale }
    end
    return out
end

return render
