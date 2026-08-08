import AppKit
import ClaudeIslandCore
import SwiftUI

/// Exercises the two behavioural requirements that cannot be unit-tested: the
/// panel must never steal focus, and clicks outside the drawn shape must pass
/// through to whatever is underneath.
///
/// Click-through is checked against the window server itself via
/// `NSWindow.windowNumber(at:)`, which reports where a click would actually be
/// delivered — not merely what our own flags claim.
@MainActor
enum SelfTest {
    private enum Outcome {
        case pass
        case fail
        /// The check could not be evaluated in this environment. Reported as
        /// such rather than counted either way — a check that cannot run must
        /// never masquerade as one that passed.
        case skipped(String)
    }

    private struct Check {
        let name: String
        let outcome: Outcome
        let detail: String

        init(name: String, passed: Bool, detail: String) {
            self.name = name
            self.outcome = passed ? .pass : .fail
            self.detail = detail
        }

        init(name: String, skipped reason: String, detail: String = "") {
            self.name = name
            self.outcome = .skipped(reason)
            self.detail = detail
        }
    }

    /// True when something is covering the whole screen — a lock screen, a
    /// screen saver, or a full-screen capture overlay. While one is up the
    /// window server reports it as the hit for every point, so click-through
    /// cannot be measured.
    private static func screenObstruction() -> String? {
        guard let screen = NSScreen.screens.first else { return nil }
        // A point in the far corner, where nothing of ours is drawn.
        let empty = CGPoint(x: screen.frame.maxX - 4, y: screen.frame.minY + 4)
        let hit = NSWindow.windowNumber(at: empty, belowWindowWithWindowNumber: 0)
        guard hit != 0,
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in list where (window[kCGWindowNumber as String] as? Int) == hit {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? "unknown"
            let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
            // Our own panel sits at layer 26; anything far above is an overlay.
            if layer > 100 {
                return "\(owner) is covering the screen (layer \(layer)) — is it locked?"
            }
        }
        return nil
    }

