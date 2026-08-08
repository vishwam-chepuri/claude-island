# Pulses that travel

**Date:** 2026-08-09

Supersedes the animation described in `2026-08-07-attention-border-design.md`.
That spec's construction survives — the Core Animation mounting, the y-flip, the
stroked shadow path, the hit-test override — but its *motion* does not. Where it
breathed the whole edge at once, this one sends a pulse outward from the centre.

## Problem

The HUD has one escalation and it is permanent: while a permission prompt is up,
the edge is lit. Nothing marks the other moment worth looking up for — a session
finishing. `done` is reported only by a word on a pill you have to already be
looking at.

Two events deserve the edge, and they are not the same kind of event. A prompt is
a standing condition: it stays true until you answer, so its signal must stay
visible. A completion is an instant: it happens once and is then simply history,
so its signal must not linger.

## The two treatments

| State                        | Colour        | Motion                     |
| ---------------------------- | ------------- | -------------------------- |
| `awaitingPermission`         | yellow-orange | grow and fill, repeating   |
| `done` (on entry)            | blue          | grow and fill, once        |
| `idle(waitingOnUser: true)`  | —             | none                       |
| `error`                      | —             | none                       |
| everything else              | —             | none                       |

The idle nudge stays excluded, as before. It is a nudge, not a block: Claude is
not stopped waiting on an answer, you simply have not typed yet. `error` stays
excluded because it auto-decays back to thinking after `Timings.errorDecay` — a
pulse announcing a state that removes itself is noise.

## The motion

`IslandOutline` is an open path: top-left flare, down the left side, along the
bottom, up the right, ending at the top-right flare. The shape is symmetric, so
its **arc-length midpoint is exactly the bottom-centre**. "Grow outward from the
centre" is therefore not a special effect but two properties of one layer:

| Key path      | From | To  |
| ------------- | ---- | --- |
| `strokeStart` | 0.5  | 0   |
| `strokeEnd`   | 0.5  | 1   |

Both on the same duration and curve, so the two halves stay mirrored by
construction rather than by tuning.

A gradient-masked sweep would give a softer falloff at the growing edge, and is
rejected: it needs a `CAGradientLayer` plus a mask re-rendered every frame, which
is the per-frame cost this file exists to avoid. At the speed the segment
travels, the hard edge is not perceptible.

### Two layers

The halo cannot ride on the growing segment. Its geometry is an explicit
`shadowPath` covering the whole stroked ribbon, so a glow would appear around
parts of the border that are not lit yet.

- **base** — the full outline at the dim resting colour. Static. Carries the
  halo. This is what keeps the edge from ever going fully dark.
- **sweep** — the bright growing segment, drawn over it. Animated. No shadow.

This **drops the breathing halo** the previous spec specified — `shadowOpacity`
0.25↔0.75 and `shadowRadius` 5↔11 animated in step with the stroke. The halo is
now steady and the motion lives entirely in the sweep. Two things travelling at
once would compete, and the steady version is also strictly cheaper: an animated
`shadowRadius` re-blurs on the render server every frame, a fixed one is
composited from cache.

Yellow mounts both. Blue mounts only the sweep, runs it once, and unmounts, so a
finished session leaves nothing behind to look at.

### Yellow, repeating

One cycle is 1.7s, matching the `PulsingGlyph` breath in `AlertContent` so the
edge and the raised hand do not beat against each other:

- 0.00–0.85s — the sweep grows from centre to both flares
- 0.85–1.70s — the sweep fades out; the base stays lit underneath

The trough is a dim lit border, never nothing. A prompt on a second display has
to survive a glance at any instant, which is the whole reason this feature
exists.

### Blue, once

Total window 1.8s: 0.6s for the sweep to reach the flares, 0.6s holding, 0.6s
fading out. Then the layer is torn down.

## Trigger semantics

Blue fires on the **transition into `done`**, not on the state. This is new: the
view model exposes state, not edges. `apply(_ snapshot:)` gains a per-session
record of the previous state and emits a one-shot completion token when a
session crosses into `done`.

