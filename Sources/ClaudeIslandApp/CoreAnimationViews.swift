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

/// The permission prompt's lit edge, and a finished session's one-shot pulse.
///
/// Both are a bright band that grows out from the bottom centre to the two top
/// flares rather than a uniform glow switching on — the eye follows the travel
/// from where the island meets the screen edge up toward the corners, instead
/// of an edge that just changes brightness in place.
///
/// A prompt is the one state where Claude is fully blocked on the human, and
/// nothing else escalates it — no sound, no dock bounce, no system notification.
/// On a second display or behind a full-screen app, a flat 1.5pt stroke is easy
/// to miss entirely.
///
/// Same construction as its siblings, for the same reason: pulsing the existing
/// SwiftUI stroke, or driving its colour from a `TimelineView(.animation)`, both
/// land on the view-graph-per-frame path this file exists to avoid.
struct PulsingOutline: NSViewRepresentable {
    let pulse: BorderPulse
    var cornerRadius: CGFloat
    var topFlare: CGFloat
    var top: IslandTop = .flare

    /// One yellow cycle. Matches the `PulsingGlyph` breath in `AlertContent` so
    /// the edge and the raised hand do not beat against each other.
    static let attentionCycle: CFTimeInterval = 1.7
    fileprivate static let lineWidth: CGFloat = 1.1

    /// Where the edge fades out. Clear at both extremes, solid across the middle
    /// — so the line is at full strength along the bottom, where the pulse is
    /// born, and has thinned to nothing by the time it reaches either flare.
    fileprivate static let taperStops: [NSNumber] = [0, 0.12, 0.88, 1]

    /// How far past the shape the halo reaches. The taper mask has to clear it,
    /// or the glow gets a hard rectangular edge the line itself does not have.
    fileprivate static let haloReach: CGFloat = 22

    final class OutlineView: NSView {
        /// The full outline at its resting colour. Static, and the only layer
        /// carrying a shadow — the halo cannot ride on the sweep, because an
        /// explicit shadowPath covers the whole ribbon and would glow around
        /// stretches of border that are not lit yet.
        let base = CAShapeLayer()
        /// The bright segment that grows out from the bottom centre.
        let sweep = CAShapeLayer()
        var pulse: BorderPulse = .attention
        var cornerRadius: CGFloat = 0
        var topFlare: CGFloat = 0
        var top: IslandTop = .flare
        /// What the sweep's animation was last built for. `apply()` runs from
        /// `layout()`, and SwiftUI calls that on every relayout — a resize, or
        /// the elapsed label ticking once a second through a live prompt —
        /// not just when the pulse actually changes. Comparing against this
        /// is what lets a plain relayout leave a running cycle alone instead
        /// of restarting it before it ever reaches its fade.
        private var appliedConfiguration: SweepConfiguration?
        private struct SweepConfiguration: Equatable {
            let pulse: BorderPulse
            let reduceMotion: Bool
        }

        /// Fades the edge out toward the two ends so it has no visible
        /// termination — it thins away into the screen edge instead of stopping.
        ///
        /// This is a mask rather than a varying `lineWidth` because a
        /// `CAShapeLayer`'s stroke is one width for the whole path. A true taper
        /// means abandoning the stroke and filling a hand-built ribbon, which
        /// would also take `strokeStart`/`strokeEnd` away from the sweep. At this
        /// line width the two are indistinguishable, and the mask has the better
        /// edges — a sub-pixel fill aliases where an alpha ramp does not.
        ///
        /// It masks `content` rather than the base and sweep separately, so the
        /// line and its halo taper as one — masked apart, the glow would outlive
        /// the line it belongs to.
        let taper = CAGradientLayer()

