-- balatro-dualscreen-thor -- the Lua side of the Lua <-> Java bridge.
--
-- Talks to the native module built at
--   android/love/src/jni/lua-modules/dsbridge/
-- which exposes exactly three functions:
--
--   dsbridge.push(string)  -> boolean   send a snapshot to Java
--   dsbridge.poll()        -> string?   take one semantic event from Java
--   dsbridge.available()   -> boolean   is a companion Presentation up?
--
-- Everything else -- serialising, generation tracking, event decoding -- is
-- here in Lua, so that changing the schema never means touching C.

local bridge = {}

-- require() is in a pcall on purpose. On a build without the native module, or
-- on a desktop run, this must degrade to single-screen rather than erroring at
-- load. Every dual-screen path needs a null path.
local ok, ds = pcall(require, "dsbridge")
if not ok then
    ds = nil
end

bridge.native_available = (ds ~= nil)

--------------------------------------------------------------------------
-- Generation counter.
--
-- NOT OPTIONAL. Every snapshot carries a monotonically increasing counter,
-- every event echoes back the generation it was decided against, and events
-- whose generation does not match the current one are dropped.
--
-- Without it, a tap that lands during a deal animation acts on whichever card
-- now occupies that index. Rare wrong-card plays, essentially impossible to
-- reproduce on demand and miserable to diagnose after the fact.
--------------------------------------------------------------------------
bridge.generation = 0

function bridge.bump()
    bridge.generation = bridge.generation + 1
    return bridge.generation
end

--------------------------------------------------------------------------
-- Serialisation
--
-- Wire format is semicolon-separated key=value, cards pipe-separated:
--   v=1;gen=42;mode=RUN;hands=3;...;cards=A,S,none,none,none,1,10,20,90,120|...
--
-- Deliberately not JSON: Balatro ships its own JSON handling and this project
-- may not touch game code, and adding a Lua JSON library to serialise ten
-- fields would be a poor trade. Parsed by CompanionSnapshot.parse().
--------------------------------------------------------------------------

-- Field separators must never appear inside a value.
local function clean(v)
    v = tostring(v or "none")
    return (v:gsub("[;|,=]", "_"))
end

local function bool01(v)
    return v and "1" or "0"
end

