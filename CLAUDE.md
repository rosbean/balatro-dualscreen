# Project context

An Android app that plays Balatro across **both screens of a dual-screen
handheld** — hand selection plus Play/Sort/Discard on the secondary display, a
conventional landscape layout on the primary. Developed against the AYN Thor.

## This is NOT a fork of Balatro

It is an Android app + a Lua overlay + a build script. The person building it
supplies their own copy of the game.

```
  this repo (android/, lua/dualscreen/, tools/)  +  a Balatro.app or .exe
                              ↓
        tools/build.py: extract → inject overlay → Game.love → Gradle → APK
```

**No Balatro code or assets in the repo. Ever.** Not Lua, not textures, not
sounds, not localizations, not the icon. This is what makes the project
publishable, and it is rule #1. `tools/check_guards.py` enforces it; run it
before committing and verify with `git ls-files` rather than assuming.

The overlay works by reassigning globals at load time — `set_screen_positions`,
`CardArea:move`, `Game:draw`, `love.resize` and friends are all globals with
nothing shadowing them. The build appends exactly one line to the extracted
`main.lua`: `require "dualscreen.init"`. That is the entire modification to
vanilla.

**Wrap, don't replace.** A wrapper inherits upstream fixes; a wholesale copy
silently reverts them *and* re-imports copyrighted code. Any wholesale copy
needs a written justification in `docs/decisions/`.

## Layout

```
.                                  ← project root = the git repo
├── docs/
│   ├── android-build.md               toolchain versions and rationale
│   └── decisions/                     ADRs
├── lua/dualscreen/                ← the Lua overlay. No Balatro code.
├── android/                       ← vendored love-android + this project's Java
├── tools/
│   ├── check_balatro_source.py        container validation
│   ├── check_guards.py                rule #1 and related invariants
│   ├── extract_icon.py                icon from the supplied container
│   ├── make_release_icon.py           regenerates the original release icon
│   └── build.py                       extract → inject → package → APK
├── local-balatro/    GITIGNORED   test containers (.app and .exe)
├── reference/        GITIGNORED   read-only third-party material
└── build/            GITIGNORED   scratch output
```

`android/` is a **vendored** copy of love-android 11.5a. Treat it as
third-party: the only edits are this project's own classes under
`android/app/src/main/java/com/balatro/dualscreen/`, plus three visibility
keywords in `org/love2d/android/GameActivity.java` (documented in place).

Anything under `reference/` is read-only third-party material. **Never edit
it.** Note that BanjoRecomp carries its own `docs/` and `src/` — do not confuse
them with this project's.

## Two build modes

```bash
python3 tools/build.py --balatro <container>   # dev: game embedded in the APK
python3 tools/build.py --release               # publishable: no game data
```

The release APK ships no Balatro at all; `SetupActivity` assembles the game on
device from a copy the person supplies at first launch (`GameAssembler`), and
`BalatroActivity` boots the engine from it. The dev build embeds `game.love`
directly and skips the setup screen. Anything touching the release path must
keep the APK free of game data — check the built APK, not just the source.

## Build against BOTH container formats

`local-balatro/` holds a macOS `.app` and a Windows `.exe`. Their game data is
byte-for-byte identical, so they cannot produce different output — but the
build script's *container handling* has two code paths, and people arrive with
either. If the two ever disagree, the container handling is wrong.

```bash
python3 tools/check_balatro_source.py local-balatro/Balatro.app
```

Anything touching extraction, injection or packaging is incomplete until run
against both with an identical resulting `Game.love`.

The two containers are **not** equivalent for icons: the `.app` carries the
game's real artwork in `GameIcon.icns`, while the `.exe` carries it only at
32 px in a second RT_GROUP_ICON (its largest icon is LÖVE's stock heart).

## Ground rules

- **No Balatro code or assets committed.** Verify, don't assume.
- **Wrap, don't replace.** Justify any wholesale function copy in `docs/decisions/`.
- **Always leave a working build.** Never end unable to produce a launching APK.
- **Verify on a device.** "The code looks right" is not verification.
- **No device-specific constants.** Detect the second display by
  `FLAG_PRESENTATION`, never by model string or by matching a resolution.
- **Preserve single-screen behaviour.** Every dual-screen path needs a null
  path: with the second screen off, or absent, behaviour must match vanilla.
- **Comments explain why, not history.** Cite vanilla `file:line` when the
  reason lives in the game's own code. No changelog narrative in comments.

## Environment

- Target: arm64-v8a, Android 8.0+ (API 26); developed against Android 13.
- Toolchain versions and rationale: `docs/android-build.md`.
  **JDK 17 is a window, not a floor** — AGP 8.1.1 needs ≥17, Gradle 8.1 cannot
  run on ≥20.
- Engine: **LÖVE 11.5**, vendored as love-android **11.5a**. 11.5's `embed`
  flavour cannot load an embedded game at all; 11.5a fixes it and ships the
  same engine submodule.
- Base game version: Steam **1.0.1o `PROD_PC_Console`**.
- LÖVE's `print()` reaches logcat as tag **`SDL/APP`**; this project's Java logs
  as **`BalatroDS`**:
  ```bash
  adb logcat -s SDL/APP:I BalatroDS:I
  ```
- Do not keep the working copy inside a cloud-synced folder. Sync races Gradle's
  build intermediates, producing misleading D8 "defined multiple times" errors
  and silently doubling APK size.

## Licensing

**GPL-3.0**, because it derives from BanjoRecomp (GPL-3.0). See `COPYING` and
`NOTICE.md`.
