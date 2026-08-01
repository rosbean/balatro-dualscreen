# Balatro Dual Screen

Play [Balatro](https://www.playbalatro.com/) across **both screens** of a
dual-screen Android handheld. Your hand, the Play/Sort/Discard buttons and the
shop live on the lower touchscreen; the table, jokers and score stay on top.

The lower screen is not a remote control or a redrawn mock-up. It is Balatro
rendering Balatro: real card sprites with their enhancements, editions and
seals, the same animated background as the top screen, drag-to-reorder,
hold-to-inspect tooltips, and full controller support.

Built and tested on the **AYN Thor**. Nothing in the code is tied to that
device — the second screen is found through Android's display API, not by model
name — but that is the only hardware this has been tested on.

> **This mod is free.** If you paid money for it, demand a refund.

---

## What it does

- **Hand on the lower screen** — cards, Play / Sort / Discard, all touch-driven.
- **Shop, blind select, booster packs and menus** move down too, so whatever
  you are interacting with is under your thumbs.
- **Optional extras**, each a toggle in *Options → Settings → Dual Screen*:
  - hand score and consumables on the lower screen
  - a wider joker row that uses the space freed up top
  - the game's CRT effect applied to the lower screen as well
  - RGB stick lighting that follows the on-screen colours (AYN Thor)
  - a 60 FPS cap to save battery, or 120 if you prefer
- **Controller and touch** both work throughout.
- **Single-screen safe** — with the second screen switched off, or on a device
  that has only one, the game behaves exactly like vanilla.

## Requirements

- A dual-screen Android device (Android 8.0 / API 26 or newer).
- **Your own legally purchased copy of Balatro for PC or Mac.** This app
  contains no part of the game.
- Supported version: **Steam 1.0.1o**. Other PC versions may work but are
  untested.

### Which copies work

| Container | Works |
| --- | --- |
| `Balatro.exe` (Steam, Windows) | yes |
| `Balatro.app` (Steam, macOS) — zipped | yes |
| `Balatro.love` | yes |
| iOS / Mac App Store build | **no** |
| Console builds | **no** |

The mobile build depends on `love.platform`, a launcher module that ships with
Apple's build of the game rather than with LÖVE itself, across 44 call sites.
`love-android` has no such module, so the game cannot start. The app rejects
that build explicitly rather than failing later in a confusing way.

## Install

1. Download the latest APK from the [**Releases**](../../releases) tab.
2. Copy it to your device and install it. Android will ask you to allow
   installing apps from this source — normal for anything outside the Play
   Store.
3. Get your Balatro copy onto the device:
   - **Windows:** `Balatro.exe`, from `Steam\steamapps\common\Balatro\`
   - **macOS:** a **ZIP** of `Balatro.app`, from
     `~/Library/Application Support/Steam/steamapps/common/Balatro/`
     (a `.app` is a folder, so it must be zipped to copy it across)
   - or a `Balatro.love` archive

   Anywhere the device's file picker can reach is fine — `Downloads` is easiest.
4. Open the app. On first launch it asks you to choose that file, checks it,
   and builds your game. This takes a few seconds.
5. It offers to add a home-screen shortcut, then starts the game.

Your Balatro copy is only read during that build. The game is assembled into
the app's private storage; nothing is uploaded anywhere.

### Updating

Install the new APK over the old one and open it. To force a rebuild from
scratch, clear the app's storage first (Android Settings → Apps → Balatro Dual
Screen → Storage) — note that this also removes in-app saves.

## Building from source

You do not need to build anything to play — use the Releases tab. To build it
yourself:

```bash
python3 tools/build.py --balatro /path/to/Balatro.app     # or Balatro.exe
```

That extracts the game, adds the overlay, packages it and produces an APK with
the game already inside, which is convenient for development. To build the
publishable APK instead, which contains no game data:

```bash
python3 tools/build.py --release
```

To check a copy of the game before building with it:

```bash
python3 tools/check_balatro_source.py /path/to/your/Balatro.app
```

You need the Android SDK/NDK and a JDK; exact versions and rationale are in
[`docs/android-build.md`](docs/android-build.md).

## How it works

This is not a fork of Balatro. It is an Android app, a Lua overlay and a build
script. Your copy of the game supplies everything else.

```
  this repo (android/, lua/dualscreen/, tools/)  +  your Balatro copy
                              |
              extract -> add overlay -> Game.love -> APK
```

The overlay reassigns a handful of globals when the game loads, so it inherits
upstream behaviour rather than replacing it. Exactly one line is added to the
game's own `main.lua`.

Design decisions and the reasoning behind them are recorded in
[`docs/decisions/`](docs/decisions/).

## Support

If you enjoy this and want to say thank you:

[![Support me on Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20me-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/rosbean)

Entirely optional, and always appreciated.

## Licence and credits

Released under the **GNU General Public License v3.0** — see [`COPYING`](COPYING).

This project stands on work others did first:

- **[BanjoRecomp](https://github.com/BanjoRecomp/BanjoRecomp)** (GPL-3.0) — the
  working dual-screen Android implementation this one learned from. Code is
  lifted and adapted from it, which is why this project is GPL-3.0.
- **[Bifrost](https://github.com/Pollux-MoonBench/Bifrost)** (GPL-3.0) by
  Pollux-MoonBench — an LED controller for the AYN Thor. Its `LedController`
  worked out how to reach the stick LEDs, and the RGB lighting here follows
  that technique.
- **[balatro-portrait-mobile](https://github.com/ShaggyLorean/balatro-portrait-mobile)**
  by ShaggyLorean — prior art that showed Balatro's layout can be reflowed on
  Android, and where the layout logic lives. Read as reference only: it carries
  no licence grant, so **no code from it is used here**.

[`NOTICE`](NOTICE) records exactly what came from where.

### Built with AI assistance

This project was written with substantial help from an AI coding assistant
(Claude). Design decisions, testing on real hardware and every judgement call
about what to keep were the author's; a great deal of the implementation,
investigation and documentation was produced in collaboration with the model.

Mentioned because you deserve to know what you are installing and reading. It
does not change what the code does or how carefully it was tested — every
feature here was verified on a physical device before it shipped — but if that
matters to you, now you know before you download it.

Balatro is © LocalThunk, published by Playstack. This project is an unofficial
fan modification, not affiliated with or endorsed by either. It contains no
Balatro code or assets, and you must own the game to use it.
