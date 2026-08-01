-- balatro-dualscreen-thor -- the Android soft keyboard for text entry.
--
-- WHY THIS EXISTS. Balatro accepts text one key at a time through
-- love.keypressed -> G.FUNCS.text_input_key (button_callbacks.lua:964). It has
-- no love.textinput handler and never calls love.keyboard.setTextInput, which
-- is reasonable on desktop and on consoles: desktop players have a real
-- keyboard, and console players get the game's OWN on-screen keyboard, built by
-- create_keyboard_input and shown only when G.CONTROLLER.HID.controller is set
-- (button_callbacks.lua:912).
--
-- On a handheld running the desktop build, neither applies. There is no
-- physical keyboard, and touching the seed field sets HID to touch -- which is
-- correct, and which is exactly why the game's own keyboard does not appear.
-- The field can be focused and nothing can be typed into it.
--
-- So: raise the Android soft keyboard when a text field is hooked, and route
-- what it produces into the game's own per-key entry point.
--
-- THE DIVISION IS DELIBERATE:
--
--   touch      -> Android's keyboard (here)
--   controller -> Balatro's built-in on-screen keyboard (vanilla, untouched)
--
-- Both are left to do what they are good at, and neither is ever on screen at
-- the same time as the other.

local keyboard = {}

local shown = false

--- Is a text field currently accepting input, and by touch rather than pad?
local function wants_soft_keyboard()
    local c = G and G.CONTROLLER
    if not c or not c.text_input_hook then
        return false
    end
    -- Controller mode gets the game's own keyboard; do not stack ours on top.
    if c.HID and c.HID.controller then
        return false
    end
    return true
end

--- Raise or dismiss the soft keyboard to match the game's state.
--- Called every update; only acts on a change.
function keyboard.update()
    if not love.keyboard or not love.keyboard.setTextInput then
        return
    end
    local want = wants_soft_keyboard()
    if want == shown then
        return
    end
    shown = want
    pcall(love.keyboard.setTextInput, want)
    if DS and DS.log then
        DS.log("soft keyboard " .. (want and "shown" or "hidden"))
    end
end

--- Swallow the keypressed twin of a soft-keyboard character.
---
--- SDL delivers a soft-keyboard key as BOTH a keypressed and a textinput, and
--- vanilla already turns keypressed into text -- so every letter arrived twice.
---
--- Rather than dropping the textinput route and relying on keypressed, this
--- keeps textinput as the single source of truth for TEXT and consumes its
--- keypressed twin. Gesture typing and autocomplete send textinput WITHOUT a
--- per-key keypressed, so the keypressed route alone would silently type
--- nothing on those keyboards.
---
--- Only text keys are consumed. LOVE names a printable key by its character,
--- so a one-character name is text; `space` is spelled out but still arrives as
--- a textinput " ". Everything else -- backspace, return, the arrows -- is left
--- to vanilla, which handles it correctly and which textinput never reports.
function keyboard.keypressed(key)
    if not shown then
        return false
    end
    return key == "space" or #key == 1
end

--- Feed a character into the hooked field.
---
--- G.FUNCS.text_input_key takes one key at a time and accepts a plain character
--- as its `key` -- paste_seed drives it exactly this way, a character per call
--- (button_callbacks.lua:941). Backspace and return are NOT handled here: the
--- soft keyboard delivers those as ordinary keypressed events, which vanilla
--- already routes.
function keyboard.textinput(text)
    local c = G and G.CONTROLLER
    if not c or not c.text_input_hook then
        return false
    end
    if not G.FUNCS or not G.FUNCS.text_input_key then
        return false
    end
    for i = 1, #text do
        pcall(G.FUNCS.text_input_key, { key = text:sub(i, i) })
    end
    return true
end

return keyboard
