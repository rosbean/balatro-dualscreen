-- balatro-dualscreen-thor -- joystick RGB LEDs follow what is on screen.
--
-- COLOUR SOURCE: THE RENDERED FRAME, not the background shader's uniforms.
--
-- The first version averaged G.C.BACKGROUND.C and .L -- the tables fed to the
-- background shader as colour_1/colour_2 (game.lua:2287-2288). It tracked
-- state changes correctly and still looked wrong, for two reasons
-- that are both visible in ease_background_colour (common_events.lua:276):
--
--   * `L` is the new colour at brightness 1.3 -- a deliberately BLASTED
--     version meant to be a highlight inside a dark swirl, not a sample of it.
--     Averaging it in made every colour too bright.
--   * `C` is hijacked by `special_colour` whenever one is given, so the pair
--     being averaged is often two unrelated hues (small blind: blue over the
--     green table). The average skewed blue while the screen read green.
--
-- Averaging the actual frame has none of that indirection: it is by definition
-- the colour of what the player is looking at. The menu is red because the
-- menu IS red; the table is green; a boss blind and a shop shift by
-- themselves. No table of states to keep in step with the game.
--
-- BRIGHTNESS IS NOT TOUCHED, in the only sense the hardware permits: the LED
-- nodes are write-only, so a brightness set before the game started cannot be
-- read, saved or restored. Per the reference doc's proven path the wire's
-- brightness byte stays at 255 and RGB is sent as-is; switching the feature
-- off leaves the LEDs where they are rather than guessing at a previous value.
--
-- COST. One downscale draw plus a 64x36 readback, ten times a second. The
-- readback is 9 KB against the 5 MB the panel already ships every other frame.
--
-- Turning those pixels into one colour is a hue VOTE, not an average; see the
-- sampling loop for why two different averages both gave a pink title screen.

local led = {}

local SAMPLE_W, SAMPLE_H = 64, 36

local SAMPLE_MS   = 0.1     -- seconds between samples/sends
local LERP_FACTOR = 0.3     -- per-send step toward the target
local MIN_DELTA   = 2       -- 0..255 channel change worth an IPC

-- HOW THE FRAME BECOMES ONE COLOUR: PICK A HUE, DO NOT AVERAGE ONE.
--
-- Two averaging attempts both failed the same way, and the reason is worth
-- stating because it is not obvious. A flat mean gave a pink title screen: the
-- white logo carries no hue but plenty of weight. Weighting each pixel by its
-- own colourfulness fixed the greys and still came out pale, because averaging
-- COLOURS is not averaging a colour -- the red background and the blue and
-- purple UI are all colourful, and summing them in RGB walks straight back
-- toward the middle. Any mean of opposed hues is desaturated by construction,
-- so no amount of boosting afterwards recovers what the sum destroyed.
--
-- Hue is angular, so it gets counted rather than averaged. Every pixel with
-- any colour in it votes for a 15-degree bin; the winning arc is the hue that
-- covers the most of the screen, which is the background, because the
-- background is what most of the screen is. Then the colour is SYNTHESISED at
-- that hue and full saturation. Nothing pale can come out of it: pink and
-- red are the same hue and only pink is reachable by averaging.
local BINS = 24                       -- 15 degrees each

-- EVERY QUALIFYING PIXEL GETS ONE VOTE. Weighting the vote by chroma seemed
-- natural and was wrong: it elects the most VIVID hue rather than the most
-- PRESENT one. The table felt is a huge, muted green (sampled at 60,84,69 --
-- chroma 24), while the HUD's chips and the Play button are small and
-- saturated, so blue won a screen that is obviously green; the same arithmetic
-- let the orange logo outvote the red field behind it on the title screen.
-- One vote per pixel makes area decide, and area is what "the colour of that
-- screen" means.
--
-- MIN_CHROMA is then the whole franchise test, and it has to sit above the
-- near-greys of the HUD pane without excluding a muted background. 18 clears
-- the felt comfortably and keeps the dark grey panel out of the count.
local MIN_CHROMA = 18                 -- 0..255; below this a pixel has no hue

-- Brightness tracks the WHOLE frame's brightness, not the winning hue's, so a
-- dark screen gives dark LEDs. The floor is deliberately low: a celestial pack
-- is nearly black and should read as nearly black rather than as a dim version
-- of whatever hue won.
local V_FLOOR, V_RANGE = 0.12, 0.55