function bridge.serialise(snap)
    local parts = {
        "v=1",
        "gen=" .. tostring(snap.generation or bridge.generation),
        "mode=" .. clean(snap.mode or "BLACK"),
        "hands=" .. tostring(snap.hands or 0),
        "discards=" .. tostring(snap.discards or 0),
        "canPlay=" .. bool01(snap.can_play),
        "canDiscard=" .. bool01(snap.can_discard),
    }

    local cards = {}
    for i, c in ipairs(snap.cards or {}) do
        cards[i] = table.concat({
            clean(c.rank), clean(c.suit), clean(c.enhancement),
            clean(c.edition), clean(c.seal), bool01(c.highlighted),
            tostring(math.floor(c.x or 0)), tostring(math.floor(c.y or 0)),
            tostring(math.floor(c.w or 0)), tostring(math.floor(c.h or 0)),
        }, ",")
    end
    parts[#parts + 1] = "cards=" .. table.concat(cards, "|")

    -- There is no ui= field. Java no longer hit-tests anything: it
    -- reports the tap coordinate and Lua resolves it against DS.HASH2. The
    -- parser still ignores unknown keys, so this is a compatible removal.

    return table.concat(parts, ";")
end

--- Send a snapshot. Returns false if the bridge is absent or the push failed.
function bridge.push(snap)
    if not ds then
        return false
    end
    return ds.push(bridge.serialise(snap)) and true or false
end

--- Panel size of the companion content view, as w, h. nil when none is up.
--- Query it; never derive it from the display mode, which reports the native
--- PORTRAIT panel, nor assume it equals the display size -- the
--- system bar makes the view 1240x1025 against a 1240x1080 display.
function bridge.panel_size()
    if not ds or not ds.panel_size then
        return nil
    end
    local okp, s = pcall(ds.panel_size)
    if not okp or type(s) ~= "string" then
        return nil
    end
    local w, h = s:match("^(%d+)x(%d+)$")
    if not w then
        return nil
    end
    return tonumber(w), tonumber(h)
end

--- Ship a rendered frame. `data` is raw RGBA8 bytes.
function bridge.push_pixels(data, w, h)
    if not ds or not ds.push_pixels then
        return false
    end
    return ds.push_pixels(data, w, h) and true or false
end

--- Ship a rendered frame WITHOUT the string copy.
---
--- Takes the ImageData itself: its pixels are handed over as a raw pointer
--- (Data:getPointer) and memcpy'd once, native-side, into a persistent Java
--- buffer. The old path built a 5.2 MB Lua string per push -- at ~50 pushes/s
--- that is a quarter GIGABYTE of garbage a second through LuaJIT's collector,
--- plus a 5.2 MB Java array to match on the other side.
---
--- The pointer is only valid while `img` is alive; the native call memcpys
--- synchronously before returning, so the caller may release the ImageData
--- as soon as this returns.
function bridge.push_pixels_data(img, w, h)
    if not ds or not ds.push_pixels2 or not img or not img.getPointer then
        return false
    end
    local okp, res = pcall(function()
        return ds.push_pixels2(img:getPointer(), img:getSize(), w, h)
    end)
    return okp and res and true or false
end

--- Set the joystick LED colour, 0..255 each. No-op without the native module
--- or on a device without the vendor LED service.
function bridge.set_leds(r, g, b)
    if not ds or not ds.set_leds then
        return false
    end
    local ok, res = pcall(ds.set_leds, r, g, b)
    return ok and res and true or false
end

--- Is a companion Presentation currently up? This is what DS.active tracks.
function bridge.companion_showing()
    if not ds then
        return false
    end
    local okc, res = pcall(ds.available)
    return okc and res and true or false
end

--------------------------------------------------------------------------
-- Events, Java -> Lua
--
-- Wire format: NAME:arg:generation
--------------------------------------------------------------------------

local function split_event(s)
    local name, arg, gen = s:match("^([^:]*):([^:]*):([^:]*)$")
    if not name then
        return nil
    end
    return name, arg, tonumber(gen)
end

-- Events that must NOT be generation-checked.
--
-- Two kinds, for two different reasons:
--
--   COORDINATE events (CLICK, DRAG_CARD) resolve against live state when they
--   are applied, so they are self-validating. Gating them only ever drops
--   valid input.
--
--   END events (DRAG_END, HOVER_END) clear state. Dropping one leaves that
--   state stuck on -- a card still flagged as being dragged, or a tooltip that
--   never goes away -- and the fix for a missed clear is never "ignore it".
--   Observed:
--       stale event dropped: DRAG_END  (gen 46, current 47)
--       stale event dropped: HOVER_END (gen 46, current 47)
--   The drag itself had bumped the generation, so the release that ended it
--   was discarded. Applying a redundant clear is harmless; missing one is not.
local UNGATED = {
    CLICK = true, DRAG_CARD = true, HOVER_AT = true,
    DRAG_END = true, HOVER_END = true,
}

--- Drain the queue. Returns a list of {name, arg, generation}, stale dropped.
function bridge.poll_events()
    local out = {}
    if not ds then
        return out
    end

    -- Bounded so a flood can never stall a frame. The Java queue caps at 64;
    -- this drains at most that many per update.
    for _ = 1, 64 do
        local okp, raw = pcall(ds.poll)
        if not okp or raw == nil then
            break
        end

        local name, arg, gen = split_event(raw)
        if not name then
            bridge.log("malformed event dropped: " .. tostring(raw))
        elseif UNGATED[name] then
            -- See UNGATED above.
            --
            -- Generation matching exists because an INDEX decided against an
            -- old hand means something different against the new one -- "card
            -- 3" is a different card once the hand changes. A coordinate does
            -- not have that problem: DS.click_at resolves it against DS.HASH2
            -- as it stands when the event is applied, so it is self-validating.
            --
            -- Gating it actively broke things. Two taps in quick succession
            -- logged:
            --     stale event dropped: CLICK (gen 15, current 16)
            -- because the first tap bumped the generation before the second
            -- was drained -- so the second tap did nothing. DRAG_CARD was
            -- already exempt for the same reason.
            out[#out + 1] = { name = name, arg = arg, generation = gen }
        elseif gen ~= bridge.generation then
            -- The event was decided against a hand that no longer exists.
            bridge.log(("stale event dropped: %s (gen %s, current %d)")
                       :format(name, tostring(gen), bridge.generation))
        else
            out[#out + 1] = { name = name, arg = arg, generation = gen }
        end
    end
    return out
end

function bridge.log(msg)
    if DS and DS.log then
        DS.log("bridge: " .. tostring(msg))
    else
        print("[dualscreen] bridge: " .. tostring(msg))
    end
end

return bridge
