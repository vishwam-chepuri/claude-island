import AppKit
import SwiftUI

// Repeating animations run through Core Animation rather than SwiftUI.
//
// A SwiftUI `withAnimation(....repeatForever())` re-runs the whole view graph
// every frame: profiling showed `CA::Transaction::flush` -> `NSHostingView.layout()`
// -> full `ViewGraph` render at the display's 120 Hz, costing 4.5% CPU for a
// single pulsing glyph (0.27% with the pulse removed). A `CAAnimation` is handed
// to the render server once and costs the app process nothing per frame.
//
// These are the only two continuously-animating elements, and both disappear
// with their state, so nothing keeps animating once a session goes quiet.

/// A glyph whose opacity breathes, animated on the render server.
struct PulsingGlyph: NSViewRepresentable {
    let symbolName: String
    let color: NSColor
    let pointSize: CGFloat
    let animating: Bool

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: NSViewRepresentableContext<Self>) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        view.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        view.contentTintColor = color

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let key = "island.pulse"
        guard animating, !reduceMotion else {
            view.layer?.removeAnimation(forKey: key)
            view.layer?.opacity = 1
            return
        }
        guard view.layer?.animation(forKey: key) == nil else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.42
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        // easeInEaseOut on a CA keyframe is the render server's own curve, not a
        // SwiftUI duration animation — the "springs only" rule is about the
        // shape morph, which stays a SwiftUI spring.
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(pulse, forKey: key)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSImageView,
        context: NSViewRepresentableContext<Self>
    ) -> CGSize? {
        CGSize(width: pointSize + 3, height: pointSize + 3)
    }
}

/// Three dots that rise and fall in sequence, animated on the render server.
struct BouncingDots: NSViewRepresentable {
    let color: NSColor
    let animating: Bool

    private static let dotSize: CGFloat = 4
    private static let spacing: CGFloat = 3
    private static let count = 3

    static var intrinsicSize: CGSize {
        CGSize(
            width: CGFloat(count) * dotSize + CGFloat(count - 1) * spacing,
            height: dotSize + 4)
    }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        for _ in 0..<Self.count {
            let dot = CALayer()
            dot.cornerRadius = Self.dotSize / 2
            view.layer?.addSublayer(dot)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: NSViewRepresentableContext<Self>) {
        guard let layers = view.layer?.sublayers, layers.count == Self.count else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let bounds = view.bounds
        let key = "island.bounce"

        // Layout happens here rather than in a layout pass: with three fixed
        // sublayers it is cheaper than a subview hierarchy, and it only runs
        // when SwiftUI updates this view, not per frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in layers.enumerated() {
            let x = CGFloat(index) * (Self.dotSize + Self.spacing)
            dot.frame = CGRect(
                x: x, y: (bounds.height - Self.dotSize) / 2,
                width: Self.dotSize, height: Self.dotSize)
            dot.backgroundColor = color.cgColor
        }
        CATransaction.commit()

        for (index, dot) in layers.enumerated() {
            guard animating, !reduceMotion else {
                dot.removeAnimation(forKey: key)
                dot.opacity = 1
                continue
            }
            guard dot.animation(forKey: key) == nil else { continue }

            let bounce = CABasicAnimation(keyPath: "transform.scale")
            bounce.fromValue = 0.55
            bounce.toValue = 1.15
            bounce.duration = 0.42
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Stagger by shifting each dot's start point within the cycle.
            bounce.timeOffset = Double(index) * 0.14
            dot.add(bounce, forKey: key)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSView,
        context: NSViewRepresentableContext<Self>
    ) -> CGSize? {
        Self.intrinsicSize
    }
}
