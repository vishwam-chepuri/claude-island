# Pulsing attention border

**Date:** 2026-08-07

## Problem

A permission prompt is the one state where Claude is fully blocked on the human,
and the HUD's only escalation for it is a flat 1.5pt orange stroke plus a
breathing `hand.raised.fill` glyph. There is no sound, no dock bounce and no
system notification, so a prompt on a second display or behind a fullscreen app
is easy to miss entirely.

Make the border pulse: the stroke cycles orange to yellow and back while an
outer glow swells and fades with it, so the island reads as lit from within and
catches peripheral vision.

## Scope

Permission prompts only — `SessionState.awaitingPermission`, which is exactly
`IslandMode.alert`.

Deliberately excluded:

- The idle nudge, `idle(waitingOnUser: true)`. It stays in plain compact mode
  with no border, as today.
- `done`. It is the most common resting state and a lit border would be on
  almost always, which would train the eye to ignore it.

## Approach

A new `PulsingOutline: NSViewRepresentable` in `CoreAnimationViews.swift`,
alongside its two siblings `PulsingGlyph` and `StatusMark` and built the same
way: one `CAShapeLayer`, animations handed to the render server once, nothing
per frame in the app process.

This is a constraint, not a preference. The file header of
`CoreAnimationViews.swift` documents the measurement: a SwiftUI
`withAnimation(...repeatForever())` re-runs the whole view graph every frame and
cost 4.5% CPU for a single pulsing glyph, against 0.27% with the pulse removed.
Both alternatives — animating the existing SwiftUI stroke, or driving the colour
from a `TimelineView(.animation)` — land on that path and are rejected.

## Geometry and mounting

The layer's path comes from
`IslandOutline(cornerRadius:topFlare:).path(in: bounds).cgPath`. The existing
shape stays the single source of truth; no path maths is duplicated.

Mount point is the one place the obvious plan is wrong. Today's stroke is an
`.overlay` **inside** the ZStack at `IslandView.swift:57-60`, and that ZStack is
clipped by `.clipShape(IslandShape(...))` at line 71 — so the outer half of the
current 1.5pt stroke is already clipped away, and an outer glow mounted there
would be clipped entirely.

`PulsingOutline` therefore attaches **after** the clip, as an overlay on
`islandShape`, shown only when `model.mode == .alert`. The panel
(`NotchGeometryResolver.panelWidth/Height`) is substantially larger than the
shape, so the bloom has room to spread without being cut off.

It fades in with `.transition(.opacity)`. Without that, the CA path snaps to its
final geometry while the SwiftUI fill springs into the alert layout, and the
mismatch is visible for the length of the morph.

## Animation

Three `CABasicAnimation`s on one layer. All share `autoreverses = true`,
`repeatCount = .infinity`, `timingFunction = easeInEaseOut`, and an identical
`duration`, so they stay in phase by construction rather than by tuning.

| Key path        | From                    | To                      |
| --------------- | ----------------------- | ----------------------- |
| `strokeColor`   | `#FF9429`               | `#FFDB47`               |
| `shadowColor`   | `#FF9429`               | `#FFDB47`               |
| `shadowOpacity` | 0.25                    | 0.75                    |
| `shadowRadius`  | 5                       | 11                      |

`lineWidth` stays constant at 1.5. `fillColor` is nil.

**The shadow's geometry is the stroke, not the silhouette.** An explicit
`shadowPath` is *filled* to derive the shadow, so setting it to the outline
directly paints a blurred orange island over the fill and its content — at
`shadowOpacity` 0.75 the card is unreadable. It has to be the outline *stroked*
first:

```swift
outline.copy(strokingWithWidth: 1.5, lineCap: .butt, lineJoin: .round, miterLimit: 10)
```

That is a closed ribbon whose fill is exactly the 1.5pt line, so the halo hugs
the edge — and it is still explicit, so Core Animation never rasterises the
layer to work the shape out for itself.