        /// Exists only to carry the mask. The mask cannot go on the view's own
        /// backing layer: AppKit owns that layer and resets properties on it out
        /// from under you, which silently killed the sweep's animation the first
        /// time this was built. A plain sublayer we own is stable.
        let content = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for layer in [base, sweep] {
                layer.fillColor = nil
                layer.lineWidth = PulsingOutline.lineWidth
                layer.lineCap = .round
            }
            base.shadowOffset = .zero
            taper.startPoint = CGPoint(x: 0, y: 0.5)
            taper.endPoint = CGPoint(x: 1, y: 0.5)
            taper.colors = [
                NSColor.clear.cgColor, NSColor.white.cgColor,
                NSColor.white.cgColor, NSColor.clear.cgColor,
            ]
            taper.locations = PulsingOutline.taperStops
            content.addSublayer(base)
            content.addSublayer(sweep)
            content.mask = taper
            self.layer?.addSublayer(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Decoration only. This view covers the whole pill, and without this it
        /// swallows the click that pins the card open — `.allowsHitTesting` on
        /// the SwiftUI side does not reach an AppKit subview's own hit test.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Laid out here rather than in `updateNSView`, for the reason `LiveRail`
        /// documents above: SwiftUI resizes the view without necessarily calling
        /// `updateNSView`. The pill does resize while mounted — its width follows
        /// the elapsed counter as it rolls 9s -> 10s -> 1:00.
        override func layout() {
            super.layout()
            guard bounds.width > 0 else { return }

            let outline = PulsingOutline.layerPath(
                in: bounds, cornerRadius: cornerRadius, topFlare: topFlare, top: top)
            // The halo's geometry is the STROKE, not the silhouette. An explicit
            // shadowPath is *filled* to derive the shadow, so handing it the
            // outline would wash a blurred wedge across the fill and its content
            // instead of haloing the edge.
            let ribbon = outline.copy(
                strokingWithWidth: PulsingOutline.lineWidth, lineCap: .butt,
                lineJoin: .round, miterLimit: 10)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [base, sweep] {
                layer.frame = bounds
                layer.path = outline
            }
            base.shadowPath = ribbon
            // The mask has to reach past `bounds` on every side or it becomes a
            // crop instead of a taper: the concave flares overhang by `topFlare`
            // at each end, and the halo spreads further still. Anything outside a
            // mask is alpha zero, so a mask sized to `bounds` would cut the tips
            // clean off — the exact hard ending this is meant to remove.
            let reach = bounds.insetBy(dx: -topFlare, dy: -PulsingOutline.haloReach)
            content.frame = bounds
            taper.frame = reach
            CATransaction.commit()

            apply()
        }

        func apply() {
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch pulse {
            case .attention:
                let baseColor = NSColor(
                    still ? IslandPalette.alertStill : IslandPalette.alert
                ).cgColor
                base.isHidden = false
                base.strokeColor = baseColor
                base.shadowColor = baseColor
                base.shadowOpacity = 0.55
                base.shadowRadius = 9
                sweep.strokeColor = NSColor(IslandPalette.alertPulse).cgColor
                sweep.isHidden = still
            case .completion:
                // Nothing rests behind a completion — it is an instant, and must
                // leave no trace once it has passed.
                base.isHidden = true
                sweep.strokeColor = NSColor(IslandPalette.completionPulse).cgColor
                sweep.isHidden = false
            }
            CATransaction.commit()

            // Colour and geometry are cheap to redo on every pass; the
            // animation is not allowed to be. Only a change in what it should
            // look like — the pulse kind, or Reduce Motion flipping — may
            // touch it. Checking the layer itself ("is an animation already
            // attached?") would go wrong here: the completion sweep sets
            // `isRemovedOnCompletion = false` so it stays attached long after
            // it finishes, and that leftover would then block a later
            // attention pulse from ever starting on the same view.
            let configuration = SweepConfiguration(pulse: pulse, reduceMotion: still)
            guard configuration != appliedConfiguration else { return }
            appliedConfiguration = configuration

            for key in PulsingOutline.animationKeys { sweep.removeAnimation(forKey: key) }
            guard !still else { return }
            switch pulse {
            case .attention: addAttentionSweep()
            case .completion: addCompletionSweep()
            }
        }

        /// Grows from the bottom centre to both flares over the first half of
        /// the cycle, then fades out over the second while `base` stays lit.
        private func addAttentionSweep() {
            let cycle = PulsingOutline.attentionCycle
            add(
                grow: [0, 0.5, 1], fadeAt: 0.5, duration: cycle, repeats: true)
        }

        private func addCompletionSweep() {
            add(
                grow: [0, 0.33, 1], fadeAt: 0.67,
                duration: PulsingOutline.completionWindow, repeats: false)
        }

        /// Keyframes rather than a group: every property shares one duration and
        /// one set of key times, so the two halves stay mirrored and the fade
        /// stays in step by construction rather than by tuning.
        private func add(
            grow keyTimes: [NSNumber], fadeAt: NSNumber, duration: CFTimeInterval, repeats: Bool
        ) {
            let spec: [(String, [Any])] = [
                ("strokeStart", [0.5, 0.0, 0.0]),
                ("strokeEnd", [0.5, 1.0, 1.0]),
            ]
            for (keyPath, values) in spec {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.duration = duration
                animation.repeatCount = repeats ? .infinity : 1
                animation.timingFunctions = [
                    CAMediaTimingFunction(name: .easeInEaseOut),
                    CAMediaTimingFunction(name: .linear),
                ]
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
                sweep.add(animation, forKey: "island.outline.\(keyPath)")
            }

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1.0, 1.0, 0.0]
            fade.keyTimes = [0, fadeAt, 1]
            fade.duration = duration
            fade.repeatCount = repeats ? .infinity : 1
            fade.timingFunctions = [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            sweep.add(fade, forKey: "island.outline.opacity")
        }
    }

    /// How long a completion is announced for. Must match
    /// `IslandViewModel.completionPulseDuration`, or the layer outlives the
    /// state that mounted it (or dies before it).
    static let completionWindow: CFTimeInterval = 1.8

    static func layerPath(
        in rect: CGRect, cornerRadius: CGFloat, topFlare: CGFloat, top: IslandTop = .flare
    ) -> CGPath {
        let authored = IslandOutline(cornerRadius: cornerRadius, topFlare: topFlare, top: top)
            .path(in: rect).cgPath
        let flip = CGAffineTransform(translationX: 0, y: rect.height)
            .scaledBy(x: 1, y: -1)
        let flipped = CGMutablePath()
        flipped.addPath(authored, transform: flip)
        return flipped
    }

