import SwiftUI

/// The island's silhouette.
///
/// Flush with the top of the screen, rounded generously along the bottom, and
/// — the detail that makes it read as one piece with the hardware — *concave*
/// where it meets the top edge. Those inverted corners let the shape flare out
/// of the bezel instead of sitting on it as a rectangle, which is what makes the
/// camera housing disappear into the fill rather than sitting in a gap.
struct IslandShape: Shape {
    var cornerRadius: CGFloat
    /// How far the shape flares past its frame at the very top, and the radius
    /// of the concave fillet that gets it there.
    var topFlare: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, topFlare) }
        set {
            cornerRadius = newValue.first
            topFlare = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path.island(in: rect, cornerRadius: cornerRadius, topFlare: topFlare, closed: true)
    }
}

/// The same silhouette as an open path with no top edge, so stroking it never
/// draws a line across the screen's edge.
struct IslandOutline: Shape {
    var cornerRadius: CGFloat
    var topFlare: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerRadius, topFlare) }
        set {
            cornerRadius = newValue.first
            topFlare = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path.island(in: rect, cornerRadius: cornerRadius, topFlare: topFlare, closed: false)
    }
}

extension Path {
    fileprivate static func island(
        in rect: CGRect, cornerRadius: CGFloat, topFlare: CGFloat, closed: Bool
    ) -> Path {
        var path = Path()
        let r = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let f = max(0, min(topFlare, rect.height / 2))

        // Start out past the left edge, level with the screen top.
        path.move(to: CGPoint(x: rect.minX - f, y: rect.minY))
        // Concave fillet curving inward and down.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + f),
            control: CGPoint(x: rect.minX, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + f, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY))

        // Closing runs straight back along the screen edge; the open variant
        // stops here so nothing is stroked across the top.
        if closed { path.closeSubpath() }
        return path
    }
}