**Colours.** The orange end is the existing `IslandPalette.alert`,
`Color(red: 1.0, green: 0.58, blue: 0.16)`. The yellow end is a new constant
`IslandPalette.alertPulse`, `Color(red: 1.0, green: 0.859, blue: 0.278)`,
declared next to `alert` in the `IslandPalette` enum in `IslandView.swift`.
The green channel travels 148 to 219 in 8-bit terms — far enough to read as a
shift, close enough that it reads as one warm colour breathing rather than two
colours alternating.

**Period.** 0.85s per half-cycle, 1.7s round trip, matching the existing
`PulsingGlyph` breath in `AlertContent`. The border and the hand glyph therefore
pulse together instead of beating against each other. This is a single constant
if it needs retuning; changing it means retuning the glyph to match.

**Resize.** The path is rebuilt in an `NSView.layout()` override, not in
`updateNSView` — the distinction `LiveRail` already documents in this file:
SwiftUI resizes the view without necessarily calling `updateNSView`, so a path
built there is drawn against stale bounds. The alert pill *does* resize while
mounted, because its width follows the elapsed counter as it rolls 9s → 10s →
1:00. `updateNSView` only stores `cornerRadius`/`topFlare` and sets
`needsLayout`.

Animations are re-added only when absent, using the
`guard layer.animation(forKey:) == nil` idiom already established in
`PulsingGlyph`, so a width change does not restart the cycle mid-phase.

**Hit testing.** The view covers the whole alert pill and sits above the tap
target, so it must be transparent to clicks or it swallows the one that pins the
card open. `.allowsHitTesting(false)` on the SwiftUI side does not reach an
AppKit subview's own hit test; `OutlineView` overrides `hitTest(_:)` to return
nil instead.

## Reduce motion

Checked via `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, as in
both sibling views. When set: no animations are added, the stroke is the
midpoint amber `#FFB438`, `shadowOpacity` is a static 0.5 and `shadowRadius` a
static 8. Still clearly lit and distinct from every other state — just not
moving.

## Idle CPU

`PulsingOutline` is mounted only while `mode == .alert`, so it is torn down with
the state and nothing survives to animate a quiet HUD. This preserves the
existing contract: no session, no timer, no redraws.

## Cleanup

`strokeColor` and `strokeWidth` in `IslandView.swift:81-89` lose their `.alert`
branch and keep only the debug-tint case, since `PulsingOutline` now owns that
edge. Leaving both in place would double-stroke the outline.

## Verification

`SelfTest` operates at view-model level and cannot inspect `CALayer` state, so
the testable seam is a model-level predicate:

- Add `var wantsAttentionBorder: Bool { mode == .alert }` to `IslandViewModel`.
- Assert it is true for a session in `awaitingPermission`.
- Assert it is false for `idle(waitingOnUser: true)`, `done`, `thinking`, and a
  dormant HUD.

The existing check "your turn (permission) rests as a single line" already
guards the alert tier's height and must keep passing — the border must not
change the shape's size.

Manual confirmation: trigger a permission prompt, confirm the border cycles and
the glow is visible outside the shape's edge rather than clipped, then enable
Reduce Motion in System Settings and confirm it settles to static amber.

A prompt can be raised without waiting for a real one, against a running HUD:

```bash
printf '%s' '{"session_id":"x","hook_event_name":"SessionStart","cwd":"/tmp/demo"}' \
  | ./.build/debug/claude-island-notify
printf '%s' '{"session_id":"x","hook_event_name":"PermissionRequest","cwd":"/tmp/demo",
  "tool_name":"Write","tool_input":{"file_path":"/tmp/x.swift"}}' \
  | ./.build/debug/claude-island-notify
```

`SessionStart` first is not optional — a `PermissionRequest` for a session the
store has never seen is dropped, and the HUD simply goes on showing whatever it
was showing. Note also that `SocketServer.start` unlinks before it binds, so a
second HUD silently takes the socket from the first.

Measured on the built-in display: the app process holds 0.0–0.1% CPU with the
pulse running, which is the contract this construction exists for. The
render-server cost of animating `shadowRadius` was not separable from background
noise. If it ever needs cutting, holding the radius constant and animating only
`shadowOpacity` costs one line and keeps most of the swell.
