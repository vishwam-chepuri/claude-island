import AppKit
import ClaudeIslandCore
import SwiftUI

// Repeating animations run through Core Animation rather than SwiftUI.
//
// A SwiftUI `withAnimation(....repeatForever())` re-runs the whole view graph
// every frame: profiling showed `CA::Transaction::flush` -> `NSHostingView.layout()`
// -> full `ViewGraph` render at the display's 120 Hz, costing 4.5% CPU for a
// single pulsing glyph (0.27% with the pulse removed). A `CAAnimation` is handed
// to the render server once and costs the app process nothing per frame.
//
// Both continuously-animating elements disappear with their state, so nothing
// keeps animating once a session goes quiet.

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

/// A slim indeterminate rail: a bright head sweeping across a dim track.
///
/// The expanded card's body is otherwise text and finished durations, and a
/// finished duration is frozen by definition — so a session working right now
/// and one that stopped an hour ago rendered identically, and both read as a
/// hung UI. This is the one element in the card body that can only mean "now".
///
/// Same construction as its siblings: the sweep is a CAAnimation handed to the
/// render server, never a SwiftUI `repeatForever`.
struct LiveRail: NSViewRepresentable {
    let base: NSColor
    let bright: NSColor

    static let height: CGFloat = 2.5

    /// Lays its own sublayers out in `layout()`. `updateNSView` cannot do it —
    /// SwiftUI has not necessarily sized the view by the time it runs, and a
    /// sweep computed against a zero width never moves.
    final class RailView: NSView {
        let track = CALayer()
        let head = CAGradientLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            head.startPoint = CGPoint(x: 0, y: 0.5)
            head.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(track)
            layer?.addSublayer(head)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            let h = bounds.height
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.frame = bounds
            track.cornerRadius = h / 2
            head.bounds = CGRect(
                x: 0, y: 0, width: max(24, bounds.width * 0.32), height: h)
            head.cornerRadius = h / 2
            head.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            applySweep()
        }

        func applySweep() {
            let key = "island.sweep"
            head.removeAnimation(forKey: key)
            guard bounds.width > 0 else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -head.bounds.width / 2
            sweep.toValue = bounds.width + head.bounds.width / 2
            sweep.duration = 1.5
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            head.add(sweep, forKey: key)
        }
    }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> RailView {
        RailView(frame: .zero)
    }

    func updateNSView(_ view: RailView, context: NSViewRepresentableContext<Self>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.track.backgroundColor = base.withAlphaComponent(0.14).cgColor
        view.head.colors = [
            base.withAlphaComponent(0).cgColor, bright.cgColor,
            base.withAlphaComponent(0).cgColor,
        ]
        CATransaction.commit()
        view.needsLayout = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: RailView,
        context: NSViewRepresentableContext<Self>
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: Self.height)
    }
}

/// The status mark: a ring that spins while working, completes and takes a
/// checkmark when the turn lands on you, and rests solid when done.
///
/// Modelled on the reference design's three states. Built from CAShapeLayers
/// with CA animations for the same reason as the other two: a SwiftUI
/// `repeatForever` re-runs the whole view graph every frame.
struct StatusMark: NSViewRepresentable {
    let state: SessionState

    static let size: CGFloat = 16
    private static let lineWidth: CGFloat = 1.8

    private enum Shape { case spinning, complete, resting }

    private var shape: Shape {
        switch state {
        case .running, .thinking, .prompting, .compacting: .spinning
        case .awaitingPermission, .idle(waitingOnUser: true): .complete
        case .done, .error, .idle: .resting
        }
    }

    private var tint: NSColor { NSColor(IslandPalette.accent(for: state)) }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSView {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.lineCap = .round
        let mark = CAShapeLayer()
        mark.fillColor = nil
        mark.lineCap = .round
        mark.lineJoin = .round
        view.layer?.addSublayer(ring)
        view.layer?.addSublayer(mark)
        return view
    }

    func updateNSView(_ view: NSView, context: NSViewRepresentableContext<Self>) {
        guard let layers = view.layer?.sublayers, layers.count == 2,
            let ring = layers[0] as? CAShapeLayer, let mark = layers[1] as? CAShapeLayer
        else { return }

        let box = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        let inset = Self.lineWidth
        let circle = CGPath(
            ellipseIn: box.insetBy(dx: inset, dy: inset), transform: nil)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = box
        mark.frame = box
        ring.path = circle
        ring.lineWidth = Self.lineWidth
        ring.strokeColor = tint.cgColor
        mark.lineWidth = Self.lineWidth
        mark.strokeColor = tint.cgColor

        switch shape {
        case .spinning:
            // A gap in the stroke, rotated — reads as motion without redrawing.
            ring.strokeStart = 0
            ring.strokeEnd = 0.3
            mark.path = nil
        case .complete, .resting:
            ring.strokeStart = 0
            ring.strokeEnd = 1
            mark.path = checkmark(in: box)
        }
        ring.opacity = 1
        CATransaction.commit()

        let spinKey = "island.spin"
        let breatheKey = "island.breathe"
        ring.removeAnimation(forKey: spinKey)
        ring.removeAnimation(forKey: breatheKey)
        mark.removeAnimation(forKey: breatheKey)
        guard !reduceMotion else { return }

        switch shape {
        case .spinning:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.4
            spin.repeatCount = .infinity
            ring.add(spin, forKey: spinKey)
        case .complete:
            // Your turn: a slow breath, so it reads as waiting rather than busy.
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1.0
            breathe.toValue = 0.45
            breathe.duration = 0.95
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ring.add(breathe, forKey: breatheKey)
            mark.add(breathe, forKey: breatheKey)
        case .resting:
            break
        }
    }

    private func checkmark(in box: CGRect) -> CGPath {
        let p = CGMutablePath()
        let w = box.width
        // Coordinates scaled from the reference's 20pt viewBox.
        p.move(to: CGPoint(x: w * 0.31, y: w * 0.51))
        p.addLine(to: CGPoint(x: w * 0.44, y: w * 0.36))
        p.addLine(to: CGPoint(x: w * 0.70, y: w * 0.64))
        return p
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSView, context: NSViewRepresentableContext<Self>
    ) -> CGSize? {
        CGSize(width: Self.size, height: Self.size)
    }
}
