# The island's corners, and its fill

## The problem

Two things break the illusion that the island *is* the camera cutout.

**The corners are drawn, not machined.** Every corner in `Path.island` is a
quadratic Bézier whose control point sits on the corner itself — a rough
circular arc. Apple's cutout has continuous corners: curvature ramps up from
zero at the join with the straight edge instead of starting abruptly. A circular
corner beside a continuous one reads as approximately right, which is worse than
reading as different.

The radii compound it. Each tier picks its own — dormant 12 (16 without a
notch), compact 18, peek 26, expanded 30 — so the shape gets rounder as it
grows. Physical objects do not. A cutout that changes curvature while it opens
reads as a panel doing a reveal animation.

**The fill is not black.** `islandFill` is a gradient from `Color(white: 0.055)`
to black. The README says "Pure `#000` is deliberate — it makes the island read
as the physical cutout", which has not been true for some time. Against the real
notch that 5.5% lift is a visible seam.

## The design

### One profile

Every corner becomes a superellipse quadrant. With the corner point `C`, unit
vectors `â` and `b̂` along the two edges leaving it, and span `s`:

```
p(θ) = C + â·s(1 − cos^(2/n) θ) + b̂·s(1 − sin^(2/n) θ),  θ ∈ [0, π/2]
```

with `n = 4` and `s = 1.528 · r`. Both constants are named and sit together, so
tuning the profile is a two-line edit.

That span multiplier is Apple's: a continuous corner of radius `r` reaches
`1.528r` along each edge, against `r` for a circular one. The curve passes
`0.344r` from the corner point on the diagonal where a circular arc passes
`0.414r` — closer to the corner at the tip, gentler into the edges. That is the
whole difference, and it is the difference between machined and drawn.

The concave top flare uses the same formula with `â` pointing outward, so the
silhouette speaks one language end to end. `topFlare` keeps its current meaning
— how far the shape reaches past its frame — so the overhang stays 11/14pt and
`interactiveScreenRect`, which adds `topFlare` to the hit region, needs no
change. Only the curve between those endpoints differs.

Each corner is emitted as cubic segments by one helper. `IslandShape`,
`IslandOutline`, the clip shape, the hit shape and `PulsingOutline`'s CALayer
path all already funnel through `Path.island`, so they inherit it.

### One radius

`notchCornerRadius = 12`, returned by `IslandViewModel.cornerRadius` for every
mode. The cutout grows; its corners stay the cutout's corners.

Twelve continuous spans ~18pt per edge, so the compact band lands close to
today's `r = 18` circular in extent — it will not read as suddenly boxy, only as
differently shaped.

**Clamping.** A span cannot exceed the edge available to it. Where the top
flares: `s = min(1.528r, width/2, height − flare)`. Where the top is rounded
instead: `s = min(1.528r, width/2, height/2)`. The tight case is the compact
band — 30 to 32pt tall with an 11pt flare — which leaves 1 to 3pt of straight
side edge. Valid, and intentionally so: that band is nearly all curve today too.

### The notchless pill's top edge

A flare only makes sense where the shape meets the screen edge. On a display
with no notch the pill floats 6pt *below* the menu bar, so today it has square
top corners, and in compact/peek/expanded it hangs concave flares in mid-air
against nothing.

The top treatment switches on `hasNotch`, not on mode: flare into the bezel when
there is a real cutout, otherwise the same continuous corners on top as on the
bottom. The fallback then reads as a notch-shaped pill rather than a clipped
rectangle. On a 30pt-tall pill the clamp takes the span to `height/2`, making it
a stadium — which is what a floating pill should be.

This is a non-animating flag on the shape. Which display the panel is on changes
by re-layout, never mid-morph, so it does not belong in `animatableData`.

### Pitch black

`islandFill` becomes solid `Color.black`. The debug tint is untouched: it exists
precisely because pure black hides the edges being worked on, and it keeps its
gradient. The README's claim becomes true.

## What this touches

- `IslandShape.swift` — `Path.island` gains the superellipse corner helper and
  the top-style flag; the two `Shape`s pass it through.
- `IslandViewModel.swift` — `cornerRadius` collapses to one constant.
- `DesignSystem.swift` — `islandFill` becomes a solid colour.
- `IslandView.swift` — constructs both shapes; passes the top style.
- `CoreAnimationViews.swift` — `PulsingOutline.layerPath` builds from
  `IslandOutline`, so it inherits the profile but must pass the top style too.

## Verifying it

`swift build`, then `swift run ClaudeIslandTests`, then the in-app self-test.
`outlineGeometryChecks` still holds: the path opens at the left flare's tip,
which is still the one point outside the frame and level with the screen edge.

Then eyeball it, which is the part that actually decides this. With the debug
tint on and `force-mode` pinned, walk compact → peek → expanded and watch the
corners hold their curvature through the morph. Then tint off, dormant, against
the real cutout: the drawn corner and the hardware corner should be
indistinguishable at arm's length. If they are not, `notchCornerRadius` and the
two profile constants are where to tune, and nothing else moves.
