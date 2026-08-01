# 0002 — Rebuilding the HUD when a Dual Screen toggle changes

**Status:** OBSOLETE -- the toggle is instant via a different mechanism; no game code is restated. See Resolution.
**Date:** 2026-07-30

## Context

The overlay lifts the hand-score readout out of the HUD so the left pane repacks
without a gap (see `lua/dualscreen/hud.lua`). The extraction happens inside a
wrapper around `create_UIBox_HUD`, which the game calls **once per run**, at
`game.lua:2396`.

That makes the setting take effect only from the next run. Flipping it mid-run
appears to do nothing, which reads as a bug even when labelled.

## The problem

There is no vanilla entry point that rebuilds the HUD. The construction is
inline in `Game:start_run`:

```lua
self.HUD = UIBox{ definition = create_UIBox_HUD(), config = {...} }
self.HUD_blind = UIBox{ definition = create_UIBox_HUD_blind(), config = {...} }
G.hand_text_area = { chips = self.HUD:get_UIE_by_ID('hand_chips'), ... }
```

**Amended after a crash on hardware.** The first implementation also rebuilt
`G.HUD_blind`, and that is not survivable: its nodes carry per-frame funcs such
as `G.FUNCS.HUD_blind_reward`, which reaches into `e.children[1].config.text`
(`button_callbacks.lua:175`) and died on a box swapped out from under it. The
blind box is only *bonded* to a HUD element (`game.lua:2402`), so it is now
re-pointed at the new element rather than reconstructed — less copied code and
one fewer thing to go wrong.

The same crash showed that `create_toggle`'s callback fires far more often than
the value changes (four rebuilds in three seconds from one tap), so the rebuild
is now gated on the setting actually differing from the one the current HUD was
built for.

`set_main_menu_UI` exists for the menu; there is no `set_HUD` equivalent.

## Decision

Restate those three statements in `hud.rebuild()` and call it when a toggle
changes during a run.

This is a **wholesale copy of game code**, which `CLAUDE.md` requires be
justified here rather than done quietly.

## Why this is acceptable

- **It is small and stable.** Three constructor calls and a table of ten
  `get_UIE_by_ID` lookups. It is configuration, not logic: no game rules, no
  scoring, no state machine.
- **There is no wrapping alternative.** The code is inline in a 200-line
  function that also deals the deck, seeds the run and builds the blind. There
  is nothing to wrap that does only this.
- **The failure mode is visible and immediate.** If LocalThunk changes the HUD's
  construction, the rebuilt HUD is wrong the moment a toggle is flipped, on
  screen, rather than silently diverging.

## What we give up

If upstream changes the HUD's alignment, offset, or the set of ids in
`G.hand_text_area`, this copy will not inherit it — the standing cost of any
copy, and the reason the rule exists.

## Mitigations

- The copy is confined to `hud.rebuild()` and nowhere else.
- It is only reached from a settings change during a run; a normal run start
  still uses the game's own path entirely.
- It reads ids from the same list `hud.lua` already keeps for the
  `get_UIE_by_ID` fallback, so the two cannot drift apart.
- If the rebuild throws, it is caught and the HUD is left as it was: the toggle
  reverts to next-run behaviour rather than breaking the run.

## Alternatives rejected

- **Leave it as next-run.** Honest, and it was labelled as such, but the user
  asked for it to apply immediately and the cost above is modest.
- **Keep the node in the HUD and hide it.** Leaves the gap this task exists to
  remove: `set_wh` measures children regardless of visibility.
- **Rebuild by calling `Game:start_run` again.** Would restart the run.


## Outcome — reverted

Implemented, tested on hardware, and backed out.

Rebuilding the HUD made the toggle apply instantly, and broke the blind display
every time. Diagnostics taken immediately after a rebuild showed the box in
perfect health:

    hud: rebuilt (score=true). blind exists=true major=true vis=true off.y=0

It existed, its bond resolved, it was visible, its offset was zero -- and it did
not draw. So the damage is in contents that `blind.lua` populates imperatively
(it reaches in by id and sets `states.visible` on individual elements,
`blind.lua:124`), which a rebuilt HUD does not restore and which nothing else
re-applies.

Three fixes were attempted -- narrowing an over-broad `get_UIE_by_ID` fallback,
re-pointing the bond instead of recreating the box, and recalculating after
re-pointing. Each addressed a real defect. None was the cause.

**The judgement:** a core HUD element disappearing is a worse fault than a
setting that takes effect on the next run. The rebuild is removed and the
toggle is labelled "(next run)" again.

