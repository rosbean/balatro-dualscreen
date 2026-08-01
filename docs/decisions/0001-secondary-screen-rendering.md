# ADR 0001 — Render the hand in LÖVE and ship pixels to screen 2 (route b)

**Status:** Accepted — **amended after implementation, see the amendment at the end**
**Decides:** the rendering strategy for the secondary display
**Measured on:** the AYN Thor

## Context

Screen 2 is an Android `Presentation` — an ordinary `View`, not an engine render target
(ADR 0000, and the architecture doc §6). So the hand has to get from LÖVE onto that view
somehow. Two routes were left open until a number existed:

**Route (a) — reimplement card rendering in Java.** Extract `8BitDeck.png`, `Enhancers.png`
and `ui_assets.png` at build time, draw the fan, enhancements, seals and selection lift with
Android Canvas 2D. No readback cost at all.

**Route (b) — render the hand in LÖVE, ship the pixels.** Draw `G.hand` and `G.buttons` to
an off-screen canvas, read it back with `Canvas:newImageData()`, push the bytes to Java.

The blocker was that `Canvas:newImageData()` is a **synchronous GPU readback**. It stalls the
render thread until the GPU has finished and the pixels have crossed back over the bus.
Mobile tile-based GPUs are much worse at this than desktop ones, by a margin that cannot be
predicted from desktop numbers. So it had to be measured on the device.

The build plan set the thresholds in advance, before any number was known:

| Measured | Verdict |
|---|---|
| < 8 ms | route (b) comfortable |
| 8–30 ms | route (b) viable **event-driven only** |
| > 30 ms | visible hitching — choose route (a) |

## Measurement

Overlay-driven benchmark (`lua/dualscreen/bench.lua`), 30 iterations per size after a
discarded warm-up, on the Thor. Renderer: OpenGL ES. Two independent runs agreed.

| Region | Pixels | min | **median** | p95 | max |
|---|---|---|---|---|---|
| hand, landscape scale (1180 × 251) | 0.30 Mpx | 0.75 | **1.01 ms** | 1.27 | 1.29 |
| full secondary panel (1240 × 1080) | 1.34 Mpx | 3.27 | **3.71 ms** | 4.19 | 4.46 |

Cost is roughly linear in area, about **2.8 ms per megapixel**.

The figure that binds is the **full-panel 3.71 ms**, since it is a strict upper bound on
anything route (b) would ever read back — a hand region is a subset of it.

## Decision

**Route (b). Render the hand in LÖVE and ship pixels.**

The full panel reads back in 3.71 ms median, 4.46 ms worst observed. That is **2.2× under the
"comfortable" threshold**, and the realistic hand-sized region at 1.01 ms is **8× under**.
Even the worst single sample never approached 8 ms.

For scale: one frame at 60 fps is 16.7 ms. A full-panel readback is 22% of a frame; a
hand-sized one is 6%.

**Route (b) also wins on correctness, independently of cost.** It preserves the edition
shaders — foil, holo, polychrome, negative, gold seal — exactly as the game draws them.
Under route (a) those degrade to flat art, and the architecture doc §8 is right that this is
*gameplay information loss*, not cosmetics: a player selecting cards on screen 2 could not
tell a polychrome card from a plain one. Route (a) would have needed a real design answer to
that. Route (b) does not raise the question.

So the two considerations point the same way, and the cheaper-to-maintain option (one
renderer, not two) is also the more faithful one.

## Consequences

- **Route (b) is implemented.** Render `G.hand` and `G.buttons` to an off-screen canvas
  sized from the secondary display's *queried logical* dimensions — `getRealSize()` or
  `getSize()`, **never `getMode()`**, which reports the native portrait panel.
- **Push on hand mutation, not per frame.** The headroom would technically allow per-frame at
  the hand size, but there is no reason to spend 6% of every frame plus the bus traffic on
  redrawing a static hand.
