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

        // Built from the stored settings rather than from the defaults, so the
        // notch-HUD switch is measured as it is actually run. It matters for one
        // check: with the switch on, click-through is tested at the level the
        // user has chosen and passes against another notch app, where the
        // default level can only report the conflict and skip.
        let stored = IslandSettings.load()
        let panel = IslandPanel(
            contentRect: geometry.panelRect, aboveOtherNotchHUDs: stored.aboveOtherNotchHUDs)
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
        // The level arithmetic, asserted rather than trusted to a comment. The
        // off case is what every build before the switch shipped with, and the
        // on case has to clear screen-saver level or it buys nothing: that is
        // where the notch apps it exists to beat are sitting.
        checks.append(
            Check(
                name: "with the notch-HUD switch off, the level is the conservative one",
                passed: IslandPanel.level(aboveOtherNotchHUDs: false).rawValue
                    == NSWindow.Level.statusBar.rawValue + 1,
                detail: "off=\(IslandPanel.level(aboveOtherNotchHUDs: false).rawValue) "
                    + "statusBar=\(NSWindow.Level.statusBar.rawValue)"))
        checks.append(
            Check(
                name: "with the notch-HUD switch on, the level clears where notch apps sit",
                passed: IslandPanel.level(aboveOtherNotchHUDs: true).rawValue
                    > NSWindow.Level.screenSaver.rawValue,
                detail: "on=\(IslandPanel.level(aboveOtherNotchHUDs: true).rawValue) "
                    + "screenSaver=\(NSWindow.Level.screenSaver.rawValue)"))
        // Asserted against the policy function rather than against `panel`, whose
        // level now depends on the stored switch: a check that compared the two
        // would fail for anyone who had turned it on.
        checks.append(
            Check(
                name: "init honours the switch, and honours its absence",
                passed: IslandPanel(contentRect: geometry.panelRect, aboveOtherNotchHUDs: true)
                    .level == IslandPanel.level(aboveOtherNotchHUDs: true)
                    && IslandPanel(contentRect: geometry.panelRect).level
                        == IslandPanel.level(aboveOtherNotchHUDs: false),
                detail: "on="
                    + "\(IslandPanel(contentRect: geometry.panelRect, aboveOtherNotchHUDs: true).level.rawValue) "
                    + "omitted=\(IslandPanel(contentRect: geometry.panelRect).level.rawValue)"))
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

        // No open delay, which is what keeps every check below able to assert in
        // the same turn it moves the cursor. The dwell has a block of its own —
        // see `hoverDelayChecks` — and giving this monitor one would only make
        // these checks wait for a property they are not about.
        let monitor = HoverMonitor(panel: panel, openDelay: 0)
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

        // --- The hover open delay ---

        await hoverDelayChecks(
            &checks, panel: panel, shape: shape, inside: overShape, outside: overTransparent)

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

        // Registration silently failing is precisely the failure this feature
        // exists to prevent, and it would otherwise only surface on someone
        // else's reboot. Prior state is restored so running the self-test never
        // leaves a login item behind.
        if !LoginItem.isAvailable {
            checks.append(
                Check(
                    name: "launch at login registers",
                    skipped: "not running from a .app bundle"))
        } else {
            let wasEnabled = LoginItem.isEnabled
            do {
                try LoginItem.setEnabled(true)
                if LoginItem.status == .requiresApproval {
                    checks.append(
                        Check(
                            name: "launch at login registers",
                            skipped: "approval was revoked in System Settings"))
                } else {
                    checks.append(
                        Check(
                            name: "launch at login registers",
                            passed: LoginItem.isEnabled,
                            detail: "status \(LoginItem.status.rawValue)"))
                }
            } catch {
                // `register()` itself throws once approval was revoked, not
                // just the status after a successful call — re-check status
                // rather than count every throw as a hard failure, so this
                // reportedly-common case still reports the skip it is meant
                // to, not a FAIL that has nothing to do with this branch.
                if LoginItem.status == .requiresApproval {
                    checks.append(
                        Check(
                            name: "launch at login registers",
                            skipped: "approval was revoked in System Settings"))
                } else {
                    checks.append(
                        Check(
                            name: "launch at login registers",
                            passed: false,
                            detail: "\(error)"))
                }
            }
            try? LoginItem.setEnabled(wasEnabled)
        }

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

    /// The dwell before peek opens, and the promise that nothing survives it.
    ///
    /// Driven with a real `Timer` on the real main run loop — the delay is a
    /// timer, and a check that swapped it for a mock would not be checking this
    /// feature. What is shortened is the interval: 120ms is far longer than the
    /// run loop turn these checks have to tell it apart from, and short enough
    /// that the whole block costs under a second. Nothing here sleeps
    /// generously and hopes; each wait is three times the delay it is waiting
    /// out, and every assertion is on state that is settled by then.
    ///
    /// None of these monitors is *started*, apart from the teardown one.
    /// `setInteractiveRectForTesting` drives exactly the evaluation a real move
    /// drives, and an installed global monitor would let a twitch of the user's
    /// actual mouse cancel a countdown mid-check — a check that fails when
    /// somebody leans on the desk is worse than no check at all.
    private static func hoverDelayChecks(
        _ checks: inout [Check], panel: IslandPanel, shape: CGRect,
        inside: CGPoint, outside: CGPoint
    ) async {
        let delay: TimeInterval = 0.12

        // --- Instant means instant ---
        //
        // Asserted with no `await` between the move and the check, which is the
        // whole claim: at zero there is no timer and no hop through the run
        // loop, so the card is open by the time the event handler returns.
        let instant = HoverMonitor(panel: panel, openDelay: 0)
        var instantReports: [Bool] = []
        instant.onHoverChange = { instantReports.append($0) }
        instant.setInteractiveRectForTesting(shape, cursorAt: inside)
        checks.append(
            Check(
                name: "a delay of zero opens the card on the same event, with no timer",
                passed: instantReports == [true] && instant.isReportedInside
                    && !instant.hasPendingOpen,
                detail: "reported=\(instantReports) pending=\(instant.hasPendingOpen)"))
        instant.stop()

        // --- A pointer passing through ---
        //
        // The gesture the whole setting exists for: across the top of the screen
        // and away again before the dwell is up. The pending open has to be
        // cancelled, not deferred — so this waits out three times the delay and
        // asserts the card never opened at all, rather than asserting it had not
        // opened yet.
        let sweeping = HoverMonitor(panel: panel, openDelay: delay)
        var sweepReports: [Bool] = []
        sweeping.onHoverChange = { sweepReports.append($0) }
        sweeping.setInteractiveRectForTesting(shape, cursorAt: inside)
        let countingDown = sweeping.hasPendingOpen
        let openedOnArrival = sweepReports
        // Clicks follow the pointer with no delay of any kind. If this flag were
        // deferred alongside the card, a click on the resting pill within the
        // dwell would fall through to whatever is behind the notch.
        let acceptsClicksWhileCountingDown = !panel.ignoresMouseEvents
        sweeping.setInteractiveRectForTesting(shape, cursorAt: outside)
        let stillCountingDown = sweeping.hasPendingOpen
        await tick(delay * 3)
        checks.append(
            Check(
                name: "a pointer that enters and leaves before the delay never opens the card",
                passed: countingDown && openedOnArrival.isEmpty && !stillCountingDown
                    && sweepReports.isEmpty && !sweeping.isReportedInside,
                detail: "pendingOnArrival=\(countingDown) afterLeaving=\(stillCountingDown) "
                    + "reported=\(sweepReports)"))
        checks.append(
            Check(
                name: "clicks are routed to where the pointer is, not to where the card is",
                passed: acceptsClicksWhileCountingDown && panel.ignoresMouseEvents,
                detail: "acceptedWhileCountingDown=\(acceptsClicksWhileCountingDown) "
                    + "ignoresNow=\(panel.ignoresMouseEvents)"))
        sweeping.stop()

        // --- A pointer that means it ---
        let dwelling = HoverMonitor(panel: panel, openDelay: delay)
        var dwellReports: [Bool] = []
        dwelling.onHoverChange = { dwellReports.append($0) }
        dwelling.setInteractiveRectForTesting(shape, cursorAt: inside)
        let openedBeforeWaiting = !dwellReports.isEmpty
        await tick(delay * 3)
        checks.append(
            Check(
                name: "a pointer that rests through the delay opens the card exactly once",
                passed: !openedBeforeWaiting && dwellReports == [true]
                    && dwelling.isReportedInside && !dwelling.hasPendingOpen,
                detail: "openedEarly=\(openedBeforeWaiting) reported=\(dwellReports) "
                    + "pending=\(dwelling.hasPendingOpen)"))

        // Leaving, checked with no wait at all: the asymmetry is the point. A
        // card that lingered over the window you have just moved to would be in
        // the way with no way to dismiss it but to wait.
        dwelling.setInteractiveRectForTesting(shape, cursorAt: outside)
        checks.append(
            Check(
                name: "leaving closes the card at once, with no delay of its own",
                passed: dwellReports == [true, false] && !dwelling.isReportedInside
                    && !dwelling.hasPendingOpen,
                detail: "reported=\(dwellReports)"))
        dwelling.stop()

        // --- Teardown ---
        //
        // `AppController.apply` stops the monitor the moment the last session
        // ends, on the promise that an idle HUD schedules nothing whatsoever. A
        // one-shot open that outlived that would fire against a dormant HUD, and
        // it is invisible in every other way — which is why this asserts on the
        // timer existing rather than on how the card looks.
        let torn = HoverMonitor(panel: panel, openDelay: delay)
        var tornReports: [Bool] = []
        torn.onHoverChange = { tornReports.append($0) }
        torn.start()
        torn.setInteractiveRectForTesting(shape, cursorAt: inside)
        let scheduledBeforeStop = torn.hasPendingOpen
        torn.stop()
        let scheduledAfterStop = torn.hasPendingOpen
        await tick(delay * 3)
        checks.append(
            Check(
                name: "stopping the monitor cancels a pending open rather than deferring it",
                passed: scheduledBeforeStop && !scheduledAfterStop && !torn.isRunning
                    && tornReports.isEmpty && panel.ignoresMouseEvents,
                detail: "before=\(scheduledBeforeStop) after=\(scheduledAfterStop) "
                    + "running=\(torn.isRunning) reported=\(tornReports)"))
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
        checks.append(
            Check(
                name: "the blue layer's window matches the model's",
                passed: PulsingOutline.completionWindow
                    == IslandViewModel.completionPulseDuration,
                detail:
                    "layer=\(PulsingOutline.completionWindow) model=\(IslandViewModel.completionPulseDuration)"
            ))
        outlineGeometryChecks(&checks)
        await switcherChecks(&checks, model: model)
        settingsChecks(&checks)
        displayChecks(&checks)
        soundChecks(&checks)
        frontmostMuteChecks(&checks)
        revealStateChecks(&checks, model: model)
        revealTickerChecks(&checks, model: model)
        await healthChecks(&checks)
        previewIsolationChecks(&checks, live: model)
    }

    /// The health strip's holder, and the timer that must not outlive the window.
    ///
    /// `PipelineHealth` itself is covered headlessly; what that cannot reach is
    /// the ticker, and the ticker is the part with a failure mode nobody would
    /// ever see — a 1 Hz timer left scheduled against a closed window, on an app
    /// whose whole claim is that it costs nothing while idle. So this asserts on
    /// whether a timer is *scheduled*, not on whether the label stopped moving,
    /// and then confirms the label follows.
    ///
    /// The interval is shortened so each timing wait costs a fifth of a second
    /// rather than a second; everything else about the timer — real `Timer`, real
    /// main runloop, `.common` mode — is what ships.
    private static func healthChecks(_ checks: inout [Check]) async {
        let health = PipelineHealthStore(tickInterval: 0.05)

        checks.append(
            Check(
                name: "a health holder schedules nothing before the window opens",
                passed: !health.isTicking,
                detail: "ticking=\(health.isTicking)"))

        health.socketListening(at: "/tmp/island-selftest.sock")
        checks.append(
            Check(
                name: "a bound socket with no events reports idle, not broken",
                passed: health.current.level == .idle,
                detail: "level=\(health.current.level) \(health.current.socketLabel())"))

        health.socketFailed(at: "/tmp/island-selftest.sock", reason: "bind() failed: in use")
        checks.append(
            Check(
                name: "a socket that failed to bind reports degraded, with the reason",
                passed: health.current.level == .degraded
                    && health.current.socketLabel().contains("in use"),
                detail: "level=\(health.current.level) \(health.current.socketLabel())"))

        health.socketListening(at: "/tmp/island-selftest.sock")
        health.noteEvent()
        health.noteSessions(3)
        checks.append(
            Check(
                name: "an arriving envelope and its sessions reach the settings window",
                passed: health.current.level == .healthy && health.current.sessionCount == 3
                    && health.current.lastEventLabel(now: Date()) != "never since launch",
                detail: "level=\(health.current.level) sessions=\(health.current.sessionCount) "
                    + "last=\(health.current.lastEventLabel(now: Date()))"))

        health.windowBecameVisible()
        let openedAt = health.now
        await tick(0.2)
        checks.append(
            Check(
                name: "the health ticker runs while the settings window is open",
                passed: health.isTicking && health.now > openedAt,
                detail: "ticking=\(health.isTicking) advanced="
                    + "\(health.now.timeIntervalSince(openedAt))s"))

        health.windowWentAway()
        let closedAt = health.now
        await tick(0.2)
        checks.append(
            Check(
                name: "closing the settings window leaves no timer behind",
                passed: !health.isTicking && health.now == closedAt,
                detail: "ticking=\(health.isTicking) advanced="
                    + "\(health.now.timeIntervalSince(closedAt))s"))

        // Reopening has to bring it back. Called twice because `show()` fires the
        // visibility callback unconditionally, including for a window that was
        // already up.
        health.windowBecameVisible()
        health.windowBecameVisible()
        let reopenedAt = health.now
        await tick(0.2)
        checks.append(
            Check(
                name: "reopening the settings window starts the ticker again",
                passed: health.isTicking && health.now > reopenedAt,
                detail: "ticking=\(health.isTicking)"))

        // And one close stops all of it. Without the `guard ticker == nil` the
        // second open would overwrite the reference and orphan the first timer,
        // which `isTicking` cannot see — but the orphan would go on setting
        // `now` after the close, so the frozen clock is what catches it.
        health.windowWentAway()
        let stoppedAt = health.now
        await tick(0.2)
        checks.append(
            Check(
                name: "a second open leaves no orphan timer still moving the clock",
                passed: !health.isTicking && health.now == stoppedAt,
                detail: "ticking=\(health.isTicking) advanced="
                    + "\(health.now.timeIntervalSince(stoppedAt))s"))

        // Laying the pane out is the only automated evidence that the strip
        // renders at all: everything above is state, and a `LabeledContent` that
        // silently produces nothing would pass every one of those checks. It is
        // a smoke test and says so — it cannot see *what* was drawn, only that
        // SwiftUI resolved the pane to a real size in both the degraded and the
        // healthy case.
        health.socketFailed(at: "/tmp/island-selftest.sock", reason: "bind() failed: in use")
        let degradedSize = settingsPaneSize(health: health)
        health.socketListening(at: "/tmp/island-selftest.sock")
        health.noteEvent()
        let healthySize = settingsPaneSize(health: health)
        checks.append(
            Check(
                name: "the general pane lays out with the health strip in it",
                passed: degradedSize.width > 0 && degradedSize.height > 0
                    && healthySize.width > 0 && healthySize.height > 0,
                detail: "degraded=\(degradedSize) healthy=\(healthySize)"))
    }

    /// The Appearance pane's preview draws with the same view model class the
    /// HUD does, which is exactly what makes it worth a check.
    ///
    /// `forcedMode` is a pin on the real island on the real screen. A preview
    /// that posed the live model would pin the user's HUD as a side effect of
    /// opening a settings pane and leave it pinned, because nothing else ever
    /// clears it — and the pane would look completely correct while doing it.
    /// The seam is `IslandPreviewSource`, so this drives the same call the
    /// segmented control drives and then asks the live model whether anything
    /// moved.
    private static func previewIsolationChecks(_ checks: inout [Check], live: IslandViewModel) {
        live.forcedMode = nil
        live.unpin()
        live.isHovered = false
        live.apply(activeSnapshot())

        let preview = IslandPreviewSource()
        preview.show(.expanded)

        checks.append(
            Check(
                name: "the appearance preview poses a model of its own",
                passed: preview.model !== live && preview.model.mode == .expanded
                    && live.forcedMode == nil && live.mode == .compact,
                detail: "preview=\(preview.model.mode) live=\(live.mode) "
                    + "forced=\(String(describing: live.forcedMode))"))

        checks.append(
            Check(
                name: "the preview's invented sessions never reach the HUD",
                passed: live.snapshot.primary?.id == "selftest"
                    && preview.model.snapshot.primary?.id != "selftest"
                    && preview.model.allSessions.count == 3,
                detail: "live=\(live.snapshot.primary?.id ?? "nil") "
                    + "preview=\(preview.model.allSessions.map(\.id))"))

        // The preview's sessions have no ancestry to resolve — nothing here was
        // launched by anything — so resolved for real the card would offer
        // "terminal unknown" on the one surface where someone looks the card
        // over before using it. Asserted for every session, not just the shown
        // one, because the switcher can select any of the three.
        let previewOwners = preview.model.allSessions.map { preview.model.owner(for: $0) }
        let named = previewOwners.compactMap { outcome -> String? in
            guard case .owner(let app) = outcome else { return nil }
            return app.name
        }
        checks.append(
            Check(
                name: "the preview's card offers a reveal rather than an unknown terminal",
                passed: named.count == previewOwners.count && !named.isEmpty,
                detail: "\(previewOwners.count) sessions, owners: \(named)"))

        // Leaves nothing ticking: every fixture holds a live session, so the
        // preview scheduled a 1 Hz timer the moment it was posed.
        preview.shutdown()
        live.apply(HUDSnapshot())
    }

    /// Hosts the real settings view at the window's default size and returns what
    /// it laid out to. The settings store writes to a temporary directory: this
    /// only mounts the view, but `onAppear` installs a write-failure handler and
    /// a self-test must not be able to touch the real settings file.
    private static func settingsPaneSize(
        health: PipelineHealthStore, settings: IslandSettings = IslandSettings()
    ) -> CGSize {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("island-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let view = SettingsView(
            store: SettingsStore(settings, root: root),
            health: health,
            model: IslandViewModel(),
            actions: SettingsActions(
                quit: {}, revealSupportFolder: {},
                notifyBinaryPath: { "/tmp/claude-island-notify" },
                // A no-op, not the real player: mounting a pane must not be
                // able to make a noise, and nothing here presses the button.
                previewSound: { _ in }))
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 820, height: 580)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The settings window's plumbing: store → disk → live effect.
    ///
    /// `IslandSettings` itself is covered by the headless suite. What that
    /// cannot reach is the app-side store, and the store is where a settings
    /// window fails quietly — a toggle that moves on screen, does nothing, and
    /// forgets itself by the next launch looks exactly like one that works.
    private static func settingsChecks(_ checks: inout [Check]) {
        // The window refuses the toolbar `NavigationSplitView` hangs off it —
        // a sidebar toggle for a sidebar that is pinned, and a tracking
        // separator that truncated the window's title to the sidebar's column.
        // Asserted by handing one over rather than by waiting for SwiftUI to
        // install its own: the contract is that this window never carries a
        // toolbar whoever sets it, and a check that watched for SwiftUI's would
        // pass vacuously on the day SwiftUI stopped installing one.
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.toolbar = NSToolbar(identifier: "selftest")
        checks.append(
            Check(
                name: "the settings window refuses a toolbar",
                passed: window.toolbar == nil,
                detail: "toolbar=\(window.toolbar.map(\.identifier) ?? "nil")"))

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("island-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var seeded = IslandSettings()
        seeded.hudEnabled = true
        // No pane binds this one — it is reachable only by hand-editing the file
        // or touching the sentinel. See the check below.
        seeded.debugTint = true
        let store = SettingsStore(seeded, root: root)

        var applied: [IslandSettings] = []
        store.onChange = { applied.append($0) }

        store.hudEnabled = false
        checks.append(
            Check(
                name: "changing a setting notifies the app",
                passed: applied.count == 1 && applied.last?.hudEnabled == false,
                detail: "\(applied.count) notification(s), last hudEnabled="
                    + "\(applied.last.map { "\($0.hudEnabled)" } ?? "none")"))

        checks.append(
            Check(
                name: "changing a setting writes it to disk at once",
                passed: IslandSettings.load(root: root).hudEnabled == false,
                detail: "on disk: \(IslandSettings.load(root: root))"))

        store.doNotDisturb = true
        store.forcedMode = "peek"
        let reloaded = IslandSettings.load(root: root)
        checks.append(
            Check(
                name: "later changes do not drop the earlier ones",
                passed: !reloaded.hudEnabled && reloaded.doNotDisturb
                    && reloaded.forcedMode == "peek",
                detail: "\(reloaded)"))

        // `persist()` writes the whole snapshot, so every setting the store does
        // not hold is a setting the next toggle silently erases. `debugTint` is
        // the only one with no control bound to it, which makes it the only one
        // whose property looks unused and invites deletion — and the user who
        // would lose it is the one who set it in the file precisely because
        // there is no switch to notice it was gone.
        checks.append(
            Check(
                name: "a setting with no control survives a change made in the window",
                passed: reloaded.debugTint,
                detail: "on disk: debugTint=\(reloaded.debugTint)"))

        // The pane writes a cue's settings through a subscript rather than to a
        // named property. A subscript setter that assigned to a copy would still
        // move the picker on screen and still lose it by the next launch.
        store[.waiting] = CueSound(enabled: false, name: "Tink")
        let sounds = IslandSettings.load(root: root)
        checks.append(
            Check(
                name: "a per-cue sound change persists through the store's subscript",
                passed: sounds[.waiting] == CueSound(enabled: false, name: "Tink")
                    && sounds[.done] == SoundCue.done.defaultSound,
                detail: "waiting=\(sounds[.waiting]) done=\(sounds[.done])"))

        // Exactly what the picker does when None is chosen: a mutating call
        // *through* the subscript, which needs both accessors to reach disk. A
        // getter-only subscript compiles into a copy, mutates that, and throws it
        // away — the picker would snap back the moment the view redrew.
        store[.done].select(nil)
        let silenced = IslandSettings.load(root: root)
        checks.append(
            Check(
                name: "picking None persists, keeping the sound the cue goes back to",
                passed: silenced[.done].selectedName == nil && silenced[.done].name == "Glass",
                detail: "done=\(silenced[.done])"))

        // The display is stored as a name that may well not be attached, so
        // nothing along the write path is allowed to "helpfully" drop it — the
        // whole fallback rests on the choice outliving the monitor.
        store.preferredDisplay = "LG UltraFine"
        checks.append(
            Check(
                name: "a chosen display persists even though nothing here is called that",
                passed: IslandSettings.load(root: root).preferredDisplay == "LG UltraFine",
                detail: "on disk: "
                    + "\(IslandSettings.load(root: root).preferredDisplay ?? "none")"))
        store.preferredDisplay = nil
        checks.append(
            Check(
                name: "choosing the menu bar display again clears the stored name",
                passed: IslandSettings.load(root: root).preferredDisplay == nil,
                detail: "on disk: "
                    + "\(IslandSettings.load(root: root).preferredDisplay ?? "none")"))

        // The hover delay is the one setting with a range, so it is the one
        // that can be written out of it. The store clamps on the way to both
        // disk and the app, because what is downstream of `onChange` is a
        // `Timer` interval — a value nobody should have to re-validate.
        store.hoverOpenDelayMilliseconds = 275
        checks.append(
            Check(
                name: "the hover delay persists through the store",
                passed: IslandSettings.load(root: root).hoverOpenDelayMilliseconds == 275,
                detail: "on disk: \(IslandSettings.load(root: root).hoverOpenDelayMilliseconds)"))

        store.hoverOpenDelayMilliseconds = 30_000
        checks.append(
            Check(
                name: "a hover delay out of range reaches neither the file nor the app",
                passed: IslandSettings.load(root: root).hoverOpenDelayMilliseconds
                    == HoverDelay.maximum
                    && applied.last?.hoverOpenDelayMilliseconds == HoverDelay.maximum,
                detail: "on disk: \(IslandSettings.load(root: root).hoverOpenDelayMilliseconds) "
                    + "applied: \(applied.last?.hoverOpenDelayMilliseconds ?? -1)"))
        store.hoverOpenDelayMilliseconds = HoverDelay.default

        // The switch has to reach the app as well as the file: the level is read
        // once at launch and then only ever again through `onChange`, so a value
        // that persisted but never applied would move nothing until a relaunch.
        store.aboveOtherNotchHUDs = true
        checks.append(
            Check(
                name: "the notch-HUD switch reaches both the file and the app",
                passed: IslandSettings.load(root: root).aboveOtherNotchHUDs
                    && applied.last?.aboveOtherNotchHUDs == true,
                detail: "on disk: \(IslandSettings.load(root: root).aboveOtherNotchHUDs) "
                    + "applied: \(applied.last?.aboveOtherNotchHUDs.description ?? "none")"))
        store.aboveOtherNotchHUDs = false

        // The window writes a string; the HUD needs a tier. A typo must leave
        // the HUD unpinned rather than pin it to something arbitrary.
        checks.append(
            Check(
                name: "a stored tier name maps onto the HUD's mode",
                passed: IslandMode(forcedName: "expanded") == .expanded
                    && IslandMode(forcedName: " Peek ") == .peek
                    && IslandMode(forcedName: "nonsense") == nil
                    && IslandMode(forcedName: nil) == nil,
                detail: "expanded=\(String(describing: IslandMode(forcedName: "expanded"))) "
                    + "nonsense=\(String(describing: IslandMode(forcedName: "nonsense")))"))
    }

    /// Which display the HUD draws on, and what becomes of it when that display
    /// is not there.
    ///
    /// The rule is driven against a made-up list of display names. The failure it
    /// exists for is a monitor being unplugged, and a check that could only be
    /// run by pulling a cable is a check nobody runs; worse, one that passed
    /// because of the two monitors on this particular desk would say nothing
    /// about anyone else's. `DisplaySelection` is deliberately shaped to take a
    /// list of strings so this can be asserted from a keyboard.
    ///
    /// The last two then walk the real `NSScreen` path, which is the half no
    /// headless suite can reach: a rule that resolves perfectly and is wired to
    /// nothing looks exactly like no feature at all.
    private static func displayChecks(_ checks: inout [Check]) {
        let attached = ["Built-in Retina Display", "DELL P3223QE", "LG UltraFine"]
        func resolve(_ preferred: String?, _ list: [String], menuBar: Int = 0)
            -> DisplayResolution?
        {
            DisplaySelection.resolve(preferred: preferred, attached: list, menuBarIndex: menuBar)
        }

        let unset = resolve(nil, attached)
        checks.append(
            Check(
                name: "with no display chosen the HUD stays on the menu bar's",
                passed: unset?.index == 0 && unset?.missing == nil,
                detail: "\(String(describing: unset))"))

        let chosen = resolve("DELL P3223QE", attached)
        checks.append(
            Check(
                name: "a chosen display that is attached is the one drawn on",
                passed: chosen?.index == 1 && chosen?.missing == nil,
                detail: "\(String(describing: chosen))"))

        // The behaviour the whole feature turns on. "Not attached" has to mean
        // the menu bar's display — not the panel's last coordinates, which now
        // belong to no screen at all, and not nil, which would leave the geometry
        // unresolved and the island drawn nowhere.
        let unplugged = resolve("LG UltraFine", ["Built-in Retina Display", "DELL P3223QE"])
        checks.append(
            Check(
                name: "an unplugged display falls back to the menu bar's, not to nothing",
                passed: unplugged?.index == 0 && unplugged?.missing == "LG UltraFine",
                detail: "\(String(describing: unplugged))"))

        // Only equal to "the first display" because AppKit happens to order that
        // array menu-bar-first; the rule is written against the menu bar.
        let elsewhere = resolve("Unplugged", attached, menuBar: 2)
        checks.append(
            Check(
                name: "the fallback follows the menu bar, not the first display in the list",
                passed: elsewhere?.index == 2,
                detail: "\(String(describing: elsewhere))"))

        // --- The real screens, through the app's own path ---

        guard let menuBar = NotchGeometryResolver.menuBarScreen() else {
            checks.append(
                Check(name: "a display this Mac does not have lands on the menu bar screen",
                    skipped: "no screens are attached"))
            return
        }
        let menuBarID = NotchGeometryResolver.displayID(of: menuBar)
        // A name no display can have, so this says the same thing on every Mac —
        // including one where the user really does own an LG UltraFine.
        let phantom = "No Such Display \(UUID().uuidString)"
        let stranded = NotchGeometryResolver.resolveDisplay(preferred: phantom)
        checks.append(
            Check(
                name: "a display this Mac does not have lands on the menu bar screen",
                passed: stranded?.missing == phantom
                    && stranded.map { NotchGeometryResolver.displayID(of: $0.screen) } == menuBarID
                    && stranded?.geometry.screenID == menuBarID
                    // On-screen, not merely on the right screen: the point of
                    // falling back is that the island is somewhere you can see.
                    && menuBar.frame.contains(stranded?.geometry.islandRect ?? .null),
                detail: "screen=\(stranded?.screen.localizedName ?? "none") "
                    + "island=\(String(describing: stranded?.geometry.islandRect)) "
                    + "menuBar=\(menuBar.localizedName) \(menuBar.frame)"))

        // Not merely "on the right screen" but pixel-for-pixel what an install
        // that had never touched this setting would draw. A fallback that landed
        // on the menu bar's display with subtly different geometry would be a
        // second bug hiding inside the fix for the first.
        checks.append(
            Check(
                name: "the fallback geometry is exactly the no-preference geometry",
                passed: stranded?.geometry == NotchGeometryResolver.current(),
                detail: "fallback=\(String(describing: stranded?.geometry.islandRect)) "
                    + "default=\(String(describing: NotchGeometryResolver.current()?.islandRect))"))

        // The picker's odd branch, laid out for real: a stored display that is
        // not attached puts an extra row and a caption on General. A smoke test
        // — it cannot see what was drawn — but the alternative is a branch that
        // only ever runs on a desk with the right monitor missing.
        var pinnedToNothing = IslandSettings()
        pinnedToNothing.preferredDisplay = phantom
        let paneSize = settingsPaneSize(health: PipelineHealthStore(), settings: pinnedToNothing)
        checks.append(
            Check(
                name: "the general pane lays out with a display that is not connected",
                passed: paneSize.width > 0 && paneSize.height > 0,
                detail: "\(paneSize)"))

        // The other direction: every attached display resolves back to itself.
        // Skipped rather than asserted when two share a name — `DisplaySelection`
        // says why they cannot be told apart, and failing here would report a
        // documented limitation as a regression.
        let names = NSScreen.screens.map(\.localizedName)
        let ambiguous = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        if let duplicate = ambiguous.first {
            checks.append(
                Check(
                    name: "every attached display can be picked by name",
                    skipped: "two displays are both called \"\(duplicate)\""))
        } else {
            let wrong = NSScreen.screens.filter { screen in
                NotchGeometryResolver.resolveDisplay(preferred: screen.localizedName)?
                    .geometry.screenID != NotchGeometryResolver.displayID(of: screen)
            }
            checks.append(
                Check(
                    name: "every attached display can be picked by name",
                    passed: wrong.isEmpty,
                    detail: wrong.isEmpty
                        ? "\(names.count) display(s): \(names.joined(separator: ", "))"
                        : "did not resolve to itself: "
                            + wrong.map(\.localizedName).joined(separator: ", ")))
        }
    }

    /// The sound settings' app-side half: a stored name has to become a sound.
    ///
    /// Nothing here plays anything. `NSSound(named:)` loads a sound and this
    /// inspects what it loaded — a self-test that made a dozen noises is one
    /// nobody would run twice, and the check would still not prove anything the
    /// resolved name does not.
    ///
    /// The headless suite covers the settings themselves; what it cannot reach
    /// is whether the names in `SystemSound.all` mean anything to AppKit on this
    /// machine, which is the whole point of offering a fixed list.
    private static func soundChecks(_ checks: inout [Check]) {
        let missing = SystemSound.all.filter { NSSound(named: $0) == nil }
        checks.append(
            Check(
                name: "every sound the picker offers exists on this Mac",
                passed: missing.isEmpty,
                detail: missing.isEmpty
                    ? "\(SystemSound.all.count) sounds load"
                    : "missing: \(missing.joined(separator: ", "))"))

        for cue in SoundCue.allCases {
            // A name macOS dropped, or a typo in a hand-edited settings.json.
            // Either way the cue must still be audible: silence here would be
            // read as the HUD having stopped noticing sessions at all.
            let fallback = Self.resolve("Klink-no-such-sound", for: cue)
            checks.append(
                Check(
                    name: "an unknown sound name for \(cue) falls back to its default",
                    passed: fallback == cue.defaultSoundName,
                    detail: "resolved to \(fallback ?? "silence"), wanted \(cue.defaultSoundName)"))

            checks.append(
                Check(
                    name: "a chosen sound name for \(cue) is the one that would ring",
                    passed: Self.resolve("Submarine", for: cue) == "Submarine",
                    detail: "resolved to \(Self.resolve("Submarine", for: cue) ?? "silence")"))
        }
    }

    /// The gate that decides whether a cue is allowed to ring at all.
    ///
    /// Deterministic because `AppController.rings(_:under:frontmost:)` is handed
    /// the frontmost bundle id rather than reading `NSWorkspace` itself — the app
    /// in front while --selftest runs is whatever the user left there, so a check
    /// that consulted the real workspace would pass or fail by accident. What
    /// stays uncovered is that one line: that the live path asks the workspace and
    /// asks it for the *bundle identifier*. No automated check can pin that down
    /// without dictating which app is frontmost.
    ///
    /// Nothing here plays anything; `rings` returns a decision, `play` is what
    /// makes noise.
    private static func frontmostMuteChecks(_ checks: inout [Check]) {
        var off = IslandSettings()  // The default: ring wherever you are looking.
        off.muteWhileTerminalFrontmost = false
        var on = IslandSettings()
        on.muteWhileTerminalFrontmost = true

        checks.append(
            Check(
                name: "with the gate off, a terminal in front still rings",
                passed: AppController.rings(.done, under: off, frontmost: "com.apple.Terminal")
                    && AppController.rings(.inputRequired, under: off, frontmost: "dev.zed.Zed"),
                detail: "off.muteWhileTerminalFrontmost=\(off.muteWhileTerminalFrontmost)"))

        let terminals: [String] = [
            "com.apple.Terminal", "com.microsoft.VSCode", "com.jetbrains.pycharm",
        ]
        let silenced = terminals.filter { !AppController.rings(.done, under: on, frontmost: $0) }
        checks.append(
            Check(
                name: "with the gate on, a terminal in front silences the cue",
                passed: silenced.count == 3,
                detail: "silenced \(silenced.count) of 3: \(silenced.joined(separator: ", "))"))

        // The safe direction: anything we cannot identify has to ring. A gate that
        // fell silent for unknown apps would be a HUD that quietly stopped making
        // noise, with nothing on screen to connect it to this switch.
        checks.append(
            Check(
                name: "with the gate on, a non-terminal or unknown app still rings",
                passed: AppController.rings(.done, under: on, frontmost: "com.apple.Safari")
                    && AppController.rings(.done, under: on, frontmost: nil)
                    && AppController.rings(.done, under: on, frontmost: "com.example.mystery"),
                detail: "safari=\(AppController.rings(.done, under: on, frontmost: "com.apple.Safari")) "
                    + "nil=\(AppController.rings(.done, under: on, frontmost: nil))"))

        // The gate only ever subtracts. It cannot un-mute a cue that the mute
        // above it or the cue's own picker already silenced, in either order.
        var mutedToo = on
        mutedToo.doNotDisturb = true
        var cueOff = on
        cueOff[.waiting].select(nil)
        checks.append(
            Check(
                name: "the frontmost gate never overrides the mute or a cue set to None",
                passed: !AppController.rings(.done, under: mutedToo, frontmost: "com.apple.Safari")
                    && !AppController.rings(.waiting, under: cueOff, frontmost: "com.apple.Safari"),
                detail: "muted=\(AppController.rings(.done, under: mutedToo, frontmost: nil)) "
                    + "cueOff=\(AppController.rings(.waiting, under: cueOff, frontmost: nil))"))

        // Both ids reach `rings` as autoclosures, and nothing may resolve them
        // until the switches above have passed. That is the difference between
        // free and a walk up eight ancestors — `kill` per pid, then
        // `NSRunningApplication` per pid, on the main thread — on every state
        // edge of every session, on a default install where this switch is off
        // and the answer is discarded. Counted rather than argued.
        var probed = 0
        func probe() -> String? {
            probed += 1
            return "com.apple.Terminal"
        }
        _ = AppController.rings(.done, under: off, frontmost: probe(), owner: probe())
        let probesWithGateOff = probed
        _ = AppController.rings(.done, under: on, frontmost: probe(), owner: probe())
        checks.append(
            Check(
                name: "the mute asks the system nothing until it can use the answer",
                passed: probesWithGateOff == 0 && probed > 0,
                detail: "probes with the gate off=\(probesWithGateOff), "
                    + "on=\(probed - probesWithGateOff)"))

        // The upgrade: a session whose own terminal is in front goes quiet,
        // while a session running in a *different* terminal still rings. The
        // old heuristic could not tell those apart and silenced both.
        checks.append(
            Check(
                name: "an owned session mutes only for its own terminal",
                passed: !AppController.rings(
                    .done, under: on, frontmost: "com.microsoft.VSCode",
                    owner: "com.microsoft.VSCode")
                    && AppController.rings(
                        .done, under: on, frontmost: "com.apple.Terminal",
                        owner: "com.microsoft.VSCode"),
                detail: "own-terminal mute vs other-terminal ring"))
    }

    /// What `AppController` would ring for this name, by name — never played.
    private static func resolve(_ name: String, for cue: SoundCue) -> String? {
        AppController.sound(for: cue, named: name)?.name
    }

    /// The four reveal states, and what the click does with each of its two
    /// outcomes — driven through `OwnerResolution` and a stubbed raise rather
    /// than the live process table, so the result does not depend on what is
    /// running while the harness does.
    ///
    /// Deliberately does not fire a real activation: `open` yanks the frontmost
    /// app, and the focus checks running beside this one would fail as a direct
    /// result.
    private static func revealStateChecks(_ checks: inout [Check], model: IslandViewModel) {
        let app = OwnerResolution.AppInfo(
            pid: 1797, bundleID: "com.microsoft.VSCode", name: "Visual Studio Code",
            isRegular: true)
        let helper = OwnerResolution.AppInfo(
            pid: 1927, bundleID: "com.microsoft.VSCode.helper", name: "Code Helper",
            isRegular: false)

        let owner = OwnerResolution.resolve(
            [4368, 1927, 1797], isRunning: { _ in true },
            lookup: { $0 == 1797 ? app : ($0 == 1927 ? helper : nil) })
        checks.append(
            Check(
                name: "reveal resolves past helpers to the app",
                passed: owner == .owner(app),
                detail: "\(owner)"))

        let background = OwnerResolution.resolve(
            [7518], isRunning: { _ in true }, lookup: { _ in nil })
        checks.append(
            Check(
                name: "a background job reports no owning app",
                passed: background == .noOwningApp, detail: "\(background)"))

        let gone = OwnerResolution.resolve(
            [4368], isRunning: { _ in false }, lookup: { _ in nil })
        checks.append(
            Check(name: "a dead chain reports gone", passed: gone == .gone, detail: "\(gone)"))

        let unknown = OwnerResolution.resolve(
            [], isRunning: { _ in false }, lookup: { _ in nil })
        checks.append(
            Check(
                name: "no ancestry reports unknown", passed: unknown == .unknown,
                detail: "\(unknown)"))

        // The click, with the raise stubbed out — the real one spawns `open` and
        // would pull the frontmost app away from the checks running beside this.
        //
        // A row can be a second out of date: the terminal quits, `reveal`
        // re-resolves and finds nothing to raise. Dismissing the card there
        // would leave a click that did nothing with nothing on screen to say so.
        model.forcedMode = nil
        model.apply(HUDSnapshot(primary: session("reveal", state: .done)))
        model.togglePinned()
        model.revealOwner(of: session("reveal", state: .done)) { _ in false }
        checks.append(
            Check(
                name: "a reveal that raises nothing leaves the card open",
                passed: model.isPinnedOpen && model.mode == .expanded,
                detail: "pinned=\(model.isPinnedOpen) mode=\(model.mode)"))

        model.revealOwner(of: session("reveal", state: .done)) { _ in true }
        checks.append(
            Check(
                name: "a reveal that lands dismisses the card",
                passed: !model.isPinnedOpen,
                detail: "pinned=\(model.isPinnedOpen)"))

        model.apply(HUDSnapshot())
    }

    /// The reveal row's cache can only go stale while the card is open, so the
    /// ticker that refreshes it has to run in exactly that situation — even
    /// when every displayed session is idle/done/error and no rate-limit
    /// countdown is showing, the one condition `syncTicker`'s other two terms
    /// (`wantsAnimation`, `showsResetCountdown`) do not cover. Without this,
    /// pinning the card open to browse a finished session and then quitting
    /// its terminal left the row reading a stale `.owner` until an unrelated
    /// snapshot arrived or the card was closed and reopened.
    private static func revealTickerChecks(_ checks: inout [Check], model: IslandViewModel) {
        model.isHovered = false
        model.forcedMode = nil
        model.apply(HUDSnapshot())
        checks.append(
            Check(
                name: "no sessions means no ticker, pinned or not",
                passed: !model.isTickerRunning && model.mode == .dormant,
                detail: "ticking=\(model.isTickerRunning) mode=\(model.mode)"))

        // A single settled session: nothing animating, no countdown either —
        // the exact combination that used to leave the ticker off entirely.
        model.apply(HUDSnapshot(primary: session("done", state: .done)))
        checks.append(
            Check(
                name: "an idle session with the card unpinned starts no ticker",
                passed: !model.isTickerRunning,
                detail: "ticking=\(model.isTickerRunning) mode=\(model.mode)"))

        model.togglePinned()
        checks.append(
            Check(
                name: "pinning an all-idle card open starts the ticker anyway",
                passed: model.mode == .expanded && model.isTickerRunning,
                detail: "mode=\(model.mode) ticking=\(model.isTickerRunning)"))

        model.togglePinned()
        checks.append(
            Check(
                name: "unpinning stops the ticker again",
                passed: !model.isPinnedOpen && !model.isTickerRunning,
                detail: "pinned=\(model.isPinnedOpen) ticking=\(model.isTickerRunning)"))

        model.forcedMode = nil
        model.apply(HUDSnapshot())
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

    /// Browsing the switcher must not change the card's width — and must change
    /// its height.
    ///
    /// The width used to follow the selected session's name length, and because
    /// the shape is centred on the camera, every click reflowed the whole HUD
    /// sideways. The height went the other way: measured across all sessions, a
    /// sparse session was drawn with room for a busy one's trail and plan below
    /// it. So these two axes are checked in opposite directions on purpose.
    private static func stableSizeChecks(_ checks: inout [Check], model: IslandViewModel) async {
        var short = session("s", state: .thinking)
        short.cwd = "/tmp/ui"
        // A `.gone` owner: the shortest of the four reveal-row labels.
        short.ownerPIDs = [4242]

        var long = session("l", state: .done)
        long.cwd = "/tmp/a-considerably-longer-worktree-name"
        // A resolvable `.owner`: the longest label the row draws, and the one
        // state that swaps a plain `Text` for a `Button` with its own padding
        // — the shape most likely to drift in height if anyone touches it.
        long.ownerPIDs = [1797]
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

        // `apply()` above ran the moment it was called, with `forcedMode` still
        // nil — its own `refreshOwners()` found `mode != .expanded` and left
        // `ownerCache` empty, so both fixtures would silently read back as
        // `.unknown` and the checks below would never see a real owner state.
        // Refresh explicitly, now that the card is open, with a resolver keyed
        // on each fixture's `ownerPIDs` rather than `SessionOwner.resolve`'s
        // live process table — the result must not depend on what else is
        // running on the machine this check executes on.
        let vsCode = OwnerResolution.AppInfo(
            pid: 1797, bundleID: "com.microsoft.VSCode", name: "Visual Studio Code",
            isRegular: true)
        model.refreshOwners { pids in
            switch pids {
            case [1797]: return .owner(vsCode)
            case [4242]: return .gone
            default: return .unknown
            }
        }

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
                name: "the card is sized for the widest session, not the shown one",
                passed: sizeWithShort.width
                    >= model.notchGap + 2 * model.leftClusterWidth(for: long),
                detail: "width=\(sizeWithShort.width)"))
        // `long` has three finished calls and a plan; `short` has neither, so a
        // card measured from the session on screen has to be the shorter one.
        checks.append(
            Check(
                name: "switcher height shrinks to the shown session's own blocks",
                passed: sizeWithShort.height < sizeWithLong.height - 0.5,
                detail: "short=\(sizeWithShort.height) long=\(sizeWithLong.height)"))
        checks.append(
            Check(
                name: "no session's card is taller than the stated ceiling",
                passed: max(sizeWithShort.height, sizeWithLong.height)
                    <= model.expandedMaxHeight + 0.5,
                detail:
                    "short=\(sizeWithShort.height) long=\(sizeWithLong.height) "
                    + "max=\(model.expandedMaxHeight)"))

        // The three checks above compare `model.shapeSize`, a hand-tallied
        // constant sum that reserves one flat `revealRowHeight` no matter what
        // `ownerCache` holds — it cannot read the row's real content, so no
        // assignment of owner states could ever make it fail from a
        // `RevealRow`-specific regression. Render the row for real instead,
        // the same `NSHostingView` + `fittingSize` technique `cardFitChecks`
        // uses below to catch `expandedChromeHeight` drifting from the actual
        // card, aimed here at one row instead of the whole thing.
        //
        // `.content`, not the row itself. `RevealRow.body` ends in
        // `.frame(height: revealRowHeight)`, so measuring the row measures that
        // frame and nothing else: 40pt text with 30pt of padding inside it still
        // reports 20, and the check passes while the card clips. Measured with
        // exactly that content, the unframed row comes to 107 and this fails,
        // which is the point. Today it is 20.0 for the button and 10.0 for the
        // disabled text, so the budget holds with room to spare, and anything
        // that outgrows it fails here instead of being silently cut off.
        let goneRowHeight = Self.measuredHeight(of: RevealRow(session: short, model: model).content)
        let ownerRowHeight = Self.measuredHeight(of: RevealRow(session: long, model: model).content)
        checks.append(
            Check(
                name: "the reveal row's content fits the height the card reserves",
                passed: goneRowHeight <= IslandViewModel.revealRowHeight + 0.5
                    && ownerRowHeight <= IslandViewModel.revealRowHeight + 0.5,
                detail: "gone=\(goneRowHeight) owner=\(ownerRowHeight) "
                    + "reserved=\(IslandViewModel.revealRowHeight)"))

        model.forcedMode = nil
        model.apply(HUDSnapshot())

        await cardFitChecks(&checks, model: model)
    }

    /// Lays out one view at a width wide enough that only its own natural
    /// height is in play, and reads that back. The same measurement
    /// `cardFitChecks` runs on the whole card, aimed at a single row.
    private static func measuredHeight(of view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
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
        busy.linesAdded = 1_412
        busy.linesRemoved = 386
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

        // Five sessions, so the switcher's viewport is full and one row sits
        // below the fold, and a 5-hour window so the tallest chrome is measured.
        let others = (0..<4).map { session("other\($0)", state: .thinking) }
        model.apply(
            HUDSnapshot(
                primary: busy, others: others,
                rateLimit: RateLimitWindow(
                    usedPercentage: 74, resetsAt: Date().addingTimeInterval(4_320))))
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
                passed: model.expandedMaxHeight <= NotchGeometryResolver.panelHeight,
                detail: "tallest=\(model.expandedMaxHeight) panel=\(NotchGeometryResolver.panelHeight)"
            ))
        checks.append(
            Check(
                name: "sessions beyond the switcher's rows are listed, not dropped",
                passed: model.sessionOverflowCount == 1,
                detail: "below the fold=\(model.sessionOverflowCount) of \(model.allSessions.count)"))

        // The viewport is whole rows plus a fixed sliver, so it only lands where
        // it means to if the budgeted row height matches the row a session
        // actually draws as. Off by a point and the sliver is a different depth
        // than the fade drawn over it, four rows down.
        let rowHost = NSHostingView(
            rootView: SessionRow(candidate: busy, isShown: true, onSelect: {})
                .frame(width: model.cardContentWidth))
        let rowHeight = rowHost.fittingSize.height
        checks.append(
            Check(
                name: "a session row draws at the height the switcher budgets for it",
                passed: abs(rowHeight - IslandViewModel.sessionRowHeight) <= 0.5,
                detail: "row=\(rowHeight) budgeted=\(IslandViewModel.sessionRowHeight)"))

        // What scrolling is for: the ninth session costs the card nothing, so a
        // busy machine does not push the trail off the bottom of the panel.
        model.apply(
            HUDSnapshot(
                primary: busy,
                others: others + (0..<4).map { session("late\($0)", state: .thinking) },
                rateLimit: RateLimitWindow(
                    usedPercentage: 74, resetsAt: Date().addingTimeInterval(4_320))))
        let withMore = model.shapeSize.height
        checks.append(
            Check(
                name: "sessions past the fourth scroll instead of growing the card",
                passed: abs(withMore - size.height) <= 0.5,
                detail: "9 sessions=\(withMore) 5 sessions=\(size.height)"))

        // The sparse card is the case the flexible height introduced, and the one
        // a tally aimed at the busy card can undercount: with no trail, no plan
        // and no chips there is nothing left over to absorb an error, so a block
        // measured a few points short is clipped rather than merely tight.
        model.select("other0")
        let sparseSize = model.shapeSize
        if let sparse = model.displaySession {
            let sparseHost = NSHostingView(rootView: ExpandedContent(session: sparse, model: model))
            sparseHost.frame = CGRect(origin: .zero, size: sparseSize)
            sparseHost.layoutSubtreeIfNeeded()
            let sparseNeeded = sparseHost.fittingSize.height

            checks.append(
                Check(
                    name: "a sparse session's card is never shorter than its contents",
                    passed: sparseNeeded <= sparseSize.height + 0.5,
                    detail: "content=\(sparseNeeded) card=\(sparseSize.height)"))
            checks.append(
                Check(
                    name: "the black space a busy session needs is not held for a sparse one",
                    passed: sparseSize.height < size.height - 0.5,
                    detail: "sparse=\(sparseSize.height) busy=\(size.height)"))
        }
        model.select("other0")

        model.forcedMode = nil
        model.apply(HUDSnapshot())

        await peekFitChecks(&checks, model: model)
        await answerBlockFitChecks(&checks, model: model)
        await branchFitChecks(&checks, model: model)
        await titleFitChecks(&checks, model: model)
        await notchlessFitChecks(&checks, model: model)
    }

    /// The same fit budget, on a display with no cutout.
    ///
    /// Every other check here runs against whatever screen the test happens to
    /// be on, which on the machine this was written on has a notch — so the
    /// notchless card was measured by nothing at all until the HUD learned to
    /// draw on a second display and someone looked at it. The two paths differ
    /// in exactly one term: with no cutout there is no camera band to route
    /// around, so the header's height stops being the band's height and starts
    /// being a line of text.
    ///
    /// Geometry is synthetic rather than borrowed from an attached display: the
    /// case has to be measurable on notched hardware, or it goes back to being
    /// covered only when someone happens to plug in the right monitor.
    private static func notchlessFitChecks(
        _ checks: inout [Check], model: IslandViewModel
    ) async {
        let restore = model.geometry
        defer { model.setGeometry(restore) }

        let pill = CGRect(
            x: 1180, y: 1408,
            width: NotchGeometryResolver.pillSize.width,
            height: NotchGeometryResolver.pillSize.height)
        model.setGeometry(
            NotchGeometry(
                islandRect: pill,
                panelRect: CGRect(
                    x: pill.midX - NotchGeometryResolver.panelWidth / 2,
                    y: pill.maxY - NotchGeometryResolver.panelHeight,
                    width: NotchGeometryResolver.panelWidth,
                    height: NotchGeometryResolver.panelHeight),
                hasNotch: false,
                screenID: 0))

        var busy = session(
            "notchless",
            state: .running(
                ToolActivity(
                    kind: .bash, toolName: "Bash", target: "swift build", startedAt: Date())))
        busy.gitBranch = "main"
        busy.model = "claude-opus-5"
        busy.effort = "xhigh"
        busy.tokens.contextTokens = 131_100
        busy.linesAdded = 2_241
        busy.linesRemoved = 146
        // A trail and a task block, matching the fixture the notched checks
        // use. A session with no tools at all is not a state a running one
        // reaches, and measuring that instead would test an empty-trail edge
        // case rather than the notchless header this exists for.
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

        for (mode, label) in [(IslandMode.peek, "peek"), (IslandMode.expanded, "expanded")] {
            model.apply(HUDSnapshot(primary: busy))
            model.forcedMode = mode
            let size = model.shapeSize
            let host = NSHostingView(
                rootView: Group {
                    if mode == .peek {
                        PeekContent(session: busy, model: model)
                    } else {
                        ExpandedContent(session: busy, model: model)
                    }
                })
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let needed = host.fittingSize.height
            checks.append(
                Check(
                    name: "the notchless \(label) card is never shorter than its contents",
                    passed: needed <= size.height + 0.5,
                    detail: "content=\(needed) card=\(size.height)"))
        }

        // The header is the row the card actually draws at its top, so the
        // budget reserved for it has to be that row's height. When a cutout
        // exists the two coincide and nothing notices; with no cutout the band
        // is zero and only this says so.
        checks.append(
            Check(
                name: "the notchless card budgets a full header row, not a zero-height band",
                passed: model.bodyTopInset >= model.rowHeight - 0.5,
                detail: "inset=\(model.bodyTopInset) headerRow=\(model.rowHeight) "
                    + "band=\(model.notchBandHeight)"))

        model.forcedMode = nil
        model.apply(HUDSnapshot())

        placementChecks(&checks)
    }

    /// Where the island meets the top of each attached display.
    ///
    /// Needs real screens — `resolve(for:)` reads `visibleFrame`, which is the
    /// whole point: macOS reserves a menu-bar strip on every display when
    /// "Displays have separate Spaces" is on, and subtracting it on a display
    /// that only draws that menu bar while it is active left the pill floating
    /// in bare desktop 36pt down. Reported as skipped rather than faked on a
    /// one-display machine, because a synthetic `NSScreen` cannot report a
    /// reserved strip and a check that cannot run must not look like one that
    /// passed.
    private static func placementChecks(_ checks: inout [Check]) {
        let screens = NSScreen.screens
        guard let menuBarID = NotchGeometryResolver.menuBarScreen()
            .map({ NotchGeometryResolver.displayID(of: $0) })
        else { return }

        for screen in screens {
            let g = NotchGeometryResolver.resolve(for: screen)
            let name = screen.localizedName
            if g.hasNotch {
                checks.append(
                    Check(
                        name: "the cutout on \(name) is flush with the top edge",
                        passed: abs(g.islandRect.maxY - screen.frame.maxY) < 0.5,
                        detail: "island.maxY=\(g.islandRect.maxY) screen=\(screen.frame.maxY)"))
            } else if NotchGeometryResolver.displayID(of: screen) == menuBarID {
                let reserved = screen.frame.maxY - screen.visibleFrame.maxY
                checks.append(
                    Check(
                        name: "the pill on the menu bar's display clears the menu bar",
                        passed: g.islandRect.maxY <= screen.frame.maxY - reserved + 0.5,
                        detail: "island.maxY=\(g.islandRect.maxY) "
                            + "menuBarBottom=\(screen.frame.maxY - reserved)"))
            } else {
                // The gap is the whole point: exactly one hairline, not the
                // reserved menu-bar strip. Asserting the number rather than
                // "near the top" is what would catch the strip creeping back.
                let gap = screen.frame.maxY - g.islandRect.maxY
                checks.append(
                    Check(
                        name: "the pill on \(name) floats one point below the top edge",
                        passed: abs(gap - NotchGeometryResolver.secondaryDisplayTopGap) < 0.5,
                        detail: "gap=\(gap)pt expected="
                            + "\(NotchGeometryResolver.secondaryDisplayTopGap)pt "
                            + "reserved=\(screen.frame.maxY - screen.visibleFrame.maxY)pt"))
            }
        }

        if screens.count < 2 {
            checks.append(
                Check(
                    name: "a second display's pill is pinned to the top edge",
                    skipped: "only one display attached"))
        }
    }

    /// The answer block's height is a constant, not a measurement, so the only
    /// thing keeping the Deny button on the card is this check.
    ///
    /// Measured with a command long enough to wrap onto the three lines the block
    /// allows itself, because that is the tall case: a short command that fits on
    /// one line cannot clip anything, and would pass a budget that is two lines
    /// short of correct.
    private static func answerBlockFitChecks(
        _ checks: inout [Check], model: IslandViewModel
    ) async {
        let command =
            "docker compose -f docker-compose.prod.yml run --rm migrate "
            + "--database postgres://user@db.internal:5432/app --yes --verbose"
        let ask = PermissionAsk(
            toolName: "Bash", kind: .bash, target: String(command.prefix(60)),
            since: Date(), decisionToken: 1, detail: command)

        var waiting = session("waiting", state: .awaitingPermission(ask))
        waiting.gitBranch = "main"
        waiting.model = "claude-opus-5"
        waiting.tokens.contextTokens = 42_000

        checks.append(
            Check(
                name: "an answerable prompt offers its controls",
                passed: {
                    model.apply(HUDSnapshot(primary: waiting))
                    return model.answerablePrompt != nil
                }(),
                detail: "answerablePrompt=\(String(describing: model.answerablePrompt?.toolName))"))

        for (label, mode) in [("peek", IslandMode.peek), ("expanded", IslandMode.expanded)] {
            model.apply(HUDSnapshot(primary: waiting))
            model.forcedMode = mode
            let size = model.shapeSize
            let host: NSHostingView<AnyView> =
                mode == .peek
                ? NSHostingView(
                    rootView: AnyView(PeekContent(session: waiting, model: model)))
                : NSHostingView(
                    rootView: AnyView(ExpandedContent(session: waiting, model: model)))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let needed = host.fittingSize.height

            checks.append(
                Check(
                    name: "\(label) with an answer block is never shorter than its contents",
                    passed: needed <= size.height + 0.5,
                    detail: "content=\(needed) card=\(size.height)"))
        }

        // A card showing a session that is *not* the blocked one draws a line
        // naming the one that is, and that line has a height of its own. The card
        // used to reserve the whole answer block here — being sized to the
        // session on screen, it now reserves only what it draws, so the notice is
        // a term in the budget rather than a passenger in somebody else's.
        //
        // Reaching it takes two blocked sessions: the shown one holds a prompt
        // this HUD cannot settle (answered in the terminal, so no token), while
        // the second holds one it can.
        let terminalAsk = PermissionAsk(
            toolName: "Edit", kind: .write, target: "/tmp/x", since: Date(), siblingCount: 2)
        let elsewhere = session("elsewhere", state: .awaitingPermission(terminalAsk))
        model.apply(HUDSnapshot(primary: elsewhere, others: [waiting]))
        model.forcedMode = .expanded

        checks.append(
            Check(
                name: "a prompt held by another session is named, not silently reserved for",
                passed: model.answerablePrompt == nil && model.anyAnswerablePrompt,
                detail: "shown=\(model.displaySession?.id ?? "nil")"))

        if let shown = model.displaySession {
            let noticeSize = model.shapeSize
            let noticeHost = NSHostingView(rootView: ExpandedContent(session: shown, model: model))
            noticeHost.frame = CGRect(origin: .zero, size: noticeSize)
            noticeHost.layoutSubtreeIfNeeded()
            let noticeNeeded = noticeHost.fittingSize.height

            checks.append(
                Check(
                    name: "the card fits the line pointing at another session's prompt",
                    passed: noticeNeeded <= noticeSize.height + 0.5,
                    detail: "content=\(noticeNeeded) card=\(noticeSize.height)"))
        }

        // The point of the block is that you can read what you are approving, so
        // the card has to grow with the command — and where it stops growing,
        // Allow has to stop being offered. A command that wraps past the cap is
        // the case that made this necessary: the old fixed three-line block drew
        // an ellipsis through the middle of a command and an Allow button beside
        // it, which is the one hazard the terminal does not have.
        let longCommand = String(repeating: "deploy --region eu-west-1 --confirm ", count: 30)
        let longAsk = PermissionAsk(
            toolName: "Bash", kind: .bash, target: String(longCommand.prefix(60)),
            since: Date(), decisionToken: 2, detail: longCommand)
        var longWaiting = session("long", state: .awaitingPermission(longAsk))
        longWaiting.gitBranch = "main"

        model.apply(HUDSnapshot(primary: longWaiting))
        model.forcedMode = .peek
        checks.append(
            Check(
                name: "a command too long to show does not offer Allow",
                passed: !model.canShowCommandInFull(longAsk),
                detail: "lines=\(model.commandLines(longAsk)) cap=\(IslandViewModel.maxCommandLines)"
            ))
        checks.append(
            Check(
                name: "a short command does offer Allow",
                passed: model.canShowCommandInFull(ask),
                detail: "lines=\(model.commandLines(ask))"))

        // Both ends of the growth: a card sized for a one-line command must not
        // clip a three-line one, and a card sized for the cap must not leave a
        // gap under a one-liner.
        for (label, sized) in [("wrapping", waiting), ("capped", longWaiting)] {
            model.apply(HUDSnapshot(primary: sized))
            model.forcedMode = .peek
            let size = model.shapeSize
            let host = NSHostingView(rootView: PeekContent(session: sized, model: model))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            checks.append(
                Check(
                    name: "peek fits a \(label) command without clipping the controls",
                    passed: host.fittingSize.height <= size.height + 0.5,
                    detail: "content=\(host.fittingSize.height) card=\(size.height)"))
        }

        model.apply(HUDSnapshot(primary: longWaiting))
        model.forcedMode = .peek
        let tallCard = model.shapeSize.height
        model.apply(HUDSnapshot(primary: waiting))
        let shortCard = model.shapeSize.height
        checks.append(
            Check(
                name: "the card grows for a longer command",
                passed: tallCard > shortCard,
                detail: "capped=\(tallCard) wrapping=\(shortCard)"))

        // The block is reserved across every session so that changing the
        // selection cannot resize the card mid-decision. Both tiers of that claim
        // are worth stating: reserved when someone is waiting, given back when
        // nobody is.
        model.apply(HUDSnapshot(primary: waiting, others: [session("idle", state: .thinking)]))
        model.forcedMode = .expanded
        let withPrompt = model.shapeSize.height
        model.apply(
            HUDSnapshot(
                primary: session("a", state: .thinking),
                others: [session("idle", state: .thinking)]))
        let withoutPrompt = model.shapeSize.height
        checks.append(
            Check(
                name: "the answer block is given back when nobody is waiting",
                passed: withoutPrompt < withPrompt,
                detail: "waiting=\(withPrompt) none=\(withoutPrompt)"))

        model.forcedMode = nil
        model.apply(HUDSnapshot())
    }

    /// Peek's chip row is conditional, and the height budget has to follow it
    /// both ways.
    ///
    /// Every chip in that row earns its place — lines changed, a cache ratio
    /// gone bad, plan progress — which means all three can be absent at once,
    /// which `output` used to prevent by always being there. Budget for the row
    /// unconditionally and a fresh session gets 41 points of nothing at the
    /// foot of the card; drop it unconditionally and a busy one has its chips
    /// clipped off. Both directions are measured.
    private static func peekFitChecks(_ checks: inout [Check], model: IslandViewModel) async {
        var bare = session("bare", state: .thinking)
        bare.gitBranch = "main"
        bare.model = "claude-opus-5"
        bare.tokens.contextTokens = 42_000

        var busy = bare
        busy.linesAdded = 1_412
        busy.linesRemoved = 386
        busy.tasks = TaskProgress(items: [
            TaskItem(id: "1", subject: "first", status: .completed),
            TaskItem(id: "2", subject: "a reasonably long in-flight task", status: .inProgress),
        ])

        for (label, session) in [("with no chips", bare), ("with chips", busy)] {
            model.apply(HUDSnapshot(primary: session))
            model.forcedMode = .peek
            let size = model.shapeSize
            let host = NSHostingView(rootView: PeekContent(session: session, model: model))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let needed = host.fittingSize.height

            checks.append(
                Check(
                    name: "peek \(label) is never shorter than its contents",
                    passed: needed <= size.height + 0.5,
                    detail: "content=\(needed) card=\(size.height)"))
        }

        // The saving is the whole reason the row is conditional; without this
        // the budget could satisfy the fit checks above by never shrinking.
        model.apply(HUDSnapshot(primary: bare))
        model.forcedMode = .peek
        let bareHeight = model.shapeSize.height
        model.apply(HUDSnapshot(primary: busy))
        let busyHeight = model.shapeSize.height
        checks.append(
            Check(
                name: "peek gives back the chip row when there are no chips",
                passed: bareHeight < busyHeight,
                detail: "bare=\(bareHeight) busy=\(busyHeight)"))

        model.forcedMode = nil
        model.apply(HUDSnapshot())
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
