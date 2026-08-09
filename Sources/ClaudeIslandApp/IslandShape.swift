import SwiftUI

/// How the island meets the top of its frame.
enum IslandTop: Equatable {
    /// Concave fillets flaring past the frame into the bezel. Only means
    /// anything against a real cutout, which is the only place it is used.
    case flare
    /// Convex corners matching the bottom pair. The fallback pill floats below
    /// the menu bar with no bezel to blend into, so a flare there would hang in
    /// mid-air and a square corner reads as a clipped rectangle.
    case rounded
}

/// The profile every corner on the island is cut from.
///
/// A superellipse quadrant, not a circular arc. Curvature ramps up from zero
/// where the corner meets the straight edge instead of starting abruptly, which
/// is the difference between a corner that reads as machined and one that reads
/// as drawn. Apple's cutout is the former and the island has to sit beside it.
enum IslandCorner {
    /// The hardware's own corner. Every tier uses it: the cutout grows, but its
    /// corners stay the cutout's corners, which is how a physical object
    /// behaves and a revealing panel does not.
    static let radius: CGFloat = 12

    /// Two would be a circle; four is the flatter shoulder the hardware has.
    static let exponent: CGFloat = 4

    /// How far a corner of radius `r` reaches along each edge. A circular
    /// corner reaches exactly `r`, so this is the whole visible difference:
    /// the curve passes 0.344r from the corner point where an arc passes
    /// 0.414r — closer to the corner at the tip, gentler into the edges.
    static let spanRatio: CGFloat = 1.528

    /// Straight segments per corner. The curve is flattest exactly where
    /// uniform sampling is sparsest — near the joins, where it is nearly a
    /// straight line — so twenty holds the polyline inside a tenth of a point
    /// of the true curve at the spans the island uses.
    static let segments = 20

    /// What a corner of this radius actually consumes along an edge. It is the
    /// span, never the radius, that has to fit in the space available.
    static func span(_ radius: CGFloat) -> CGFloat { max(0, radius) * spanRatio }
}

/// The island's silhouette.
///
/// Flush with the top of the screen, rounded along the bottom, and — the detail
/// that makes it read as one piece with the hardware — *concave* where it meets
/// the top edge. Those inverted corners let the shape flare out of the bezel
/// instead of sitting on it as a rectangle, which is what makes the camera
/// housing disappear into the fill rather than sitting in a gap.
struct IslandShape: Shape {
    var cornerRadius: CGFloat
    /// How far the shape flares past its frame at the very top, and the extent
    /// of the concave fillet that gets it there.
    var topFlare: CGFloat
    var top: IslandTop = .flare

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, topFlare) }
        set {
            cornerRadius = newValue.first
            topFlare = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path.island(
            in: rect, cornerRadius: cornerRadius, topFlare: topFlare, top: top, closed: true)
    }
}

/// The same silhouette as an open path with no top edge, so stroking it never
/// draws a line across the screen's edge. A rounded top has no screen edge to
/// avoid, so that variant closes like any other shape.
struct IslandOutline: Shape {
    var cornerRadius: CGFloat
    var topFlare: CGFloat
    var top: IslandTop = .flare

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, topFlare) }
        set {
            cornerRadius = newValue.first
            topFlare = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path.island(
            in: rect, cornerRadius: cornerRadius, topFlare: topFlare, top: top, closed: false)
    }
}

extension Path {
    fileprivate static func island(
        in rect: CGRect, cornerRadius: CGFloat, topFlare: CGFloat, top: IslandTop, closed: Bool
    ) -> Path {
        var path = Path()

        // Spans, not radii, are what have to fit: the bottom pair shares the
        // width between them and takes whatever height the top treatment leaves.
        let wanted = IslandCorner.span(cornerRadius)
        let topSpan =
            switch top {
            case .flare: max(0, min(topFlare, rect.height / 2))
            case .rounded: min(wanted, rect.width / 2, rect.height / 2)
            }
        let bottom = max(0, min(wanted, rect.width / 2, rect.height - topSpan))

        switch top {
        case .flare:
            // Start out past the left edge, level with the screen top.
            path.move(to: CGPoint(x: rect.minX - topSpan, y: rect.minY))
            path.addSmoothCorner(
                at: CGPoint(x: rect.minX, y: rect.minY),
                from: CGVector(dx: -1, dy: 0), to: CGVector(dx: 0, dy: 1), span: topSpan)
        case .rounded:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + topSpan))
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addSmoothCorner(
            at: CGPoint(x: rect.minX, y: rect.maxY),
            from: CGVector(dx: 0, dy: -1), to: CGVector(dx: 1, dy: 0), span: bottom)

        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addSmoothCorner(
            at: CGPoint(x: rect.maxX, y: rect.maxY),
            from: CGVector(dx: -1, dy: 0), to: CGVector(dx: 0, dy: -1), span: bottom)

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topSpan))

        switch top {
        case .flare:
            path.addSmoothCorner(
                at: CGPoint(x: rect.maxX, y: rect.minY),
                from: CGVector(dx: 0, dy: 1), to: CGVector(dx: 1, dy: 0), span: topSpan)
            // Closing runs straight back along the screen edge; the open variant
            // stops here so nothing is stroked across the top.
            if closed { path.closeSubpath() }
        case .rounded:
            // Nothing to leave open: this shape never touches the screen edge.
            path.addSmoothCorner(
                at: CGPoint(x: rect.maxX, y: rect.minY),
                from: CGVector(dx: 0, dy: 1), to: CGVector(dx: -1, dy: 0), span: topSpan)
            path.addLine(to: CGPoint(x: rect.minX + topSpan, y: rect.minY))
            path.addSmoothCorner(
                at: CGPoint(x: rect.minX, y: rect.minY),
                from: CGVector(dx: 1, dy: 0), to: CGVector(dx: 0, dy: 1), span: topSpan)
            path.closeSubpath()
        }

        return path
    }

    /// Turns the corner at `corner`, arriving along `from` and leaving along
    /// `to` — both unit vectors pointing away from the corner, down the edges
    /// that meet there. The curve runs `span` along each.
    ///
    /// The caller must already be at `corner + from * span`. Concave and convex
    /// corners are the same call: `from` and `to` decide which, and both get the
    /// same profile, so the silhouette speaks one language end to end.
    fileprivate mutating func addSmoothCorner(
        at corner: CGPoint, from: CGVector, to: CGVector, span: CGFloat
    ) {
        guard span > 0 else {
            addLine(to: corner)
            return
        }
        let e = 2 / IslandCorner.exponent
        for step in 1...IslandCorner.segments {
            let t = CGFloat(step) / CGFloat(IslandCorner.segments) * (.pi / 2)
            let along = span * (1 - pow(cos(t), e))
            let away = span * (1 - pow(sin(t), e))
            addLine(
                to: CGPoint(
                    x: corner.x + to.dx * along + from.dx * away,
                    y: corner.y + to.dy * along + from.dy * away))
        }
    }
}
