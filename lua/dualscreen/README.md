# `lua/dualscreen/` — the runtime overlay

This project's own Lua. **No Balatro code belongs here, ever.**

At build time `tools/build.py` copies this directory into the extracted game and
appends exactly one line to the game's `main.lua`:

```lua
require "dualscreen.init"
```

That append lands after `main.lua`'s `require` block (which ends at line 29) and
before `love.load` runs, so every class and callback exists but nothing has
executed yet.

## The rule

**Wrap. Do not replace.**

```lua
local orig = set_screen_positions
function set_screen_positions()
    orig()                              -- inherit vanilla, including future fixes
    if DS.active then ds_adjust() end   -- then adjust
end
```

A wrapper survives anything short of a rename or a signature change, and it
keeps LocalThunk's code out of this repository. Any wholesale copy of a vanilla
function needs a written justification in `docs/decisions/`.
