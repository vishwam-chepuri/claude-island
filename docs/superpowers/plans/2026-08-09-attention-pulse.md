# Travelling Attention Pulses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the island's uniform breathing border with two travelling pulses — a repeating yellow one while a permission prompt is up, and a single blue one when a session finishes.

**Architecture:** The outline is a symmetric open path, so its arc-length midpoint is the bottom-centre; "grow outward from the centre" is `strokeStart: 0.5→0` and `strokeEnd: 0.5→1` on one `CAShapeLayer`. Two layers are used: a static `base` carrying the halo (so the edge never goes fully dark) and an animated `sweep` drawn over it. Completion is detected as a state *transition* in the view model, which also drives a temporary display takeover.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Core Animation. No third-party dependencies.

## Global Constraints

- Repeating animations go through Core Animation, never SwiftUI `repeatForever`. A SwiftUI `withAnimation(...repeatForever())` re-runs the whole view graph every frame — measured at 4.5% CPU for one pulsing glyph vs 0.27% without.
- Springs only for shape morphs; no duration easing on the SwiftUI side. CA timing functions are fine — they are the render server's own curves.
- Idle-CPU contract: no session, no timer, no redraws. Anything animating must be torn down with its state.
- Nothing may be drawn in the camera gap — those pixels are a hole in the display.
- Neither pulse may change the shape's size. `your turn (permission) rests as a single line` must keep passing.
- Tests run `swift build && ./.build/debug/ClaudeIslandApp --selftest` and `swift run ClaudeIslandTests`. Not `swift test`.
- `git diff` needs `--no-ext-diff` in this repo; `-c diff.external=` does **not** work (git tries to exec the empty string).
- Commits carry no co-author trailer.
- Reduce Motion is read via `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.

## File Structure

- `Sources/ClaudeIslandApp/IslandViewModel.swift` — adds `BorderPulse`, the `borderPulse` predicate, completion-transition tracking, and the takeover. This file is already large; the new state is appended as one cohesive block near `apply(_:)` rather than scattered.
- `Sources/ClaudeIslandApp/CoreAnimationViews.swift` — `PulsingOutline` reworked from one layer to two.
- `Sources/ClaudeIslandApp/IslandView.swift` — one new palette constant, and the mount switches from `wantsAttentionBorder` to `borderPulse`.
- `Sources/ClaudeIslandApp/SelfTest.swift` — checks for every new model behaviour.

---

### Task 1: Replace `wantsAttentionBorder` with a two-case `BorderPulse`

**Files:**
- Modify: `Sources/ClaudeIslandApp/IslandViewModel.swift` (the `wantsAttentionBorder` property, currently around line 69-77)
- Modify: `Sources/ClaudeIslandApp/IslandView.swift` (the `.overlay` mount, currently around line 80-85)
- Test: `Sources/ClaudeIslandApp/SelfTest.swift` (`attentionBorderChecks`)

**Interfaces:**
- Consumes: `IslandViewModel.mode`, `IslandMode.alert`
- Produces: `enum BorderPulse: Equatable { case attention, completion }` and `IslandViewModel.borderPulse: BorderPulse?`. Tasks 2, 3, 4 and 5 all read `borderPulse`.

- [ ] **Step 1: Rewrite the existing checks to use the new predicate**

In `SelfTest.swift`, replace the whole body of `attentionBorderChecks` with:

```swift
    private static func attentionBorderChecks(_ checks: inout [Check], model: IslandViewModel) {
        model.isHovered = false
        model.apply(
            HUDSnapshot(
                primary: session(
                    "s",
                    state: .awaitingPermission(
                        PermissionAsk(
                            toolName: "Write", kind: .write, target: "/tmp/x", since: Date()))),
                others: []))
        checks.append(
            Check(
                name: "a permission prompt asks for the attention pulse",
                passed: model.borderPulse == .attention,
                detail: "mode=\(model.mode) pulse=\(String(describing: model.borderPulse))"))

        for (label, state) in [
            ("the idle nudge", SessionState.idle(waitingOnUser: true)),
            ("thinking", SessionState.thinking),
            ("a failure", SessionState.error("Bash failed")),
        ] {
            model.apply(HUDSnapshot(primary: session("s", state: state), others: []))
            checks.append(
                Check(
                    name: "\(label) asks for no pulse",
                    passed: model.borderPulse == nil,
                    detail: "mode=\(model.mode) pulse=\(String(describing: model.borderPulse))"))
        }

        model.apply(HUDSnapshot())
        checks.append(
            Check(
                name: "a dormant HUD asks for no pulse",
                passed: model.borderPulse == nil,
                detail: "mode=\(model.mode) pulse=\(String(describing: model.borderPulse))"))
    }
