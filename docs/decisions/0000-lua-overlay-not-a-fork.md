# ADR 0000 — Lua overlay, not a fork of Balatro

**Status:** Accepted
**Supersedes:** the fork-based approach described in earlier drafts of the build plan

## Context

The project began by building on `balatro-portrait-mobile 1.6.0`, a whole-file fork of
Balatro's Lua source (32 files, ~35,000 lines). The assumption was that it had "lots of
legwork done for us".

Two things then changed.

**The goal became a public release** where others build their own APK from source. That makes
what the repo *contains* a first-class concern rather than an incidental one. A fork puts
33,773 lines of LocalThunk's Lua into a repository intended for publication.

**The portrait mod's actual contribution was measured.** Against genuine vanilla 1.0.1o:

| | |
|---|---|
| Total change set | **1191 real lines** across 12 of 32 files |
| Files byte-identical to vanilla | 20 of 32 |
| `UI_definitions.lua` — portrait layouts we replace | 631 lines |
| `main.lua` — orientation forcing + a latent touch bug | 196 lines |

Roughly two-thirds is discarded by this design. What survived under the fork model
was about 200 lines of Python asset plumbing.

## Alternatives considered

**Fork the portrait mod** (the original plan). Its one genuine asset was proof that this Lua
boots on love-android 11.5. That evaporated once a clean Steam `PROD_PC_Console` copy was
acquired — the property belongs to vanilla, and the mod was only ever a carrier for it.

**Rebase onto Balatro's official mobile build.** Attractive on paper: native landscape, real
touch primitives (`Node:simple_touch`, `can_long_press`, `can_hover_on_drag`), `G.F_MOBILE`.
**Ruled out** — it depends on `love.platform.*`, a proprietary LocalThunk launcher module
that is not part of LÖVE, at 44 call sites across 9 files including `save_manager.lua` and
`string_packer.lua`. It cannot run on stock love-android.

**Unified-diff patches** applied to the user's copy at build time. Zero copyrighted code in
the repo, but brittle: a diff breaks if any line moves.

## Decision

Build a **runtime Lua overlay**. The repo contains an Android project, our own Lua, and a
build script. The user supplies their own Balatro copy.

Balatro's Lua is almost entirely globals — every function this project needs
(`set_screen_positions`, `CardArea:move`, `Game:draw`, `love.resize`, `love.mousepressed`)
is a global with nothing shadowing it **[verified]**. So the overlay reassigns them at load
time.

The build appends **one line** to the extracted `main.lua`:

```lua
require "dualscreen.init"
```

That works because `main.lua`'s requires end at line 29, `love.load` is *defined* at line 86,
and the file ends at 388 **[verified]** — code appended at the end runs after every class and
callback exists, but before anything executes.

**Governing rule: wrap, don't replace.** A wrapper survives anything short of a rename or a
signature change, and inherits LocalThunk's future fixes. A wholesale copy silently reverts
them *and* re-imports copyrighted code.

## Consequences

**Good.** Zero Balatro code in the repo, so the project is publishable. Version bumps mean
fixing a handful of wrappers rather than re-forking 35k lines. Cross-platform is a non-issue
— the two Steam depots are byte-identical, so only container handling differs.

**Costs.** Overrides are harder to debug than direct edits. A few functions may need
wholesale replacement rather than wrapping — each needs its own ADR. Users must supply a
Steam or GOG copy; the iOS / Mac App Store build will not work, and the build script must
detect and refuse it with a clear message.

**Rejected-approach note.** Do not re-explore the mobile build as a base, or a single spanned
framebuffer for the two screens. Both are ruled out with evidence in
the architecture notes.

## Postscript: the fork was never legally available anyway

Discovered after the decision was made, and it validates it on a second, independent axis.

`balatro-portrait-mobile` **carries no licence grant** — its README says only "This mod is
provided as-is for personal use", and the repo contains no LICENSE file. That is not an
open-source licence. Forking it into a GPL-3.0 repository intended for public release was
never actually an option, whatever its technical merits.

So the project's lineage is narrower than it first appeared:

| Source | What we take | Licence consequence |
|---|---|---|
| **BanjoRecomp** | Actual code — display manager, Presentation, JNI pattern, lifecycle gating | GPL-3.0. This is why *this* repo is GPL-3.0. |
| **balatro-portrait-mobile** | Nothing. Findings only, already extracted into `docs/` | None — no code taken, none permitted |
| **Vanilla Balatro** | Nothing in the repo; supplied by the user at build time | None |

Accurate description of this project: **a BanjoRecomp-derived Android dual-screen companion
app, targeting Balatro, informed by research on the portrait mod.**

`NOTICE.md` should credit the portrait mod as prior art and research input, and be explicit that
no code was taken from it.