    static func run() async -> Int32 {
        var checks: [Check] = []

        let frontmostBefore = NSWorkspace.shared.frontmostApplication

        NSApp.setActivationPolicy(.accessory)

        guard let geometry = NotchGeometryResolver.current() else {
            print("no screens available")
            return 1
        }

        let panel = IslandPanel(contentRect: geometry.panelRect)
        let model = IslandViewModel()
        model.setGeometry(geometry)
        let host = NSHostingViewShim(model: model, size: geometry.panelRect.size)
        panel.contentView = host
        panel.orderFrontRegardless()

        // Give AppKit a runloop turn to actually put the window on screen.
        await tick(0.3)

        // --- Focus ---

        checks.append(
            Check(
                name: "panel refuses key",
                passed: !panel.canBecomeKey,
                detail: "canBecomeKey=\(panel.canBecomeKey)"))
        checks.append(
            Check(
                name: "panel refuses main",
                passed: !panel.canBecomeMain,
                detail: "canBecomeMain=\(panel.canBecomeMain)"))
        checks.append(
            Check(
                name: "panel is non-activating",
                passed: panel.styleMask.contains(.nonactivatingPanel),
                detail: "styleMask=\(panel.styleMask.rawValue)"))
        checks.append(
            Check(
                name: "panel is above the menu bar",
                passed: panel.level.rawValue > NSWindow.Level.statusBar.rawValue,
                detail:
                    "level=\(panel.level.rawValue) statusBar=\(NSWindow.Level.statusBar.rawValue)"))
        checks.append(
            Check(
                name: "collection behavior spans spaces and full screen",
                passed: panel.collectionBehavior.contains(.canJoinAllSpaces)
                    && panel.collectionBehavior.contains(.fullScreenAuxiliary)
                    && panel.collectionBehavior.contains(.stationary)
                    && panel.collectionBehavior.contains(.ignoresCycle),
                detail: "\(panel.collectionBehavior.rawValue)"))
        checks.append(
            Check(
                name: "ordering the panel front did not activate the app",
                passed: !NSApp.isActive,
                detail: "NSApp.isActive=\(NSApp.isActive)"))

        let frontmostAfter = NSWorkspace.shared.frontmostApplication
        checks.append(
            Check(
                name: "frontmost app unchanged",
                passed: frontmostBefore?.bundleIdentifier == frontmostAfter?.bundleIdentifier,
                detail:
                    "\(frontmostBefore?.localizedName ?? "none") -> \(frontmostAfter?.localizedName ?? "none")"
            ))
        checks.append(
            Check(
                name: "panel is not the key window",
                passed: NSApp.keyWindow == nil,
                detail: "keyWindow=\(NSApp.keyWindow?.description ?? "nil")"))

        // --- Click-through ---
        //
        // Asks the window server where a click would actually land, rather than
        // inferring it from our own flags. This is the authoritative test and
        // needs no Accessibility permission.

        model.apply(activeSnapshot())
        await tick(0.35)
        let shape = model.interactiveScreenRect
        let overShape = CGPoint(x: shape.midX, y: shape.midY)
        let overTransparent = CGPoint(
            x: geometry.panelRect.minX + 8, y: geometry.panelRect.minY + 8)

        checks.append(
            Check(
                name: "probe point is inside the panel but outside the shape",
                passed: geometry.panelRect.contains(overTransparent)
                    && !shape.contains(overTransparent),
                detail: "\(overTransparent) panel=\(geometry.panelRect) shape=\(shape)"))

        checks.append(
            Check(
                name: "panel starts fully click-through",
                passed: panel.ignoresMouseEvents,
                detail: "ignoresMouseEvents=\(panel.ignoresMouseEvents)"))
        if let obstruction = screenObstruction() {
            for name in [
                "while ignoring events, clicks over the shape pass through",
                "with events enabled, the shape receives clicks",
                "transparent panel area passes clicks through per-pixel",
            ] {
                checks.append(Check(name: name, skipped: obstruction))
            }
        } else {
            checks.append(
                Check(
                    name: "while ignoring events, clicks over the shape pass through",
                    passed: windowNumber(at: overShape) != panel.windowNumber,
                    detail: "hit=\(windowNumber(at: overShape)) ours=\(panel.windowNumber)"))

            // Now accept events and re-ask the window server.
            panel.ignoresMouseEvents = false
            await tick(0.35)

            let ourLevel = panel.level.rawValue
            if let conflict = occluder(
                at: overShape, ourLevel: ourLevel, ourWindow: panel.windowNumber)
            {
                checks.append(
                    Check(name: "with events enabled, the shape receives clicks", skipped: conflict)
                )
            } else {
                checks.append(
                    Check(
                        name: "with events enabled, the shape receives clicks",
                        passed: windowNumber(at: overShape) == panel.windowNumber,
                        detail: "hit=\(windowNumber(at: overShape)) ours=\(panel.windowNumber)"))
            }

            // macOS hit-tests a window by its frame rect, not per-pixel alpha:
            // measured directly, a fully transparent region of a non-opaque
            // panel still claims the click. That is exactly why HoverMonitor
            // has to gate ignoresMouseEvents — without it this panel would
            // swallow every click in its 420x260 frame.
            checks.append(
                Check(
                    name: "frame-rect hit testing confirmed (so the monitor is required)",
                    passed: windowNumber(at: overTransparent) == panel.windowNumber,
                    detail:
                        "hit=\(windowNumber(at: overTransparent)) ours=\(panel.windowNumber)"))
        }

        panel.ignoresMouseEvents = true

        // --- Hover monitor ---

        let monitor = HoverMonitor(panel: panel)
        monitor.start()
        checks.append(
            Check(
                name: "hover monitor installs",
                passed: monitor.isRunning,
                detail: "running=\(monitor.isRunning)"))

        // Drive containment directly. A synthetic cursor warp does not generate
        // the mouseMoved event a global monitor observes, so probing the real
        // event path from a headless run is not possible; this exercises the
        // same evaluation the monitor performs on each move.
        monitor.setInteractiveRectForTesting(shape, cursorAt: overShape)
        await tick(0.3)
        checks.append(
            Check(
                name: "cursor inside the shape enables mouse events",
                passed: !panel.ignoresMouseEvents,
                detail: "ignoresMouseEvents=\(panel.ignoresMouseEvents) shape=\(shape)"))

        monitor.setInteractiveRectForTesting(shape, cursorAt: overTransparent)
        // ignoresMouseEvents reaches the window server on the next runloop
        // turn, so the flag and the server's view of it disagree until we pump.
        await tick(0.3)
        checks.append(
            Check(
                name: "cursor outside the shape restores click-through",
                passed: panel.ignoresMouseEvents,
                detail: "ignoresMouseEvents=\(panel.ignoresMouseEvents)"))
        checks.append(
            Check(
                name: "with the monitor gating, the transparent area passes through",
                passed: windowNumber(at: overTransparent) != panel.windowNumber,
                detail:
                    "hit=\(windowNumber(at: overTransparent)) ours=\(panel.windowNumber)"))

        monitor.stop()
        checks.append(
            Check(
                name: "stopping the monitor restores full click-through",
                passed: panel.ignoresMouseEvents && !monitor.isRunning,
                detail: "running=\(monitor.isRunning)"))

        // --- Pinning ---

        model.apply(activeSnapshot())
        await expandCheck(&checks, model: model, panel: panel)

        // --- Idle ---

        model.apply(HUDSnapshot())
        checks.append(
            Check(
                name: "no active session means no animation is requested",
                passed: !HUDSnapshot().wantsAnimation && model.mode == .dormant,
                detail: "mode=\(model.mode)"))

        panel.orderOut(nil)

        // --- Report ---

        print("ClaudeIsland self-test\n")
        var failures = 0
        var skipped = 0
        for check in checks {
            switch check.outcome {
            case .pass:
                print("  ✓ \(check.name)")
            case .fail:
                failures += 1
                print("  ✗ \(check.name)")
                print("      \(check.detail)")
            case .skipped(let reason):
                skipped += 1
                print("  — \(check.name)")
                print("      SKIPPED: \(reason)")
            }
        }
        print("")
        let passed = checks.count - failures - skipped
        if failures == 0 {
            print("\(passed) checks passed\(skipped > 0 ? ", \(skipped) skipped" : "")")
            if skipped > 0 {
                print("Skipped checks could not be evaluated here — see the reason on each.")
            }
            return skipped > 0 ? 2 : 0
        }
        print("\(failures) of \(checks.count) checks FAILED (\(passed) passed, \(skipped) skipped)")
        return 1
    }