Reviving this needs the missing half first: a way to re-apply the blind's own UI
state after the HUD is rebuilt, most likely by driving `Blind`'s own setup
rather than reconstructing boxes underneath it. Without that, this ADR's
premise -- that the copy is small and self-contained -- does not hold.


## Outcome — resolved

The missing half turned out to be exactly what this document predicted, and it
is small.

The blind panel's display is not declarative. `blind.lua` sets it up by reaching
into the box by id from inside a delayed event (`blind.lua:132-136`):

```lua
G.HUD_blind:get_UIE_by_ID("HUD_blind_name").states.visible = true
G.HUD_blind:get_UIE_by_ID("dollars_to_be_earned").parent.parent.states.visible = true
G.HUD_blind.alignment.offset.y = 0
```

That event runs once, when the blind is set. Rebuild the HUD afterwards and
nothing re-runs it -- so `recalculate` rebuilds the box's elements from its
definition and discards the visibility that was switched on by hand. The box
comes back structurally perfect and visually empty, which is precisely what the
diagnostics reported.

`hud.lua` now re-applies those three lines after a rebuild, gated on a blind
actually being set: between blinds the panel is *supposed* to be hidden, and
forcing it visible would be a different bug.

**Why the earlier attempts missed it.** All three -- narrowing the
`get_UIE_by_ID` fallback, re-pointing the bond rather than recreating the box,
recalculating after re-pointing -- were aimed at the BOX. The evidence said the
box was fine. The state that mattered lived one level down, in elements that
nothing declarative owns, and no amount of fixing the container was going to
reach it.


## Postscript — the actual destroyer

The fix above was still not complete. Re-applying the blind's visibility made
toggling work, but the FIRST toggle in a run lost the blind permanently.

`G.GAME.blind` is itself a node inside the blind box:

```lua
{n=G.UIT.O, config={object = G.GAME.blind, draw_layer = 1}}   -- UI_definitions.lua:1232
```

and a `UIElement` takes ownership of an object node (`config.object.parent =
self`, `ui.lua:355`). So `G.HUD_blind:recalculate(false)` -- which this code was
calling to make the box re-measure against its new anchor -- tore down the
element that owns the Blind, and took the Blind with it. Nothing could restore
it afterwards because there was nothing left.

Re-pointing the bond and calling `align_to_major` is sufficient on its own. The
recalculate was never needed; it was added on the assumption that the box had to
be told to re-measure, and that assumption cost three rounds.

**The generalisable point:** in this engine an object node OWNS its object.
Rebuilding a container is never only a layout operation -- it destroys whatever
the game has parked inside it. That is the same hazard as `G.pack_cards` being
an object node in the pack UIBox, seen from the other side.


## Final outcome — rejected

Removing the `recalculate` did not fix it either. The blind still disappears on
the first toggle of a run.

So the chain has at least one more link than the one identified above. Object
nodes owning their objects is real and was worth recording, but it was not the
whole story, and five attempts is enough to say the approach is wrong rather
than the implementation.

**Decision: the hand-score toggle applies from the next run.** The label says so.

What would make this worth revisiting, in order:

1. Find what else the rebuild destroys or detaches, by logging
   `G.GAME.blind` -- its existence, `parent`, `states.visible`, and `blind_set`
   -- immediately before and after each step of `hud.rebuild`, rather than
   inspecting only the box as every attempt so far has done.
2. Consider not rebuilding at all: apply the extraction at a moment the game
   already rebuilds the HUD, or defer the toggle until the blind is not set.
3. Only then reconsider the copy this ADR proposes.

**The process lesson, which is the more useful one.** Every attempt inspected
the container and concluded the container was fine -- and it was, every time.
The evidence needed was the state of the thing that had gone missing, and I did
not gather it until several rounds in, then still reasoned forwards from a
partial picture. When a fix has failed twice for different reasons, the next
step is not a third fix.


## Resolution — the rebuild was never needed

The instant toggle now works by DETACHING THE LIVE ELEMENT: the score element
is removed from its parent's `children` array and `G.HUD:recalculate()` repacks
the pane; reinserting at the same index restores vanilla. `lua/dualscreen/hud.lua`
holds the mechanism and the full reasoning.

Reading `engine/ui.lua` properly also settled why every rebuild attempt killed
the blind: `UIElement:remove()` destroys its object node's object
(`ui.lua:1008`), and `G.GAME.blind` is an object node inside `G.HUD_blind`
(`UI_definitions.lua:1232`) — the teardown removed the Blind itself. The
follow-up path this ADR proposed (instrument `G.GAME.blind`, or avoid the
rebuild entirely) was taken: the rebuild is avoided entirely.

With no game code restated, the copy this ADR existed to justify no longer
exists. It is kept as the record of why the rebuild approach is a trap.