    fileprivate static let animationKeys = [
        "island.outline.strokeStart", "island.outline.strokeEnd", "island.outline.opacity",
    ]

    func makeNSView(context: NSViewRepresentableContext<Self>) -> OutlineView {
        OutlineView(frame: .zero)
    }

    func updateNSView(_ view: OutlineView, context: NSViewRepresentableContext<Self>) {
        view.pulse = pulse
        view.cornerRadius = cornerRadius
        view.topFlare = topFlare
        view.top = top
        view.needsLayout = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: OutlineView,
        context: NSViewRepresentableContext<Self>
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// The status trace: one mark per state, all drawn with one pen.
///
/// What replaced a spinning ring — and then replaced its own first draft. The
/// ring drew nine states with two glyphs: `running`, `thinking`, `prompting` and
/// `compacting` all span, and `done`, `error`, `idle` and "your turn" all drew
/// the same checkmark, so a failed session and a finished one were identical but
/// for their tint.
///
/// The first fix gave every state the same four bars and a different *gait* —
/// speed, amplitude, phase. That failed on the real pill, for a reason worth
/// recording: at 16pt in the corner of the eye, you read how many marks there
/// are and which way they run long before you read how fast they move. Count and
/// axis are pre-attentive; tempo is a difference of degree. Thinking, working and
/// "your turn" came out nearly indistinguishable, with colour doing all the work.
///
/// So the states differ in silhouette now, and what holds the set together is
/// the pen rather than the shape. Every figure is built from the same
/// `penWidth`-wide round-capped module: one module is a dot, a stretched one is a
/// bar, a full-height one is a caret.
///
///     thinking    3 dots at the floor, a brightness wave travelling through
///     running     3 balls bouncing on a ground line, squashing as they land
///     compacting  2 bars closing on each other, rising as they meet
///     sent        3 dots flying in from the left, into the murmur's places
///     your turn   1 caret, blinking
///     idle        1 dim dot, still
///     done/failed a check / a cross, stroked on after the marks fall
///
/// `running` is the exception to the pen, and it earned it. It was bars twice —
/// four of them crackling — and both times it lost to `thinking` at a glance,
/// because bars can only differ from other bars by count, height or tempo, and
/// at this size those are all differences of degree. Balls differ in kind: they
/// move up and down where every other figure holds its line, they carry a ground
/// to bounce off, and they deform — nothing else here changes shape. It is also
/// the state you see most, which is the one worth spending a drawing on.
///
/// The caret is the one that changes meaning rather than styling. A blink is the
/// only mark in computing that already means "a machine has stopped and is
/// waiting for a human", and nobody has to be taught it.
///
/// Every hook event kicks a bright swell across whatever is showing, so a session
/// grinding through a long call looks unmistakably different from one that has
/// hung. That is the reading a spinner can never give: it turns at the same rate
/// either way.
///
/// Built from CALayers driven by CA animations, like both siblings above and for
/// the same reason: a SwiftUI `repeatForever` re-runs the whole view graph every
/// frame.
struct StatusMark: NSViewRepresentable {
    let state: SessionState
    /// When this session last heard from Claude Code. A change fires one swell
    /// across the marks; an unchanged stamp leaves the running figure alone,
    /// which matters because SwiftUI re-runs this view on every 1 Hz tick.
    var eventStamp: Date = .distantPast

    /// The slot the pill reserves. `rightClusterWidth` budgets exactly this, so
    /// the two cannot drift.
    static let size: CGFloat = 16

    // MARK: The pen
    //
    // One module, six figures. Keeping every mark to a single width and cap is
    // what lets the shapes differ this much and still read as one object's
    // states rather than as six unrelated icons.

    /// How many modules exist. Figures use the first one, two or three of them and
    /// hide the rest — the count is part of what distinguishes them.
    static let penCount = 3
    static let penWidth: CGFloat = 2.4
    /// A dot: one module, unstretched. Height equals width, so the round cap
    /// closes it into a circle.
    static let dot: CGFloat = penWidth
    /// A caret: as tall as the slot allows, leaving room for an event swell to
    /// ride on top without clipping.
    static let full: CGFloat = 12.5

    static let verdictWidth: CGFloat = 1.8

    /// Idle is the one state with nothing at all to say, so it says it quietly.
    static let restAlpha: Float = 0.45
    /// The dark half of the caret's blink — see the note where it is applied.
    static let caretDim: Float = 0.22

    // MARK: Figures

    /// running: three balls bouncing on a ground line.
    ///
    /// Every table here is deliberately mismatched. Equal sizes, equal heights and
    /// a common period give a chorus line — three marks moving as one, which is
    /// the failure the bars kept landing in. Three different periods that share no
    /// factor never come back into step, so the group is always mid-scatter.
    static let bounceCount = 3
    static let bounceSize: [CGFloat] = [3.4, 3.8, 3.2]
    static let bounceX: [CGFloat] = [4.2, 8.0, 11.8]
    /// A ball's *bottom*, not its centre: at rest all three sit on `bounceFloor`,
    /// and a shared baseline is what says they are bouncing on the same ground
    /// even though they are different sizes.
    static let bounceFloor: CGFloat = 3
    static let bounceApex: [CGFloat] = [9.4, 10.4, 8.6]
    static let bounceCycle: [CFTimeInterval] = [0.72, 0.88, 0.62]
    static let bouncePhase: [Double] = [0, 0.35, 0.7]

    /// How flat a ball goes at contact, and how far it spreads doing it.
    static let bounceSquashY: CGFloat = 0.62
    static let bounceSquashX: CGFloat = 1.24
    /// Where the squash lives in the cycle. Only around contact — spread across
    /// the whole arc it reads as a ball pulsing rather than one landing.
    static let bounceSquashTimes: [NSNumber] = [0, 0.1, 0.5, 0.9, 1]

    /// The ground. Without it three balls at three heights are three dots that
    /// happen to be moving; with it they are obviously bouncing off something.
    /// Quiet on purpose — it is the stage, not the act.
    static let groundWidth: CGFloat = 13
    static let groundThickness: CGFloat = 0.9
    static let groundAlpha: Float = 0.28

    /// thinking: three dots that stay on the floor while brightness travels
    /// through them. The tiny swell is there so it reads as alive rather than as
    /// three static pixels — it never leaves the floor, which is the whole point.
    static let murmurCycle: CFTimeInterval = 1.5
    static let murmurPhases: [Double] = [0, 0.20, 0.40]
    /// The crest. Enough that the wave is a change of size and not only of
    /// brightness, and still low enough that the group reads as sitting on the
    /// floor — which is the entire distinction from `work`.
    static let murmurSwell: CGFloat = 4.6
    /// How far the wave's trough dims. Not to nothing: at 0.26 the two dots
    /// behind the crest all but disappeared, and a mark that comes and goes in a
    /// 16pt slot reads as three dots one moment and one dot the next.
    static let murmurDim: Float = 0.34

    /// compacting: two bars sliding together and rising as they meet, like a pile
    /// being pressed. Motion across rather than up, which is what keeps it clear
    /// of `running` at a glance.
    static let squeezeCycle: CFTimeInterval = 1.5
    private static let squeezeOpenGap: CGFloat = 8
    private static let squeezeShutGap: CGFloat = 1.2
    static let squeezeLow: CGFloat = 8.5
    static let squeezeHigh: CGFloat = 11

    /// sent: the murmur's three dots flying in from off-slot left, one after
    /// another, and stopping exactly where `.thinking` will hold them — so the
    /// flash hands over without anything jumping.
    ///
    /// A single dot was the first attempt and it was the wrong mark twice over: a
    /// lone dot at the floor is the same silhouette as `idle`, and one small dot
    /// arriving is too little event for the only state that means "your prompt
    /// went out". Three dots streaming in read as departure.
    static let launchTravel: CFTimeInterval = 0.55
    static let launchStagger: CFTimeInterval = 0.1

    /// How much taller one event makes a murmur dot, how long the swell takes to
    /// reach the next one, and how long it lasts. The bounce answers an event
    /// differently — see `kick`.
    private static let kickSwell: CGFloat = 1.2
    private static let kickStagger: CFTimeInterval = 0.05
    private static let kickDuration: CFTimeInterval = 0.42

    /// What the pen is drawing. Distinct silhouettes on purpose — the whole
    /// complaint against both earlier passes was states that looked alike.
    enum Figure: Equatable {
        /// thinking. Three dots, a brightness wave travelling through them.
        case murmur
        /// running. Three balls bouncing on a ground line.
        case bounce
        /// compacting. Two bars closing on each other.
        case squeeze
        /// prompting. One dot arriving.
        case launch
        /// A permission prompt, or the idle nudge. One caret, blinking.
        case caret
        case check
        case cross
        /// idle. One dim dot, dead still.
        case rest
    }

    var figure: Figure {
        switch state {
        case .thinking: .murmur
        case .running: .bounce
        case .compacting: .squeeze
        case .prompting: .launch
        case .awaitingPermission, .idle(waitingOnUser: true): .caret
        case .done: .check
        case .error: .cross
        case .idle: .rest
        }
    }

    /// The same pair the status word beside it is drawn in. The flat palette the
    /// ring used disagreed with that word — thinking was violet in one and grey
    /// in the other.
    private var tint: NSColor { NSColor(IslandPalette.accentPair(for: state).bright) }

    // MARK: Geometry

    /// Centres for `count` marks separated by `gap`, as a group centred in the
    /// slot. Every figure's layout comes from here, so they share a midpoint.
    static func centres(_ count: Int, gap: CGFloat) -> [CGFloat] {
        let span = CGFloat(count) * penWidth + CGFloat(count - 1) * gap
        let first = (size - span) / 2 + penWidth / 2
        return (0..<count).map { first + CGFloat($0) * (penWidth + gap) }
    }

    static var murmurCentres: [CGFloat] { centres(3, gap: 3) }
    static var squeezeOpen: [CGFloat] { centres(2, gap: squeezeOpenGap) }
    static var squeezeShut: [CGFloat] { centres(2, gap: squeezeShutGap) }

    /// The two halves of a fall, in closed form — so the Reduce Motion still and
    /// the offscreen filmstrip land on the curve the render server draws rather
    /// than a straight line through it.
    static func easedOut(_ t: Double) -> Double { 1 - pow(1 - t, 2) }
    static func easedIn(_ t: Double) -> Double { t * t }

    /// Where ball `index` has its bottom at `phase` of its own cycle: up on a
    /// decelerating curve, down on an accelerating one. That asymmetry is the
    /// whole difference between a bounce and a float — it puts the ball near the
    /// top for most of the cycle and snaps it through contact.
    static func bounceBottom(_ index: Int, at phase: Double) -> CGFloat {
        let apex = bounceApex[index]
        if phase < 0.5 {
            return bounceFloor + (apex - bounceFloor) * CGFloat(easedOut(phase * 2))
        }
        return apex + (bounceFloor - apex) * CGFloat(easedIn(phase * 2 - 1))
    }

    /// Where a mark at `phase` sits with the motion taken away — a frozen frame
    /// of the same wave, so Reduce Motion still tells the figures apart instead
    /// of flattening them all to one silhouette.
    static func frozen(_ phase: Double) -> CGFloat {
        CGFloat(0.5 - 0.5 * cos(2 * .pi * phase))
    }

    /// Coordinates from the reference's 20pt viewBox. y-up, because a CALayer
    /// inside an unflipped `NSView` is — see the note in `SelfTest`.
    static func checkPath() -> CGPath {
        let p = CGMutablePath()
        let w = size
        p.move(to: CGPoint(x: w * 0.28, y: w * 0.50))
        p.addLine(to: CGPoint(x: w * 0.43, y: w * 0.34))
        p.addLine(to: CGPoint(x: w * 0.72, y: w * 0.66))
        return p
    }

    /// Two strokes rather than a symbol, so `strokeEnd` draws it on the same way
    /// the checkmark is drawn on.
    static func crossPath() -> CGPath {
        let p = CGMutablePath()
        let w = size
        p.move(to: CGPoint(x: w * 0.32, y: w * 0.32))
        p.addLine(to: CGPoint(x: w * 0.68, y: w * 0.68))
        p.move(to: CGPoint(x: w * 0.68, y: w * 0.32))
        p.addLine(to: CGPoint(x: w * 0.32, y: w * 0.68))
        return p
    }

    // MARK: View

    /// Holds the pen strokes in a group of their own, so one opacity animation
    /// can retire all of them at once, and keeps the state the guard below needs
    /// — SwiftUI hands us a fresh `StatusMark` value on every update.
    final class TraceView: NSView {
        let strokes: CALayer = {
            let group = CALayer()
            group.frame = CGRect(x: 0, y: 0, width: StatusMark.size, height: StatusMark.size)
            return group
        }()
        /// The check or the cross, and never anything else.
        let verdict = CAShapeLayer()
        /// The ground the balls bounce on. Only `bounce` shows it.
        let ground = CALayer()
        /// The seven reusable modules. Hidden rather than destroyed when a figure
        /// wants fewer: rebuilding them on every state change would throw away
        /// the running animation on the ones that survive.
        private(set) var pen: [CALayer] = []

        /// What the animations currently on the layers were built for. Rebuilt
        /// only when this changes: `updateNSView` runs on every relayout — the
        /// elapsed label ticking once a second is enough — and restarting a
        /// figure every second would freeze it on its first frame.
        var applied: Applied?
        struct Applied: Equatable {
            let figure: Figure
            let reduceMotion: Bool
        }
        /// The stamp the last kick was fired for. Nil until the first update, so
        /// mounting a view mid-session does not fire one for history.
        var kickedAt: Date?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            // Added first, so a squashing ball spreads over the line rather
            // than under it.
            ground.bounds = CGRect(
                x: 0, y: 0, width: StatusMark.groundWidth,
                height: StatusMark.groundThickness)
            ground.cornerRadius = StatusMark.groundThickness / 2
            ground.position = CGPoint(
                x: StatusMark.size / 2,
                y: StatusMark.bounceFloor - StatusMark.groundThickness / 2)
            ground.opacity = StatusMark.groundAlpha
            ground.isHidden = true
            strokes.addSublayer(ground)

            for _ in 0..<StatusMark.penCount {
                let layer = CALayer()
                layer.bounds = CGRect(
                    x: 0, y: 0, width: StatusMark.penWidth, height: StatusMark.dot)
                layer.position = CGPoint(x: StatusMark.size / 2, y: StatusMark.size / 2)
                // Half the width, so the ends stay capped at every height and a
                // mark is a circle when it bottoms out. Core Animation clamps the
                // radius against the shorter side for us.
                layer.cornerRadius = StatusMark.penWidth / 2
                pen.append(layer)
                strokes.addSublayer(layer)
            }
            verdict.frame = CGRect(x: 0, y: 0, width: StatusMark.size, height: StatusMark.size)
            verdict.fillColor = nil
            verdict.lineWidth = StatusMark.verdictWidth
            verdict.lineCap = .round
            verdict.lineJoin = .round
            verdict.isHidden = true
            layer?.addSublayer(strokes)
            layer?.addSublayer(verdict)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Decoration. Without this it swallows the click that pins the card
        /// open, exactly as `PulsingOutline` documents.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: NSViewRepresentableContext<Self>) -> TraceView {
        TraceView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
    }

    func updateNSView(_ view: TraceView, context: NSViewRepresentableContext<Self>) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Colour is cheap to redo every pass; the animations are not.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in view.pen { layer.backgroundColor = tint.cgColor }
        view.ground.backgroundColor = tint.cgColor
        view.verdict.strokeColor = tint.cgColor
        CATransaction.commit()

        let wanted = TraceView.Applied(figure: figure, reduceMotion: still)
        if wanted != view.applied {
            let previous = view.applied?.figure
            view.applied = wanted
            apply(wanted, from: previous, to: view)
        }

        // One swell per event, and only for the two figures a tool call can
        // actually arrive during: the settled figures have no marks on screen to
        // swell, and a prompt or a compaction is not what the tick is reporting.
        let isFirst = view.kickedAt == nil
        if view.kickedAt != eventStamp {
            view.kickedAt = eventStamp
            if !isFirst, !still, figure == .bounce || figure == .murmur { kick(view, figure) }
        }
    }

    /// Puts the figure on the layers, animations included. Every path out of here
    /// leaves them fully described — nothing is inherited from what was there.
    private func apply(
        _ applied: TraceView.Applied, from previous: Figure?, to view: TraceView
    ) {
        let still = applied.reduceMotion
        for layer in view.pen { layer.removeAllAnimations() }
        view.ground.removeAllAnimations()
        view.strokes.removeAllAnimations()
        view.verdict.removeAllAnimations()

        let settling = applied.figure == .check || applied.figure == .cross
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Every figure gets the pen back to its default: a bar-width module at the
        // floor, unscaled, fully lit. Without this a figure inherits whatever the
        // last one left behind, and `work` leaves circles three points across,
        // shrunk by transform and half faded out.
        for layer in view.pen {
            layer.bounds = CGRect(x: 0, y: 0, width: Self.penWidth, height: Self.dot)
            layer.cornerRadius = Self.penWidth / 2
            layer.transform = CATransform3DIdentity
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.opacity = 1
        }
        view.ground.isHidden = true
        // The marks retire on a settle, so the group's resting opacity is zero
        // and the fade below is what holds them visible while they fall.
        view.strokes.opacity = settling ? 0 : 1
        view.verdict.path =
            settling ? (applied.figure == .check ? Self.checkPath() : Self.crossPath()) : nil
        view.verdict.isHidden = !settling
        view.verdict.strokeEnd = 1
        CATransaction.commit()

        switch applied.figure {
        case .murmur:
            show(view, 3, at: Self.murmurCentres)
            for (index, layer) in view.pen.prefix(3).enumerated() {
                let phase = Self.murmurPhases[index]
                guard !still else {
                    let at = Self.frozen(phase)
                    set(layer, height: Self.dot + (Self.murmurSwell - Self.dot) * at)
                    set(layer, alpha: Self.murmurDim + (1 - Self.murmurDim) * Float(at))
                    continue
                }
                set(layer, height: Self.dot)
                set(layer, alpha: Self.murmurDim)
                // Brightness carries the wave and the swell only seasons it: the
                // marks must not climb, or this becomes a shorter `work`.
                wave(
                    layer, keyPath: "bounds.size.height",
                    from: Self.dot, to: Self.murmurSwell,
                    cycle: Self.murmurCycle, phase: phase)
                wave(
                    layer, keyPath: "opacity",
                    from: CGFloat(Self.murmurDim), to: 1,
                    cycle: Self.murmurCycle, phase: phase, key: Self.waveKey)
            }

        case .bounce:
            reveal(view, Self.bounceCount)
            view.ground.isHidden = false
            for (index, layer) in view.pen.enumerated() {
                let cycle = Self.bounceCycle[index]
                let phase = Self.bouncePhase[index]
                set(layer, size: Self.bounceSize[index])
                // Anchored at the bottom, so the squash flattens the ball ONTO
                // the ground instead of shrinking it about its middle — which
                // lifts it off the line at the exact frame it is meant to land.
                // Position therefore means the ball's bottom, not its centre.
                set(layer, anchoredAtBottom: true)

                guard !still else {
                    // Parked where its own phase would have had it, easings
                    // included, so the three are at three heights with the motion
                    // taken away rather than collapsing into a row.
                    set(
                        layer,
                        at: CGPoint(
                            x: Self.bounceX[index],
                            y: Self.bounceBottom(index, at: phase)))
                    continue
                }

                set(layer, at: CGPoint(x: Self.bounceX[index], y: Self.bounceFloor))

                let hop = CAKeyframeAnimation(keyPath: "position.y")
                hop.values = [Self.bounceFloor, Self.bounceApex[index], Self.bounceFloor]
                hop.keyTimes = [0, 0.5, 1]
                // Decelerating up, accelerating down. An easeInEaseOut here — the
                // curve every other figure in this file uses — floats.
                hop.timingFunctions = [
                    CAMediaTimingFunction(name: .easeOut),
                    CAMediaTimingFunction(name: .easeIn),
                ]
                hop.duration = cycle
                hop.repeatCount = .infinity
                hop.timeOffset = phase * cycle
                layer.add(hop, forKey: Self.penKey)

                // The whole transform rather than `transform.scale.x` and
                // `.scale.y` as two animations: those write two components of one
                // property, and which of them lands is not worth relying on.
                let contact = NSValue(
                    caTransform3D: CATransform3DMakeScale(
                        Self.bounceSquashX, Self.bounceSquashY, 1))
                let round = NSValue(caTransform3D: CATransform3DIdentity)
                let squash = CAKeyframeAnimation(keyPath: "transform")
                squash.values = [contact, round, round, round, contact]
                squash.keyTimes = Self.bounceSquashTimes
                squash.duration = cycle
                squash.repeatCount = .infinity
                squash.timeOffset = phase * cycle
                squash.timingFunctions = [
                    CAMediaTimingFunction(name: .easeOut),
                    CAMediaTimingFunction(name: .linear),
                    CAMediaTimingFunction(name: .linear),
                    CAMediaTimingFunction(name: .easeIn),
                ]
                layer.add(squash, forKey: Self.waveKey)
            }

        case .squeeze:
            let open = Self.squeezeOpen
            let shut = Self.squeezeShut
            show(view, 2, at: open)
            for (index, layer) in view.pen.prefix(2).enumerated() {
                set(layer, alpha: 1)
                set(layer, height: Self.squeezeLow)
                guard !still else { continue }
                // Across, not up. The rise as they meet is what makes it read as
                // material being pressed rather than two bars merely sliding.
                wave(
                    layer, keyPath: "position.x", from: open[index], to: shut[index],
                    cycle: Self.squeezeCycle, phase: 0)
                wave(
                    layer, keyPath: "bounds.size.height",
                    from: Self.squeezeLow, to: Self.squeezeHigh,
                    cycle: Self.squeezeCycle, phase: 0, key: Self.waveKey)
            }

        case .launch:
            let centres = Self.murmurCentres
            show(view, 3, at: centres)
            for (index, layer) in view.pen.prefix(3).enumerated() {
                set(layer, height: Self.dot)
                set(layer, alpha: 1)
                guard !still else { continue }
                let arrive = CABasicAnimation(keyPath: "position.x")
                arrive.fromValue = -Self.penWidth
                arrive.toValue = centres[index]
                arrive.duration = Self.launchTravel
                arrive.beginTime =
                    CACurrentMediaTime() + Double(index) * Self.launchStagger
                arrive.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // `.backwards` so the dots still waiting their turn hold off-slot
                // instead of sitting at their destinations until they animate.
                arrive.fillMode = .backwards
                layer.add(arrive, forKey: Self.penKey)
            }

        case .caret:
            show(view, 1, at: [Self.size / 2])
            set(view.pen[0], height: Self.full)
            set(view.pen[0], alpha: 1)
            guard !still else { return }
            // Discrete, not a breath. A breath says "alive and busy"; a blink
            // says "stopped, waiting for you", which is the whole message. The
            // period is half `PulsingOutline.attentionCycle`, so two blinks fit
            // one pass of the edge and the two lock instead of beating.
            //
            // It blinks to `caretDim`, not to nothing. The discontinuity is what
            // makes a blink a blink; the depth is not. Going to zero left the
            // slot empty half the time, and a HUD you glance at cannot afford a
            // mark that is missing on even odds when you look.
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1.0, Self.caretDim]
            blink.keyTimes = [0, 0.5, 1]
            blink.calculationMode = .discrete
            blink.duration = PulsingOutline.attentionCycle / 2
            blink.repeatCount = .infinity
            view.pen[0].add(blink, forKey: Self.penKey)

        case .rest:
            show(view, 1, at: [Self.size / 2])
            set(view.pen[0], height: Self.dot)
            set(view.pen[0], alpha: Self.restAlpha)

        case .check, .cross:
            let visible = view.pen.filter { !$0.isHidden }
            // Coming off the bounce there is nothing to collapse: a ball is a
            // circle, and shrinking its height on the way out would flatten it
            // into an oval. It just fades.
            let collapses = previous != .bounce
            guard !still else {
                if collapses { for layer in visible { set(layer, height: Self.dot) } }
                return
            }
            // Two beats: the marks fall flat and retire, then the verdict is
            // drawn on the space they left. The fall starts from wherever each
            // mark happens to be — read off the presentation layer — so a
            // session that finishes mid-swing does not snap to full height first.
            let now = CACurrentMediaTime()
            if collapses {
                for (index, layer) in visible.enumerated() {
                    let from = layer.presentation()?.bounds.height ?? layer.bounds.height
                    set(layer, height: Self.dot)
                    let fall = CABasicAnimation(keyPath: "bounds.size.height")
                    fall.fromValue = from
                    fall.toValue = Self.dot
                    fall.duration = 0.22
                    // Right to left: the newest end of the trace settles last.
                    fall.beginTime = now + Double(visible.count - 1 - index) * 0.035
                    fall.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    fall.fillMode = .backwards
                    layer.add(fall, forKey: Self.penKey)
                }
            }

            let retire = CABasicAnimation(keyPath: "opacity")
            retire.fromValue = 1
            retire.toValue = 0
            retire.duration = 0.16
            retire.beginTime = now + 0.24
            retire.fillMode = .backwards
            view.strokes.add(retire, forKey: Self.retireKey)

            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.30
            draw.beginTime = now + 0.26
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            draw.fillMode = .backwards
            view.verdict.add(draw, forKey: Self.drawKey)
        }
    }