    /// Click-to-pin, checked at the model level. Delivering a synthetic click
    /// needs Accessibility permission, so the gesture itself is confirmed by
    /// hand; this pins down everything the gesture drives.
    private static func expandCheck(
        _ checks: inout [Check], model: IslandViewModel, panel: IslandPanel
    ) async {
        model.isHovered = false
        checks.append(
            Check(
                name: "unhovered and unpinned shows the compact pill",
                passed: model.mode == .compact && !model.isPinnedOpen,
                detail: "mode=\(model.mode) pinned=\(model.isPinnedOpen)"))

        model.isHovered = true
        checks.append(
            Check(
                name: "hovering peeks rather than fully expanding",
                passed: model.mode == .peek,
                detail: "mode=\(model.mode)"))
        model.isHovered = false

        let compactRect = model.interactiveScreenRect
        model.togglePinned()
        checks.append(
            Check(
                name: "clicking pins the card open",
                passed: model.mode == .expanded && model.isPinnedOpen,
                detail: "mode=\(model.mode) pinned=\(model.isPinnedOpen)"))
        checks.append(
            Check(
                name: "the pinned card stays open with the cursor away",
                passed: !model.isHovered && model.mode == .expanded,
                detail: "hovered=\(model.isHovered) mode=\(model.mode)"))
        checks.append(
            Check(
                name: "the hit region grows with the pinned card",
                passed: model.interactiveScreenRect.height > compactRect.height,
                detail: "pinned=\(model.interactiveScreenRect) compact=\(compactRect)"))

        model.togglePinned()
        checks.append(
            Check(
                name: "clicking again unpins",
                passed: model.mode == .compact && !model.isPinnedOpen,
                detail: "mode=\(model.mode)"))

        model.togglePinned()
        model.unpin()
        checks.append(
            Check(
                name: "a click outside dismisses the pinned card",
                passed: !model.isPinnedOpen && model.mode == .compact,
                detail: "mode=\(model.mode)"))

        model.togglePinned()
        model.apply(HUDSnapshot())
        checks.append(
            Check(
                name: "the last session ending clears the pin",
                passed: !model.isPinnedOpen && model.mode == .dormant,
                detail: "pinned=\(model.isPinnedOpen) mode=\(model.mode)"))

        checks.append(
            Check(
                name: "the panel still refuses key after the tap gesture exists",
                passed: !panel.canBecomeKey && !NSApp.isActive,
                detail: "canBecomeKey=\(panel.canBecomeKey) active=\(NSApp.isActive)"))

        await restingLineChecks(&checks, model: model)
        attentionBorderChecks(&checks, model: model)
        completionPulseChecks(&checks, model: model)
        completionTakeoverChecks(&checks, model: model)
        outlineGeometryChecks(&checks)
        await switcherChecks(&checks, model: model)
    }