```

Note `done` is deliberately absent here — it is a transition, and Task 2 covers it.

- [ ] **Step 2: Run the build to verify it fails**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: FAIL with `value of type 'IslandViewModel' has no member 'borderPulse'`

- [ ] **Step 3: Add the type and the predicate**

In `IslandViewModel.swift`, delete the `wantsAttentionBorder` property and its doc comment. Add above `@MainActor @Observable final class IslandViewModel`:

```swift
/// What the island's edge should be doing.
///
/// The edge is reserved for the two events worth looking up for. A running
/// session gets nothing: it is the longest-lived state there is, and an edge lit
/// most of the time is one the eye stops reading.
enum BorderPulse: Equatable {
    /// A permission prompt. Repeating, yellow — a standing condition that stays
    /// true until you answer, so its signal has to stay visible.
    case attention
    /// A session just finished. One shot, blue — an instant, not a condition, so
    /// it must not linger.
    case completion
}
```

Then, in place of the deleted property:

```swift
    /// Which pulse the edge should run, if any.
    ///
    /// A prompt outranks a completion: it blocks Claude entirely, and the edge
    /// can only say one thing at a time.
    var borderPulse: BorderPulse? {
        guard mode != .dormant else { return nil }
        if mode == .alert { return .attention }
        return nil
    }