    /// Which modules this figure uses, and where they sit across the slot's waist.
    private func show(_ view: TraceView, _ count: Int, at centres: [CGFloat]) {
        reveal(view, count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in view.pen.prefix(count).enumerated() {
            layer.position = CGPoint(x: centres[index], y: Self.size / 2)
        }
        CATransaction.commit()
    }

    /// Which modules this figure uses. Separate from `show` because the balls
    /// place their own in two dimensions rather than along one line.
    private func reveal(_ view: TraceView, _ count: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in view.pen.enumerated() { layer.isHidden = index >= count }
        CATransaction.commit()
    }

    /// `from -> to -> from` forever, eased both ways, offset into the cycle
    /// rather than delayed before it — so every mark is already mid-swing on the
    /// first frame instead of the group starting out in unison.
    private func wave(
        _ layer: CALayer, keyPath: String, from: CGFloat, to: CGFloat,
        cycle: CFTimeInterval, phase: Double, key: String? = nil
    ) {
        let swing = CAKeyframeAnimation(keyPath: keyPath)
        swing.values = [from, to, from]
        swing.keyTimes = [0, 0.5, 1]
        swing.duration = cycle
        swing.repeatCount = .infinity
        swing.timeOffset = phase * cycle
        swing.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        layer.add(swing, forKey: key ?? Self.penKey)
    }

    private func set(_ layer: CALayer, height: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds.size.height = height
        CATransaction.commit()
    }

    private func set(_ layer: CALayer, alpha: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = alpha
        CATransaction.commit()
    }

    /// A module as a circle `size` across, for the one figure that is not bars.
    private func set(_ layer: CALayer, size: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        CATransaction.commit()
    }

    private func set(_ layer: CALayer, at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = point
        CATransaction.commit()
    }

    /// Moves the layer's anchor to its bottom edge, so a scale deforms it against
    /// the ground rather than about its own middle. `position` then addresses the
    /// bottom of the mark instead of its centre.
    private func set(_ layer: CALayer, anchoredAtBottom: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: anchoredAtBottom ? 0 : 0.5)
        CATransaction.commit()
    }