- **Ambient sway must still be suppressed for the screen-2 render.** `cardarea.lua` has ten
  `math.sin(G.TIMERS.REAL …)` terms (from line 439; the hand's own are 439 and 444) which
  mean the hand is *never* visually static. Without suppressing them, "push on change" degrades
  into "push every frame". All ten are already gated on
  `(G.SETTINGS.reduced_motion and 0 or 1)`, so forcing that flag around the screen-2 render is
  cheaper than patching the expressions.
- **The second renderer is not built.** No Java card drawing, no build-time atlas extraction,
  no duplicate enhancement/seal/edition logic to keep in sync with upstream.
- **Route (a) remains the documented fallback** if the numbers ever change.

## What would reverse this

- **A measured median above 8 ms** for the region actually being pushed, on hardware this
  project supports. The benchmark is in `lua/dualscreen/bench.lua`; re-run it rather than
  re-reasoning.
- **A requirement for genuinely per-frame screen-2 updates** at full-panel size — 3.71 ms
  every frame is 22% of a 60 fps budget, which is affordable but no longer negligible.
- **A future LÖVE version making readback asynchronous**, which would strengthen route (b)
  further rather than reverse it.

Note the thresholds were fixed in the build plan *before* the measurement, so this is not a
number chosen to justify a preference.

---

## Amendment — the original measurement was 5.3x too pessimistic, and the whole pipeline is cheap

Two things changed once it was built. The decision stands; the numbers behind it did not.

### The original measurement used oversized canvases

`love.graphics.newCanvas(w, h)` defaults a canvas's **pixel** dimensions to
`w * dpiscale` x `h * dpiscale`. This device reports `love.graphics.getDPIScale() = 2.3077`
(matching the device's 369 dpi / `density=2.30625`). A 10x10 canvas comes back as
**23x23**:

```
format probe: 10x10 canvas -> format=rgba8  getWidth=23  #getString=2116  (expect 400)
```

So the original `newCanvas(1240, 1080)` actually allocated **2860 x 2491 = 7.1 Mpx**, not
1.34 Mpx, and its "3.71 ms full panel readback" was the cost of a canvas 5.3x larger than the
one route (b) will use. Pinning `{dpiscale = 1}` gives the intended size and the true figure:

| | unpinned | pinned (`dpiscale = 1`) |
|---|---|---|
| actual canvas | 2860 x 2491 | 1240 x 1080 |
| payload | 27.2 MiB | 5.1 MiB |
| readback | 3.71 ms | **1.28 ms** |

**The error was conservative** — route (b) was chosen against a number 3x worse than reality —
so the decision needs no revisiting. But `{dpiscale = 1}` is now mandatory on every canvas
the overlay creates. Omitting it costs 5.3x the memory and 5.3x the time, silently.

### The full pipeline, measured

ADR 0001 originally timed `newImageData()` alone, which was sufficient while route (b) pushed
only on hand mutation. Rendering the animated background means pushing continuously, so
Every stage was timed:

| region | payload | readback | `getString` | JNI + Bitmap blit | **total** | ceiling |
|---|---|---|---|---|---|---|
| full panel 1240 x 1080 | 5231 KiB | 1.28 | 0.60 | 1.87 | **3.75 ms** | 266 fps |
| half panel 620 x 540 | 1308 KiB | 0.50 | 0.09 | 0.43 | **1.02 ms** | 977 fps |
| hand strip 1240 x 320 | 1550 KiB | 0.57 | 0.17 | 0.54 | **1.28 ms** | 782 fps |

Java-side `Bitmap.copyPixelsFromBuffer` is ~1.8 ms of the full-panel figure, measured
independently on the UI thread.

### Amended decision

**Render the background as well as the hand, and push the whole panel live.**

3.75 ms is under the 8 ms threshold the build plan pre-registered for "push background + hand
together at 30 Hz; screen 2 is fully live". At 30 Hz the cost is ~11% of the frame budget
amortised; even at 60 Hz it is 22%, the same share ADR 0001 already accepted for a
readback alone.

Consequences on top of the original:

- **Draw order into the off-screen canvas: background, then `G.hand`, then `G.buttons`.**
- **Pin `{dpiscale = 1}` on every canvas.** Non-negotiable, per above.
- **Reuse the Bitmap and its direct ByteBuffer across frames.** Reallocating 5.4 MB per frame
  would dominate the cost.
- **The background tracks screen 1 for free.** Its uniforms come from `G.C.BACKGROUND`, which
  the game eases per blind through `ease_background_colour_blind`, so rendering with the same
  uniforms keeps both panels in the same colour state with no extra plumbing.
- **Ambient sway suppression is no longer needed for correctness**, only for economy. With a
  live background the panel is repainting anyway, so the sway can simply be left alone — one
  fewer thing to fight. The `G.SETTINGS.reduced_motion` trick stays available if a lower push
  rate is ever wanted.

### What would reverse the amendment

A measured full-pipeline cost above ~8 ms on hardware this project supports — re-run
`bench.run_pipeline()`. Note it must be re-run with `{dpiscale = 1}`; without it the answer is
5.3x too pessimistic and would wrongly push the design toward route (a).