    /// The edge belongs to a permission prompt, and only a permission prompt.
    ///
    /// `SelfTest` works at view-model level and cannot inspect `CALayer` state,
    /// so the seam is the predicate the view mounts `PulsingOutline` on. The
    /// negative cases are the point: the idle nudge stays dark because it is a
    /// nudge, not a block — Claude isn't stopped waiting on an answer, you
    /// just haven't typed yet — and thinking, a failure and a dormant HUD stay
    /// dark because none of them is Claude waiting on you either.
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

        // Another snapshot arrives mid-window. The pulse is a fixed span of
        // time, so it neither restarts nor is cut short by unrelated traffic.
        model.apply(HUDSnapshot(primary: session("s", state: .done), others: []))
        checks.append(
            Check(
                name: "the pulse rides out its window across snapshots",
                passed: model.borderPulse == .completion,
                detail: "pulse=\(String(describing: model.borderPulse))"))

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

    /// Every tracked session rests as one line, including the two states you are
    /// most likely to be waiting on.
    private static func restingLineChecks(_ checks: inout [Check], model: IslandViewModel) async {
        model.isHovered = false
        let compactHeight = { () -> CGFloat in
            model.apply(HUDSnapshot(primary: session("s", state: .thinking), others: []))
            return model.shapeSize.height
        }()

        for (label, state) in [
            ("thinking", SessionState.thinking),
            ("waiting (idle nudge)", SessionState.idle(waitingOnUser: true)),
            ("done", SessionState.done),
            ("failed", SessionState.error("Bash failed")),
        ] {
            model.apply(HUDSnapshot(primary: session("s", state: state), others: []))
            checks.append(
                Check(
                    name: "\(label) rests as a single line",
                    passed: model.mode == .compact
                        && abs(model.shapeSize.height - compactHeight) < 0.5,
                    detail: "mode=\(model.mode) height=\(model.shapeSize.height)"))
        }

        // A permission prompt is styled differently but must be the same height.
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
                name: "your turn (permission) rests as a single line",
                passed: model.mode == .alert
                    && abs(model.shapeSize.height - compactHeight) < 0.5,
                detail: "mode=\(model.mode) height=\(model.shapeSize.height) vs \(compactHeight)"
            ))

        checks.append(
            Check(
                name: "only a session-free HUD goes dormant",
                passed: { model.apply(HUDSnapshot()); return model.mode == .dormant }(),
                detail: "mode=\(model.mode)"))
    }

    /// The attention border's path must not be drawn on its head.
    ///
    /// `IslandOutline` is a SwiftUI `Shape`, so it is authored y-down: the
    /// concave flares curve out of `minY`, which is the screen edge. A CALayer
    /// inside an unflipped `NSView` is y-up — `StatusMark`'s checkmark in the
    /// same file only reads as a tick because of it — so handing that path
    /// straight to the layer inverts the whole silhouette.
    ///
    /// Which is worth a check rather than an eyeball, because the island is very
    /// nearly symmetric about its waist: inverted, it still looks like a lit
    /// island with a glow, and the tell is only that the flares hang off the
    /// bottom instead of meeting the screen edge.
    private static func outlineGeometryChecks(_ checks: inout [Check]) {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 38)
        let flare: CGFloat = 11
        let path = PulsingOutline.layerPath(in: rect, cornerRadius: 18, topFlare: flare)

        // The path opens at the left flare's tip, which is the one point that is
        // both outside the frame and level with the screen edge.
        var start: CGPoint?
        path.applyWithBlock { element in
            guard element.pointee.type == .moveToPoint, start == nil else { return }
            start = element.pointee.points[0]
        }

        checks.append(
            Check(
                name: "the outline's flares meet the screen edge",
                passed: start.map { $0.x < rect.minX && $0.y > rect.midY } ?? false,
                detail: "opens at \(start.map(String.init(describing:)) ?? "nothing") "
                    + "— want x < \(rect.minX) and y > \(rect.midY) in \(rect)"))
    }

    /// The session switcher, including the rule that a permission prompt takes
    /// over from an explicit selection but does not discard it.
    private static func switcherChecks(_ checks: inout [Check], model: IslandViewModel) async {
        model.apply(twoSessionSnapshot(alerting: false))
        checks.append(
            Check(
                name: "the switcher lists every active session",
                passed: model.allSessions.count == 2,
                detail: "\(model.allSessions.map(\.id))"))
        checks.append(
            Check(
                name: "with no selection the ranked primary is shown",
                passed: model.displaySession?.id == "alpha",
                detail: "shown=\(model.displaySession?.id ?? "nil")"))

        model.select("beta")
        checks.append(
            Check(
                name: "selecting a session switches the detail to it",
                passed: model.displaySession?.id == "beta",
                detail: "shown=\(model.displaySession?.id ?? "nil")"))

        // Alpha raises a permission prompt while beta is selected.
        model.apply(twoSessionSnapshot(alerting: true))
        checks.append(
            Check(
                name: "a permission prompt takes over from the selection",
                passed: model.displaySession?.id == "alpha",
                detail: "shown=\(model.displaySession?.id ?? "nil")"))
        checks.append(
            Check(
                name: "the takeover is signalled rather than silent",
                passed: model.isOverriddenByAlert,
                detail: "overridden=\(model.isOverriddenByAlert)"))

        // Prompt answered: the selection was kept, so we go back to it.
        model.apply(twoSessionSnapshot(alerting: false))
        checks.append(
            Check(
                name: "the selection resumes once the prompt is answered",
                passed: model.displaySession?.id == "beta",
                detail: "shown=\(model.displaySession?.id ?? "nil")"))

        model.select("beta")
        checks.append(
            Check(
                name: "selecting the shown session again clears the selection",
                passed: model.selectedSessionID == nil && model.displaySession?.id == "alpha",
                detail: "selected=\(model.selectedSessionID ?? "nil")"))

        model.select("beta")
        model.apply(HUDSnapshot(primary: session("alpha", state: .thinking), others: []))
        checks.append(
            Check(
                name: "a selection whose session ended is dropped",
                passed: model.selectedSessionID == nil,
                detail: "selected=\(model.selectedSessionID ?? "nil")"))

        await stableSizeChecks(&checks, model: model)
    }

    /// Browsing the switcher must not resize the card.
    ///
    /// It used to: the card was measured from the *selected* session, so its
    /// width followed that session's name length and its height followed that
    /// session's tool count. Every click reflowed the whole HUD.
    private static func stableSizeChecks(_ checks: inout [Check], model: IslandViewModel) async {
        var short = session("s", state: .thinking)
        short.cwd = "/tmp/ui"

        var long = session("l", state: .done)
        long.cwd = "/tmp/a-considerably-longer-worktree-name"
        long.recentTools = (0..<3).map {
            ToolActivity(
                kind: .bash, toolName: "Bash", target: "step \($0)", startedAt: Date(),
                endedAt: Date())
        }
        long.tasks = TaskProgress(items: [
            TaskItem(id: "1", subject: "first", status: .completed),
            TaskItem(id: "2", subject: "second", status: .inProgress),
        ])

        model.apply(HUDSnapshot(primary: short, others: [long]))
        model.forcedMode = .expanded

        model.select("s")
        let sizeWithShort = model.shapeSize
        model.select("l")
        let sizeWithLong = model.shapeSize

        checks.append(
            Check(
                name: "switcher width does not change when browsing sessions",
                passed: abs(sizeWithShort.width - sizeWithLong.width) < 0.5,
                detail: "\(sizeWithShort.width) vs \(sizeWithLong.width)"))
        checks.append(
            Check(
                name: "switcher height does not change when browsing sessions",
                passed: abs(sizeWithShort.height - sizeWithLong.height) < 0.5,
                detail: "\(sizeWithShort.height) vs \(sizeWithLong.height)"))
        checks.append(
            Check(
                name: "the card is sized for the widest session, not the shown one",
                passed: sizeWithShort.width
                    >= model.notchGap + 2 * model.leftClusterWidth(for: long),
                detail: "width=\(sizeWithShort.width)"))

        model.forcedMode = nil
        model.apply(HUDSnapshot())

        await cardFitChecks(&checks, model: model)
    }

    /// The card must never be drawn shorter than its own contents.
    ///
    /// It was. `expandedChromeHeight` was a single hand-tallied constant, it
    /// undercounted the real chrome, and `.clipShape` sliced the bottom of the
    /// recent list clean through — the card silently ate its own last row.
    ///
    /// Measuring the laid-out height is the only check that can catch that.
    /// Every arithmetic version of this check shares the bug's premise, which is
    /// precisely that someone tallied the blocks by hand and got it wrong.
    private static func cardFitChecks(_ checks: inout [Check], model: IslandViewModel) async {
        var busy = session(
            "busy",
            state: .running(
                ToolActivity(
                    kind: .bash, toolName: "Bash", target: "swift build", startedAt: Date())))
        busy.gitBranch = "main"
        busy.model = "claude-opus-5"
        busy.effort = "xhigh"
        busy.tokens.contextTokens = 131_100
        busy.tokens.cumulativeOutput = 37_900
        // One in flight plus a full trail, which is the tallest the body gets.
        busy.recentTools =
            [
                ToolActivity(
                    kind: .bash, toolName: "Bash", target: "swift build", startedAt: Date())
            ]
            + (0..<5).map {
                ToolActivity(
                    kind: .read, toolName: "Read", target: "Sources/Long/File\($0).swift",
                    startedAt: Date(), endedAt: Date())
            }
        busy.tasks = TaskProgress(items: [
            TaskItem(id: "1", subject: "first", status: .completed),
            TaskItem(id: "2", subject: "a reasonably long in-flight task", status: .inProgress),
        ])

        // Five sessions, so the switcher is full and the overflow line shows.
        let others = (0..<4).map { session("other\($0)", state: .thinking) }
        model.apply(HUDSnapshot(primary: busy, others: others))
        model.forcedMode = .expanded

        let size = model.shapeSize
        let host = NSHostingView(rootView: ExpandedContent(session: busy, model: model))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let needed = host.fittingSize.height

        checks.append(
            Check(
                name: "the expanded card is never shorter than its contents",
                passed: needed <= size.height + 0.5,
                detail: "content=\(needed) card=\(size.height)"))
        checks.append(
            Check(
                name: "the expanded card fits inside its panel",
                passed: size.height <= NotchGeometryResolver.panelHeight,
                detail: "card=\(size.height) panel=\(NotchGeometryResolver.panelHeight)"))
        checks.append(
            Check(
                name: "sessions beyond the switcher's rows are counted, not dropped",
                passed: model.sessionOverflowCount == 1,
                detail: "overflow=\(model.sessionOverflowCount) of \(model.allSessions.count)"))

        model.forcedMode = nil
        model.apply(HUDSnapshot())

        await branchFitChecks(&checks, model: model)
        await titleFitChecks(&checks, model: model)
    }

    /// A branch name is shown whole, and the card is what gives.
    ///
    /// Clamping it to 20 characters turned every branch under a shared prefix
    /// into the same string — `feature/attention-b…` for all of them — which is
    /// worse than showing no branch at all, because it looks like an answer.
    ///
    /// Laid out rather than computed: an arithmetic check would share the width
    /// calculation's premises, and those premises are what break.
    private static func branchFitChecks(_ checks: inout [Check], model: IslandViewModel) async {
        // Long enough to overrun the card's default width, which is the case
        // that used to lose characters and the only one worth asserting on.
        let long = "feature/attention-border-design-and-the-idle-nudge-that-follows-it"
        checks.append(
            Check(
                name: "the branch name is never abbreviated",
                passed: Format.branch(long) == long,
                detail: Format.branch(long) ?? "nil"))

        // Started hours ago, so the elapsed figure is as wide as it realistically
        // gets — a fresh session would leave slack the real card will not have.
        var branchy = Session(id: "branchy", startedAt: Date().addingTimeInterval(-3 * 3600))
        branchy.cwd = "/tmp/branchy"
        branchy.state = .thinking
        branchy.gitBranch = long
        branchy.model = "claude-opus-5"
        branchy.effort = "xhigh"

        model.apply(HUDSnapshot(primary: branchy))

        for mode in [IslandMode.peek, .expanded] {
            model.forcedMode = mode
            let available = model.shapeSize.width - 2 * IslandViewModel.sidePadding
            let host = NSHostingView(rootView: MetaLine(session: branchy, tick: Date()))
            host.frame = CGRect(origin: .zero, size: CGSize(width: available, height: 20))
            host.layoutSubtreeIfNeeded()
            let needed = host.fittingSize.width

            checks.append(
                Check(
                    name: "\(mode) is wide enough for a long branch",
                    passed: needed <= available + 0.5,
                    detail: "meta=\(needed) available=\(available)"))
        }

        model.forcedMode = nil
        model.apply(HUDSnapshot())
    }

    /// Each tier shortens the title differently, and each must fit what it
    /// shows.
    ///
    /// Three separate promises: the pill cuts on a word and wears no ellipsis,
    /// the shared header cuts at 25 and does, and whatever a tier ends up
    /// drawing, its flank is wide enough to draw it. The last one is laid out
    /// rather than computed — an arithmetic check would inherit the same
    /// premises as the width it is checking, and those premises are what break.
    /// It already caught the glyph size being tuned in two places out of three.
    private static func titleFitChecks(_ checks: inout [Check], model: IslandViewModel) async {
        let long = "Implement Claude session naming across the island"
        var titled = Session(id: "titled", startedAt: Date().addingTimeInterval(-3 * 3600))
        titled.cwd = "/tmp/titled"
        titled.state = .thinking
        titled.aiTitle = long

        let header = model.headerLeadingText(titled)
        checks.append(
            Check(
                name: "the header is bounded and says so",
                passed: header.count <= 25 && header.hasSuffix("\u{2026}")
                    && long.hasPrefix(header.dropLast()),
                detail: header))
        checks.append(
            Check(
                name: "the header shows more of the title than the pill",
                passed: header.count > model.compactLeadingText(titled).count,
                detail: "\(header) | vs | \(model.compactLeadingText(titled))"))

        // The pill does shorten, but it must not look broken doing it.
        let pill = model.compactLeadingText(titled)
        checks.append(
            Check(
                name: "the pill shortens without an ellipsis",
                passed: !pill.contains("\u{2026}") && !pill.hasSuffix(" "),
                detail: pill))
        checks.append(
            Check(
                name: "the pill cuts on a word, not mid-word",
                passed: long.hasPrefix(pill)
                    && (long.count == pill.count
                        || Array(long)[pill.count] == " "),
                detail: "\(pill) | of | \(long)"))
        // A single token long enough to overrun has no boundary to fall back
        // to, and must still be cut rather than left to widen the pill.
        var unbroken = Session(id: "unbroken", startedAt: Date())
        unbroken.aiTitle = String(repeating: "x", count: 40)
        checks.append(
            Check(
                name: "a title with no word break is still bounded",
                passed: model.compactLeadingText(unbroken).count == 18,
                detail: model.compactLeadingText(unbroken)))

        model.apply(HUDSnapshot(primary: titled))

        // The cutout is a physical feature the eye reads as a midpoint, so the
        // resting pill has to actually be centred on it — both flanks equal and
        // the shape drawn without an offset.
        model.forcedMode = .compact
        let leftFlank = model.flankLeftWidth ?? 0
        let rightFlank = model.flankRightWidth ?? 0
        checks.append(
            Check(
                name: "the resting pill is symmetric about the cutout",
                passed: abs(leftFlank - rightFlank) < 0.5 && model.shapeOffsetX == 0
                    && model.shapeSize.width >= model.notchGap + 2 * leftFlank - 0.5,
                detail:
                    "left=\(leftFlank) right=\(rightFlank) offset=\(model.shapeOffsetX) "
                    + "width=\(model.shapeSize.width) gap=\(model.notchGap)"))

        for mode in [IslandMode.peek, .expanded] {
            model.forcedMode = mode
            // Both open tiers split their width evenly across the cutout, so the
            // header's leading label gets one half less its own padding.
            let available =
                (model.shapeSize.width - model.notchGap) / 2
                - IslandViewModel.sidePadding - SessionGlyph.size - 8
                - IslandViewModel.notchPadding
            let host = NSHostingView(
                rootView: Text(model.headerLeadingText(titled))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1))
            host.frame = CGRect(origin: .zero, size: CGSize(width: available, height: 20))
            host.layoutSubtreeIfNeeded()
            let needed = host.fittingSize.width

            checks.append(
                Check(
                    name: "\(mode) is wide enough for a long title",
                    passed: needed <= available + 0.5,
                    detail: "title=\(needed) available=\(available)"))
        }

        model.forcedMode = nil
        model.apply(HUDSnapshot())
    }

    private static func session(_ id: String, state: SessionState) -> Session {
        var s = Session(id: id, startedAt: Date())
        s.cwd = "/tmp/\(id)"
        s.state = state
        return s
    }

    private static func twoSessionSnapshot(alerting: Bool) -> HUDSnapshot {
        let alpha = session(
            "alpha",
            state: alerting
                ? .awaitingPermission(
                    PermissionAsk(toolName: "Write", kind: .write, target: "/tmp/x", since: Date()))
                : .thinking)
        return HUDSnapshot(primary: alpha, others: [session("beta", state: .thinking)])
    }

    private static func activeSnapshot() -> HUDSnapshot {
        var session = Session(id: "selftest", startedAt: Date())
        session.cwd = "/tmp/selftest"
        session.state = .running(
            ToolActivity(kind: .bash, toolName: "Bash", target: "swift build", startedAt: Date()))
        return HUDSnapshot(primary: session, others: [])
    }

    /// Which window the server would deliver a click at `point` to. This is the
    /// ground truth for click-through, and needs no special permission.
    private static func windowNumber(at point: CGPoint) -> Int {
        NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
    }

    /// Describes any window sitting above ours at `point`.
    ///
    /// Other notch HUDs exist, and some sit at window levels far above
    /// `.statusBar + 1`. When one covers the probe point the click-through
    /// measurement is about that app, not about us, so it is reported as a
    /// conflict rather than counted as a failure.
    private static func occluder(at point: CGPoint, ourLevel: Int, ourWindow: Int) -> String? {
        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard hit != 0, hit != ourWindow,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for window in list where (window[kCGWindowNumber as String] as? Int) == hit {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? "unknown"
            let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
            guard layer > ourLevel else { return nil }
            return "\(owner) is above us at layer \(layer) (we are \(ourLevel))"
        }
        return nil
    }

    private static func tick(_ seconds: TimeInterval) async {
        // Pump the runloop rather than just sleeping: the event monitors and
        // the window server both need turns for any of this to be real.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pumpRunLoop()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Non-async so `RunLoop.run` stays legal; the async caller only awaits
    /// around it.
    private static func pumpRunLoop() {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

/// Minimal host so the self-test does not depend on the full view tree.
@MainActor
private func NSHostingViewShim(model: IslandViewModel, size: CGSize) -> NSView {
    let view = NSHostingView(rootView: IslandView(model: model))
    view.frame = CGRect(origin: .zero, size: size)
    return view
}