    /// One event, one swell travelling left to right, riding additively on top of
    /// whatever the figure is doing — so the trace visibly ticks each time Claude
    /// gets something done, and a wedged session does not.
    private func kick(_ view: TraceView, _ figure: Figure) {
        let now = CACurrentMediaTime()
        guard figure != .bounce else {
            // The balls flash and the ground lights with them. Nothing touches
            // the arcs: a ball that suddenly jumped or bounced higher would read
            // as a bug in the physics rather than as news, which is the same
            // reason the swell below is only for the murmur.
            // Plain `spark`: the ground is dimmed by its layer opacity, not by a
            // faded colour, so it takes the same flash as the balls and stays as
            // quiet as it was.
            view.ground.add(spark(at: now), forKey: Self.kickColorKey)
            for (index, layer) in view.pen.enumerated() where !layer.isHidden {
                layer.add(
                    spark(at: now + Double(index) * Self.kickStagger),
                    forKey: Self.kickColorKey)
            }
            return
        }

        for (index, layer) in view.pen.enumerated() where !layer.isHidden {
            let at = now + Double(index) * Self.kickStagger

            let rise = CAKeyframeAnimation(keyPath: "bounds.size.height")
            rise.values = [CGFloat(0), Self.kickSwell, CGFloat(0)]
            rise.keyTimes = [0, 0.3, 1]
            rise.duration = Self.kickDuration
            rise.beginTime = at
            rise.isAdditive = true
            rise.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            layer.add(rise, forKey: Self.kickHeightKey)
            layer.add(spark(at: at), forKey: Self.kickColorKey)
        }
    }

    /// A mark flashing hot and cooling back to its tint. Between the accent and
    /// white rather than white: a flat white spark on a black pill outshines
    /// everything else on the row for a fifth of a second.
    private func spark(at time: CFTimeInterval) -> CABasicAnimation {
        let hot = tint.blended(withFraction: 0.55, of: .white) ?? tint
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = hot.cgColor
        animation.toValue = tint.cgColor
        animation.duration = Self.kickDuration
        animation.beginTime = time
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.fillMode = .backwards
        return animation
    }

    private static let penKey = "island.trace.pen"
    private static let waveKey = "island.trace.wave"
    private static let retireKey = "island.trace.retire"
    private static let drawKey = "island.trace.draw"
    private static let kickHeightKey = "island.trace.kick.height"
    private static let kickColorKey = "island.trace.kick.color"

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TraceView,
        context: NSViewRepresentableContext<Self>
    ) -> CGSize? {
        CGSize(width: Self.size, height: Self.size)
    }
}