-- ...and is scaled by how much of the screen actually voted for the winner.
-- On a dark, mostly colourless screen the hue that wins does so on a handful of
-- pixels, and blasting the sticks with it states far more confidence than the
-- evidence supports. Full strength once the winning hue covers this fraction of
-- the frame, proportionally less below it.
local COVERAGE_FULL = 0.20

-- Pull each hue toward the nearer of its two surrounding primaries.
--
-- At full saturation the middle channel is what the eye reads as the hue, and
-- deviations that are subtle in a muted source are not subtle at all coming off
-- an LED. The table felt sits at hue 142 -- a green a sixth of the way to cyan,
-- which nobody notices in a dim textured field and which reads as CYAN when a
-- point source blasts it. The title screen's slightly warm red reads as orange
-- for the same reason. Raising the fractional position within the hue sextant
-- to this power suppresses the middle channel without moving the hue's sextant,
-- so a near-red stays red and a near-green stays green.
local HUE_PURIFY = 1.8

-- Per-channel calibration, applied last.
--
-- The panel's green and blue emitters read brighter than the red at equal
-- drive, which is what pushed orange toward yellow and left one stick looking
-- cyan where the other looked green. Trimming the two brighter channels shifts
-- mixed hues back warm and costs only a little brightness on pure green and
-- blue. Tune here if a future panel behaves differently.
local GAIN_R, GAIN_G, GAIN_B = 1.0, 0.85, 0.85

-- A DELIBERATE MANUAL EXCEPTION, and the only one.
--
-- The celestial pack is a near-black starfield. Sampling it is a coin toss:
-- there is barely any coloured area to vote with, so whichever few pixels do
-- have a hue decide the whole result, and it came out orange. The coverage
-- scaling dims that but cannot make it right, because the problem is not the
-- brightness of the answer -- it is that the screen genuinely has no dominant
-- hue and the honest answer is "almost nothing".
--
-- So this one state says so directly rather than being tuned toward. Barely
-- lit white, and the per-channel gains are skipped: at this level a warm trim
-- would only be a rounding difference, and the intent here is neutral.
local CELESTIAL_LEVEL = 6     -- 0..255, per channel

-- A fixed colour for ordinary (non-boss) rounds was tried here -- the felt
-- is one known green, so a constant seemed strictly better than an estimate.
-- In practice it was WORSE: the frame changes with what is happening (highlighted cards, scoring
-- flashes, the played hand lifting away), and a constant makes the LEDs read
-- as dead where the sampled colour breathes with the game. The celestial
-- override above survives because its screen genuinely has nothing to
-- sample; a live round always does. Resist re-adding constants here.

local canvas = nil
local cur = nil               -- {r,g,b} being eased toward the target
local last_at = 0

-- Reused across calls; this runs ten times a second and should not allocate.
local bin_w = {}

local function clamp255(v)
    v = math.floor(v + 0.5)
    if v < 0 then return 0 elseif v > 255 then return 255 end
    return v
end

--- Fully saturated colour at `hue` degrees, scaled to `val` (0..1).
local function hsv_full(hue, val)
    local h = (hue % 360) / 60
    local i = math.floor(h)
    local f = (h - i) ^ HUE_PURIFY
    local v = val * 255
    local q, t = v * (1 - f), v * f
    local r, g, b
    if     i == 0 then r, g, b = v, t, 0
    elseif i == 1 then r, g, b = q, v, 0
    elseif i == 2 then r, g, b = 0, v, t
    elseif i == 3 then r, g, b = 0, q, v
    elseif i == 4 then r, g, b = t, 0, v
    else               r, g, b = v, 0, q end
    return clamp255(r * GAIN_R), clamp255(g * GAIN_G), clamp255(b * GAIN_B)
end