Firing on the state instead would re-pulse on every snapshot, on HUD launch with
an already-finished session, and every time the switcher landed on one.

### Takeover

A session that finishes while a *different* session is displayed takes the
display over for the length of the pulse, then hands it back — the way a
permission prompt takes over, except temporary. Without this the border would
pulse while the label named a session that had not finished.

It is suppressed in four cases:

1. **A permission prompt is up.** A prompt blocks Claude entirely; a completion
   elsewhere must never displace it.
2. **You are hovering, or the card is pinned open.** You are reading a session's
   detail; yanking it mid-read loses your place.
3. **The finished session is already displayed.** Nothing to switch to — it
   pulses in place.
4. **A takeover is already running.** Only the first of a burst takes the
   display; later completions pulse only if they happen to be shown.

Handing the display back needs a one-shot timer. This is consistent with the
idle-CPU contract: it is self-cancelling, and nothing survives it.

## Colours

The yellow pair is already in the palette from the previous spec:
`IslandPalette.alert` `#FF9429` at the base, `alertPulse` `#FFDB47` for the
sweep.

Blue needs a new constant: `IslandPalette.completionPulse`, `#59ADFF`.

`IslandPalette.running` is also blue, `#6BC7FF`, but the two never meet. A
running session draws no border — `strokeColor` is `.clear` outside the debug
tint, in every tier — so the running blue only ever appears as the status mark
and the status word. Blue on the *edge* is unambiguous, and can only mean
finished.

This is worth stating because it is a standing constraint, not an accident: the
edge is reserved for the two events that are worth looking up for. Giving it to
`running` as well would put the border on during the longest-lived state there
is, and an edge that is lit most of the time is one the eye stops reading.

## Reduce Motion

Checked via `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, as
everywhere else in `CoreAnimationViews.swift`.

- **Yellow** settles to the static amber `#FFB438` border already specified.
- **Blue** cannot travel, so it becomes a static blue edge that fades out over
  the same 1.8s window. The completion still reads; nothing moves.

The takeover still happens under Reduce Motion — it is a display change, not an
animation.

## Idle CPU

Both layers are mounted only while their state holds, so nothing survives to
animate a quiet HUD. The blue layer additionally tears itself down at the end of
its one-shot window rather than resting invisible.

## What changes in existing code

- `PulsingOutline` is reworked into the two-layer construction. Its flip
  (`layerPath`), `hitTest` override, `layout()`-not-`updateNSView` rule and
  stroked `shadowPath` all survive unchanged.
- `wantsAttentionBorder: Bool` becomes a richer value — attention, completion,
  or none — and its five self-test checks extend to match.
- `IslandViewModel.apply(_:)` gains previous-state tracking and the takeover.
- `displaySession` gains the takeover as a second override, below the existing
  permission-prompt override in priority.

## Verification

`SelfTest` works at view-model level and cannot inspect `CALayer` state, so the
seam stays a model-level predicate. Extending the existing checks:

- `done` on entry requests the completion pulse; a second snapshot with the same
  session still `done` does not.
- `awaitingPermission` requests the attention pulse.
- The idle nudge, `error`, `thinking` and a dormant HUD request nothing.
- Each of the four suppression rules, asserted independently.
- The takeover returns the display to the previously shown session when it ends.

The geometry check from the previous spec — that the outline's flares meet the
screen edge rather than hanging off the bottom — must keep passing, as must
"your turn (permission) rests as a single line". Neither pulse may change the
shape's size.

### Carried over, still unverified

Two items from the previous spec were never confirmed and this work touches both
areas, so they are folded in here:

- **Reduce Motion has never been observed.** The path is written but has not been
  seen to render. Confirming it means toggling the real system setting.
- **The hit-test override has never been exercised.** `PulsingOutline` covers the
  whole alert pill and returns nil from `hitTest(_:)` so it cannot swallow the
  click that pins the card open. That reasoning is sound but untested — the
  self-test's click check is skipped on this machine (another HUD sits at window
  layer 1000) and exercises compact mode regardless, not alert mode with the
  overlay mounted.