```

- [ ] **Step 4: Point the view at it**

In `IslandView.swift`, change the overlay condition from `if model.wantsAttentionBorder {` to:

```swift
            if model.borderPulse != nil {
```

- [ ] **Step 5: Run the build and self-test**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && ./.build/debug/ClaudeIslandApp --selftest 2>&1 | grep -E "pulse|passed|FAILED"`
Expected: `Build complete`, all pulse checks PASS, no FAILED line.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeIslandApp/IslandViewModel.swift Sources/ClaudeIslandApp/IslandView.swift Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "Name what the edge is doing, not whether it is on"
```

---

### Task 2: Fire a completion pulse on the transition into `done`

**Files:**
- Modify: `Sources/ClaudeIslandApp/IslandViewModel.swift` (`apply(_:)` around line 477, plus new stored properties)
- Test: `Sources/ClaudeIslandApp/SelfTest.swift`

**Interfaces:**
- Consumes: `BorderPulse` from Task 1, `HUDSnapshot`, `SessionState`
- Produces: `IslandViewModel.completionPulseID: String?` (private(set)), `IslandViewModel.endCompletionPulse()`, `static let completionPulseDuration: TimeInterval = 1.8`. Task 3 reads `completionPulseID` in `displaySession`; Task 5 reads `borderPulse == .completion`.

- [ ] **Step 1: Write the failing checks**

In `SelfTest.swift`, add this function and call it from `run()`'s check block immediately after `attentionBorderChecks(&checks, model: model)`:

```swift
        completionPulseChecks(&checks, model: model)
```

```swift
    /// A completion is an instant, not a condition: it fires on the edge into
    /// `done` and then stops. Firing on the state instead would re-pulse on
    /// every snapshot, on launch with an already-finished session, and every
    /// time the switcher landed on one.
    private static func completionPulseChecks(_ checks: inout [Check], model: IslandViewModel) {
        model.isHovered = false

        // A session first seen already finished must not pulse — that is the
        // HUD launching, not work completing.
        model.apply(HUDSnapshot(primary: session("s", state: .done), others: []))
        checks.append(
            Check(
                name: "a session first seen as done does not pulse",
                passed: model.borderPulse == nil,
                detail: "pulse=\(String(describing: model.borderPulse))"))

        // Working, then finished: that is the edge.
        model.apply(HUDSnapshot(primary: session("s", state: .thinking), others: []))
        model.apply(HUDSnapshot(primary: session("s", state: .done), others: []))
        checks.append(
            Check(
                name: "crossing into done asks for the completion pulse",
                passed: model.borderPulse == .completion,
                detail: "pulse=\(String(describing: model.borderPulse))"))

        // Still done on the next snapshot: the instant has passed.
        model.apply(HUDSnapshot(primary: session("s", state: .done), others: []))
        checks.append(
            Check(
                name: "staying done does not re-pulse",
                passed: model.borderPulse == .completion,
                detail: "still within the window: \(String(describing: model.borderPulse))"))

        model.endCompletionPulse()
        checks.append(
            Check(
                name: "the completion pulse ends on its own",
                passed: model.borderPulse == nil && model.completionPulseID == nil,
                detail: "pulse=\(String(describing: model.borderPulse))"))

        model.apply(HUDSnapshot(primary: session("s", state: .done), others: []))
        checks.append(
            Check(
                name: "a finished session does not pulse again once the window closes",
                passed: model.borderPulse == nil,
                detail: "pulse=\(String(describing: model.borderPulse))"))

        model.apply(HUDSnapshot())
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: FAIL with `value of type 'IslandViewModel' has no member 'endCompletionPulse'`

- [ ] **Step 3: Add the tracking and lifecycle**

In `IslandViewModel.swift`, add these stored properties next to `tickTimer`:

```swift
    /// The session whose completion is currently being announced, if any.
    /// Cleared by a one-shot timer — a completion is an instant, so nothing here
    /// outlives its own window.
    private(set) var completionPulseID: String?
    private var completionTimer: Timer?
    /// Every session's state as of the last snapshot, so a completion can be
    /// detected as a crossing rather than as a condition.
    private var lastStates: [String: SessionState] = [:]

    /// How long a completion is announced for: the sweep reaches the flares,
    /// holds long enough to read the name, then fades.
    static let completionPulseDuration: TimeInterval = 1.8
```

Replace `apply(_:)` with:

```swift
    func apply(_ snapshot: HUDSnapshot) {
        let previous = lastStates
        self.snapshot = snapshot
        // Nothing left to pin open once the last session goes away.
        if snapshot.primary == nil {
            isPinnedOpen = false
            selectedSessionID = nil
        }
        // Drop a selection whose session has ended.
        if let id = selectedSessionID, !snapshot.others.contains(where: { $0.id == id }),
            snapshot.primary?.id != id
        {
            selectedSessionID = nil
        }
        lastStates = Dictionary(
            allSessions.map { ($0.id, $0.state) }, uniquingKeysWith: { _, latest in latest })
        // A session that has gone away takes its pulse with it.
        if let id = completionPulseID, !allSessions.contains(where: { $0.id == id }) {
            endCompletionPulse()
        }
        noteCompletions(since: previous)
        syncTicker()
    }

    /// Starts a completion pulse for the first session that crossed into `done`.
    ///
    /// Suppressed while a prompt is up — a prompt blocks Claude entirely and the
    /// edge can only say one thing — and while a pulse is already running, so a
    /// burst of completions does not make the display hop.
    private func noteCompletions(since previous: [String: SessionState]) {
        guard completionPulseID == nil else { return }
        guard !allSessions.contains(where: { $0.state.isAlert }) else { return }
        let finished = allSessions.first { session in
            guard let was = previous[session.id] else { return false }
            return was != .done && session.state == .done
        }
        guard let finished else { return }
        beginCompletionPulse(finished.id)
    }

    private func beginCompletionPulse(_ id: String) {
        completionPulseID = id
        completionTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.completionPulseDuration, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCompletionPulse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    /// Ends the announcement. Called by the one-shot timer, and directly by the
    /// self-test so the checks do not have to sleep through the window.
    func endCompletionPulse() {
        completionTimer?.invalidate()
        completionTimer = nil
        completionPulseID = nil
    }
```

Extend `borderPulse` from Task 1 to return the completion case:

```swift
    var borderPulse: BorderPulse? {
        guard mode != .dormant else { return nil }
        if mode == .alert { return .attention }
        if let id = completionPulseID, displaySession?.id == id { return .completion }
        return nil
    }
```

Add the teardown to `setEnabled(_:)`, inside its existing `if !enabled {` block:

```swift
            endCompletionPulse()
```

And to `shutdown()`:

```swift
        endCompletionPulse()
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && ./.build/debug/ClaudeIslandApp --selftest 2>&1 | grep -E "pulse|done|passed|FAILED"`
Expected: `Build complete`, all five completion checks PASS, no FAILED line.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeIslandApp/IslandViewModel.swift Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "A completion is an instant, so catch the crossing not the state"
```

---

### Task 3: Let a finished session take the display, within limits

**Files:**
- Modify: `Sources/ClaudeIslandApp/IslandViewModel.swift` (`displaySession`, around line 93)
- Test: `Sources/ClaudeIslandApp/SelfTest.swift`

**Interfaces:**
- Consumes: `completionPulseID` and `endCompletionPulse()` from Task 2
- Produces: no new API — `displaySession` gains a second override.

- [ ] **Step 1: Write the failing checks**

In `SelfTest.swift`, add this function and call it from `run()` immediately after `completionPulseChecks(&checks, model: model)`:

```swift
        completionTakeoverChecks(&checks, model: model)
```

```swift
    /// The border wraps a pill that names one session, so a completion elsewhere
    /// has to bring its session with it or say nothing at all.
    private static func completionTakeoverChecks(_ checks: inout [Check], model: IslandViewModel) {
        func working(_ id: String) -> Session { session(id, state: .thinking) }
        func finished(_ id: String) -> Session { session(id, state: .done) }
        let prompt = PermissionAsk(
            toolName: "Write", kind: .write, target: "/tmp/x", since: Date())

        // Background session finishes: it takes the display and pulses.
        model.isHovered = false
        model.apply(HUDSnapshot(primary: working("alpha"), others: [working("beta")]))
        model.apply(HUDSnapshot(primary: working("alpha"), others: [finished("beta")]))
        checks.append(
            Check(
                name: "a finished background session takes the display",
                passed: model.displaySession?.id == "beta" && model.borderPulse == .completion,
                detail: "shown=\(model.displaySession?.id ?? "nil")"))

        model.endCompletionPulse()
        checks.append(
            Check(
                name: "the display returns when the pulse ends",
                passed: model.displaySession?.id == "alpha",
                detail: "shown=\(model.displaySession?.id ?? "nil")"))

        // Rule 1: a prompt is up, so no takeover at all.
        model.apply(
            HUDSnapshot(
                primary: session("alpha", state: .awaitingPermission(prompt)),
                others: [working("beta")]))
        model.apply(
            HUDSnapshot(
                primary: session("alpha", state: .awaitingPermission(prompt)),
                others: [finished("beta")]))
        checks.append(
            Check(
                name: "a prompt is never displaced by a completion",
                passed: model.displaySession?.id == "alpha" && model.borderPulse == .attention,
                detail:
                    "shown=\(model.displaySession?.id ?? "nil") pulse=\(String(describing: model.borderPulse))"
            ))
        model.endCompletionPulse()

        // Rule 2: hovering holds the display where it is.
        model.apply(HUDSnapshot(primary: working("alpha"), others: [working("beta")]))
        model.isHovered = true
        model.apply(HUDSnapshot(primary: working("alpha"), others: [finished("beta")]))
        checks.append(
            Check(
                name: "hovering holds the display through a completion",
                passed: model.displaySession?.id == "alpha" && model.borderPulse == nil,
                detail: "shown=\(model.displaySession?.id ?? "nil")"))
        model.isHovered = false
        model.endCompletionPulse()

        // Rule 3: the finished session is already shown — pulses in place.
        model.apply(HUDSnapshot(primary: working("alpha"), others: []))
        model.apply(HUDSnapshot(primary: finished("alpha"), others: []))
        checks.append(
            Check(
                name: "a finished session already shown pulses in place",
                passed: model.displaySession?.id == "alpha" && model.borderPulse == .completion,
                detail: "shown=\(model.displaySession?.id ?? "nil")"))
        model.endCompletionPulse()

        // Rule 4: only the first of a burst takes the display.
        model.apply(
            HUDSnapshot(primary: working("alpha"), others: [working("beta"), working("gamma")]))
        model.apply(
            HUDSnapshot(primary: working("alpha"), others: [finished("beta"), working("gamma")]))
        let firstTaker = model.displaySession?.id
        model.apply(
            HUDSnapshot(primary: working("alpha"), others: [finished("beta"), finished("gamma")]))
        checks.append(
            Check(
                name: "a second completion does not steal the display",
                passed: firstTaker == "beta" && model.displaySession?.id == "beta",
                detail: "first=\(firstTaker ?? "nil") now=\(model.displaySession?.id ?? "nil")"))

        model.endCompletionPulse()
        model.apply(HUDSnapshot())
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && ./.build/debug/ClaudeIslandApp --selftest 2>&1 | grep -E "takes the display|FAILED"`
Expected: `a finished background session takes the display` FAILS with `shown=alpha`.

- [ ] **Step 3: Add the override**

In `IslandViewModel.swift`, replace `displaySession` with:

```swift
    /// The session whose details are on screen.
    ///
    /// A permission prompt always takes over, even from an explicit selection —
    /// missing one is worse than losing your place. The selection is kept, not
    /// cleared, so the view returns to it once the prompt is answered.
    ///
    /// A session announcing its completion takes over too, but only briefly and
    /// only if you are not already reading something: hover and pin both hold
    /// the display where it is, because losing your place mid-read costs more
    /// than a completion notice is worth.
    var displaySession: Session? {
        if let alerting = allSessions.first(where: { $0.state.isAlert }) { return alerting }
        if let id = completionPulseID, !isHovered, !isPinnedOpen,
            let finished = allSessions.first(where: { $0.id == id })
        {
            return finished
        }
        if let id = selectedSessionID,
            let selected = allSessions.first(where: { $0.id == id })
        {
            return selected
        }
        return snapshot.primary
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && ./.build/debug/ClaudeIslandApp --selftest 2>&1 | grep -E "display|completion|passed|FAILED"`
Expected: `Build complete`, all six takeover checks PASS, no FAILED line.

- [ ] **Step 5: Confirm nothing else regressed**

Run: `./.build/debug/ClaudeIslandApp --selftest 2>&1 | tail -3 && swift run ClaudeIslandTests 2>&1 | tail -2`
Expected: no FAILED line; the headless suite still passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeIslandApp/IslandViewModel.swift Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "Let a finished session bring its own name with it"
```

---

### Task 4: Rework `PulsingOutline` into base + sweep, and make the yellow travel

**Files:**
- Modify: `Sources/ClaudeIslandApp/CoreAnimationViews.swift` (`PulsingOutline`)
- Modify: `Sources/ClaudeIslandApp/IslandView.swift` (the `.overlay` mount)

**Interfaces:**
- Consumes: `BorderPulse` (Task 1), `PulsingOutline.layerPath(in:cornerRadius:topFlare:)` (already present)
- Produces: `PulsingOutline(pulse:cornerRadius:topFlare:)`. Task 5 adds the completion branch to the same type.

**Note:** `layerPath` already applies the y-flip that keeps the flares against the screen edge, and the check `the outline's flares meet the screen edge` guards it. Do not remove either.

- [ ] **Step 1: Replace the animation section of `PulsingOutline`**

Keep `layerPath`, `hitTest`, the `layout()`-not-`updateNSView` rule and the stroked `shadowPath`. Replace the type's stored properties, the `OutlineView` layers, `applyPulse`, and the animation constants with:

```swift
struct PulsingOutline: NSViewRepresentable {
    let pulse: BorderPulse
    var cornerRadius: CGFloat
    var topFlare: CGFloat

    /// One yellow cycle. Matches the `PulsingGlyph` breath in `AlertContent` so
    /// the edge and the raised hand do not beat against each other.
    static let attentionCycle: CFTimeInterval = 1.7
    fileprivate static let lineWidth: CGFloat = 1.5

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

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for layer in [base, sweep] {
                layer.fillColor = nil
                layer.lineWidth = PulsingOutline.lineWidth
                layer.lineCap = .round
            }
            base.shadowOffset = .zero
            self.layer?.addSublayer(base)
            self.layer?.addSublayer(sweep)
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
                in: bounds, cornerRadius: cornerRadius, topFlare: topFlare)
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
            CATransaction.commit()

            apply()
        }

        func apply() {
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for key in PulsingOutline.animationKeys { sweep.removeAnimation(forKey: key) }

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

    static func layerPath(in rect: CGRect, cornerRadius: CGFloat, topFlare: CGFloat) -> CGPath {
        let authored = IslandOutline(cornerRadius: cornerRadius, topFlare: topFlare)
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
        view.needsLayout = true
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: OutlineView,
        context: NSViewRepresentableContext<Self>
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
```

Keep the existing doc comment above `struct PulsingOutline`, but replace its second paragraph so it describes travelling pulses rather than a breath.

- [ ] **Step 2: Update the mount to pass the pulse**

In `IslandView.swift`, replace the overlay body with:

```swift
        .overlay {
            if let pulse = model.borderPulse {
                PulsingOutline(
                    pulse: pulse,
                    cornerRadius: model.cornerRadius, topFlare: model.topFlare
                )
                .transition(.opacity)
            }
        }
```

- [ ] **Step 3: Build (expect one error — the blue is added in Task 5)**

Run: `swift build 2>&1 | grep -E "error:|Build complete"`
Expected: FAIL with `type 'IslandPalette' has no member 'completionPulse'`. That is the seam Task 5 fills; do not add it here.

- [ ] **Step 4: Add the blue constant so the build passes**

In `IslandView.swift`, in the `IslandPalette` enum next to `alertStill`:

```swift
    /// A finished session's one blue pulse. `running` is blue too, but the two
    /// never meet: a running session draws no border at all, so blue on the edge
    /// can only mean finished.
    static let completionPulse = Color(red: 0.349, green: 0.678, blue: 1.0)
```

- [ ] **Step 5: Run the build and the full self-test**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && ./.build/debug/ClaudeIslandApp --selftest 2>&1 | tail -3`
Expected: `Build complete`; no FAILED line; `the outline's flares meet the screen edge` still passes.

- [ ] **Step 6: Confirm on screen**

The running HUD holds the socket, so use its own hook client rather than launching a second one — `SocketServer.start` unlinks before it binds and a second HUD silently steals the socket.

```bash
N=dist/ClaudeIsland.app/Contents/MacOS/claude-island-notify
printf '%s' '{"session_id":"pulse-check","hook_event_name":"SessionStart","cwd":"/tmp/pulse-check"}' | $N
sleep 0.4
printf '%s' '{"session_id":"pulse-check","hook_event_name":"PermissionRequest","cwd":"/tmp/pulse-check","tool_name":"Bash","tool_input":{"command":"make release"}}' | $N
sleep 0.8
screencapture -x -R 600,0,600,95 /tmp/yellow.png
```

Rebuild `dist` first with `./Scripts/bundle.sh` if the bundle predates this task. Confirm in `/tmp/yellow.png`: the edge is lit all the way round, brighter near the bottom centre early in a cycle, and the flares meet the screen edge rather than hanging off the bottom. Then end it:

```bash
printf '%s' '{"session_id":"pulse-check","hook_event_name":"SessionEnd","cwd":"/tmp/pulse-check"}' | $N
```

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeIslandApp/CoreAnimationViews.swift Sources/ClaudeIslandApp/IslandView.swift
git commit -m "Send the light out from the centre instead of breathing it"
```

---

### Task 5: Confirm the blue pulse renders, once, and leaves nothing behind

**Files:**
- Test: `Sources/ClaudeIslandApp/SelfTest.swift`

**Interfaces:**
- Consumes: everything from Tasks 1-4. No new production API.

This task adds no production code. Task 4's `apply()` already branches on `.completion`; what is unverified is that the two durations agree and that the layer really is torn down.

- [ ] **Step 1: Write the failing check**

The one thing that can silently drift is the pair of durations. Add to `SelfTest.swift`, called from `run()` after `completionTakeoverChecks(&checks, model: model)`:

```swift
        checks.append(
            Check(
                name: "the blue layer's window matches the model's",
                passed: PulsingOutline.completionWindow
                    == IslandViewModel.completionPulseDuration,
                detail:
                    "layer=\(PulsingOutline.completionWindow) model=\(IslandViewModel.completionPulseDuration)"
            ))
```

- [ ] **Step 2: Run it**

Run: `swift build 2>&1 | grep -E "error:|Build complete" && ./.build/debug/ClaudeIslandApp --selftest 2>&1 | grep -E "window matches|FAILED"`
Expected: PASS. If it fails, the two constants have drifted — fix the constants, not the check.

- [ ] **Step 3: Confirm the blue on screen**

With `dist` rebuilt via `./Scripts/bundle.sh`:

```bash
N=dist/ClaudeIsland.app/Contents/MacOS/claude-island-notify
printf '%s' '{"session_id":"blue-check","hook_event_name":"SessionStart","cwd":"/tmp/blue-check"}' | $N
sleep 0.4
printf '%s' '{"session_id":"blue-check","hook_event_name":"PreToolUse","cwd":"/tmp/blue-check","tool_name":"Bash","tool_input":{"command":"swift build"}}' | $N
sleep 0.5
printf '%s' '{"session_id":"blue-check","hook_event_name":"Stop","cwd":"/tmp/blue-check"}' | $N
for i in 1 2 3 4; do screencapture -x -R 600,0,600,95 /tmp/blue$i.png; sleep 0.5; done
```

Confirm across the four frames: the blue segment grows from the bottom centre outward, then fades; and by the last frame **no border remains** — a finished session must leave nothing behind. Then:

```bash
printf '%s' '{"session_id":"blue-check","hook_event_name":"SessionEnd","cwd":"/tmp/blue-check"}' | $N
```

`Stop` is the right event: `Session.apply` sets `.done` for it at `Session.swift:208-211`.
`SessionEnd` also sets `.done`, but the session is already `done` by then, so the
crossing test fails and it correctly does not fire a second pulse.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "Tie the blue layer's window to the model's"
```

---

### Task 6: Close the two carried-over verification gaps

**Files:**
- Modify: `docs/superpowers/specs/2026-08-09-attention-pulse-design.md` (the "Carried over, still unverified" section)

**Interfaces:**
- Consumes: the finished feature. No new API.

Both gaps predate this work and both live in areas it reworks, so they close here.

- [ ] **Step 1: Confirm the click-through fix**

`PulsingOutline` returns nil from `hitTest(_:)` so it cannot swallow the click that pins the card open. This has never been exercised with the overlay actually mounted. With a prompt up (use the Task 4 recipe), click the island once and confirm the expanded card opens; click again and confirm it closes.

This moves the cursor. Ask the user before doing it, and put the cursor back.

- [ ] **Step 2: Confirm Reduce Motion**

```bash
defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo "unset (off)"
```

Ask the user before changing a system setting. With their agreement, enable Reduce Motion in System Settings > Accessibility > Display, raise a prompt, and confirm: the edge is a static amber ring with a steady halo and **no sweep**; then let a session finish and confirm the blue edge appears and fades without travelling. Put the setting back exactly as it was.

If the user declines either step, say so plainly in the spec rather than marking it done.

- [ ] **Step 3: Record the outcome**

Replace the "Carried over, still unverified" section of the spec with what was actually observed — or with what remains unverified and why. Do not describe an unverified path as confirmed.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-08-09-attention-pulse-design.md
git commit -m "Record what the pulses actually do under Reduce Motion"
```

---

## Self-Review

**Spec coverage.** Every section maps to a task: the two treatments and the state table (Tasks 1-2), grow-and-fill via `strokeStart`/`strokeEnd` (Task 4), the two layers and the dropped breathing halo (Task 4), yellow's 1.7s cycle and never-dark trough (Task 4), blue's 1.8s window (Tasks 2, 4, 5), transition-not-state (Task 2), all four suppression rules (Tasks 2-3), colours (Task 4), Reduce Motion (Tasks 4, 6), idle CPU (Task 2's timer teardown), and the carried-over gaps (Task 6).

**Known gap, stated rather than hidden.** The travelling motion itself has no automated check — `SelfTest` works at view-model level and cannot read `CALayer` state, which is why the seam is a model predicate. Task 4 Step 6 and Task 5 Step 3 are screenshot confirmations, and they are the only evidence that the sweep travels. That is a real limit of this harness, not an oversight.

**Type consistency.** `BorderPulse` is `.attention`/`.completion` throughout. `completionPulseID`, `endCompletionPulse()`, `completionPulseDuration` and `PulsingOutline.completionWindow` are spelled identically in every task, and Task 5 asserts the last two agree. `layerPath` keeps its existing signature.