--- The frame's dominant colour, or nil if unavailable.
local function sample_frame()
    local src = G and G.CANVAS
    if not src then return nil end

    -- The celestial pack, before any sampling: see CELESTIAL_LEVEL. Reading
    -- the state directly, because that is what identifies the pack --
    -- create_UIBox_celestial_pack is built on the PLANET_PACK path
    -- (game.lua:3538-3560).
    if G.STATE and G.STATES and G.STATE == G.STATES.PLANET_PACK then
        return { r = CELESTIAL_LEVEL, g = CELESTIAL_LEVEL, b = CELESTIAL_LEVEL }
    end

    if not canvas then
        local ok, c = pcall(love.graphics.newCanvas, SAMPLE_W, SAMPLE_H,
                            { dpiscale = 1 })
        if not ok or not c then return nil end
        canvas = c
    end

    local sw, sh = src:getDimensions()
    if not sw or sw <= 0 or sh <= 0 then return nil end

    local prev = love.graphics.getCanvas()
    love.graphics.push()
    love.graphics.origin()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setShader()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(src, 0, 0, 0, SAMPLE_W / sw, SAMPLE_H / sh)
    love.graphics.setCanvas(prev)
    love.graphics.pop()

    local img = canvas:newImageData()
    local str = img:getString()
    if img.release then img:release() end

    for i = 1, BINS do bin_w[i] = 0 end
    local total, bright_sum, n = 0, 0, 0

    for i = 1, #str - 3, 4 do
        local r, g, b = str:byte(i, i + 2)
        local mx = r; if g > mx then mx = g end; if b > mx then mx = b end
        local mn = r; if g < mn then mn = g end; if b < mn then mn = b end
        local c = mx - mn
        if c >= MIN_CHROMA then
            -- Standard hue sextants, in units of 60 degrees.
            local h
            if mx == r then
                h = (g - b) / c
                if h < 0 then h = h + 6 end
            elseif mx == g then
                h = (b - r) / c + 2
            else
                h = (r - g) / c + 4
            end
            local idx = math.floor(h * 4) % BINS + 1   -- h*60/15 == h*4
            bin_w[idx] = bin_w[idx] + 1
            total = total + 1
        end
        bright_sum = bright_sum + mx
        n = n + 1
    end
    if n == 0 then return nil end

    -- A screen with no hue at all -- the intro's fade to white, a black
    -- transition -- gets a dim neutral rather than an invented colour.
    if total < n * 0.02 then
        local v = clamp255(bright_sum / n * 0.35)
        return { r = v, g = clamp255(v * GAIN_G), b = clamp255(v * GAIN_B) }
    end

    -- Score each bin together with its two neighbours, so a hue sitting on a
    -- bin boundary is not split into two losing halves.
    local best, best_score = 1, -1
    for i = 1, BINS do
        local l = (i - 2) % BINS + 1
        local r = i % BINS + 1
        local score = bin_w[l] + bin_w[i] + bin_w[r]
        if score > best_score then best, best_score = i, score end
    end

    -- Mean hue across the winning arc, measured as an offset from the centre
    -- bin so the wrap at 360 degrees cannot skew it.
    local lo = (best - 2) % BINS + 1
    local hi = best % BINS + 1
    local wsum = bin_w[lo] + bin_w[best] + bin_w[hi]
    if wsum <= 0 then wsum = 1 end
    local offset = (bin_w[hi] - bin_w[lo]) / wsum          -- -1 .. +1 bins
    local hue = ((best - 1) + 0.5 + offset) * (360 / BINS)

    -- Value from the whole frame, then scaled by the winner's coverage.
    local coverage = wsum / n
    local conf = coverage / COVERAGE_FULL
    if conf > 1 then conf = 1 end

    local val = (V_FLOOR + V_RANGE * (bright_sum / n / 255)) * conf
    if val > 1 then val = 1 end

    local r, g, b = hsv_full(hue, val)
    return { r = r, g = g, b = b }
end

--- Called once per drawn frame, after the game has rendered into G.CANVAS.
--- Self-throttling; a tick that is not due costs one comparison.
function led.reconcile()
    local settings = require("dualscreen.settings")
    if not settings.rgb_leds() then
        -- Disabled: forget our state so re-enabling starts from the live
        -- colour instead of easing out of something stale.
        cur = nil
        return
    end

    local now = love.timer.getTime()
    if now - last_at < SAMPLE_MS then return end
    last_at = now

    local want = sample_frame()
    if not want then return end

    if not cur then
        cur = { r = want.r, g = want.g, b = want.b }
    else
        cur.r = cur.r + (want.r - cur.r) * LERP_FACTOR
        cur.g = cur.g + (want.g - cur.g) * LERP_FACTOR
        cur.b = cur.b + (want.b - cur.b) * LERP_FACTOR
    end

    local r, g, b = clamp255(cur.r), clamp255(cur.g), clamp255(cur.b)
    if led._r and math.abs(r - led._r) < MIN_DELTA
       and math.abs(g - led._g) < MIN_DELTA
       and math.abs(b - led._b) < MIN_DELTA then
        return
    end
    led._r, led._g, led._b = r, g, b

    require("dualscreen.bridge").set_leds(r, g, b)
end

return led
