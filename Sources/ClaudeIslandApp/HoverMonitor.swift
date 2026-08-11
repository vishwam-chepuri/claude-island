import AppKit

/// Decides, from the cursor position, whether the panel should accept mouse
/// events at all.
///
/// The obvious approach — an `NSTrackingArea` toggling `ignoresMouseEvents` —
/// is circular: once the panel ignores mouse events it receives none, so the
/// tracking area can never fire `mouseEntered` to switch it back. A global
/// monitor runs outside the panel and sees the cursor regardless. Mouse-only
/// global monitors need no Accessibility permission (keyboard ones do).
///
/// The monitor is installed only while a session is active. With no sessions
/// there is nothing to hover, and an always-on monitor would spend CPU on every
/// mouse move for nothing.
///
/// It answers two questions that used to be one, and are no longer the same
/// question once `openDelay` is nonzero: *where is the pointer* — which decides
/// click-through and can never lag — and *is the island being hovered*, which
/// the HUD opens on and which waits the pointer out. `isOverShape` is the first,
/// `isInside` the second.
@MainActor
final class HoverMonitor {
    private weak var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Screen-coordinate rect the island currently occupies. Updated as the
    /// shape morphs so the interactive region always matches what is drawn.
    private var interactiveRect: CGRect = .zero
    /// Where the cursor actually is, right now. Drives click-through, which can
    /// never be delayed — see `evaluate`.
    private var isOverShape = false
    /// The last value handed to `onHoverChange`. Lags `isOverShape` by the open
    /// delay on the way in, and by nothing at all on the way out.
    private var isInside = false

    /// The pending open, if the cursor is sitting inside the shape and the delay
    /// has not elapsed. One-shot, created on the way in and invalidated on the
    /// way out — never periodic, and never left behind by `stop()`.
    private var pendingOpen: Timer?

    /// How long the cursor must rest inside the shape before the card is
    /// reported as hovered.
    ///
    /// Hover-*in* only, and deliberately so. Leaving is instant because a card
    /// that lingers over the window you just moved the pointer to is in the way,
    /// with no way to dismiss it but to wait; where an open that arrives 150ms
    /// late costs nothing, because nothing is covered yet. The asymmetry is the
    /// feature: the delay's whole job is to ignore a pointer *passing through*
    /// on its way to the menu bar, and a pointer passing through has left by the
    /// time it matters.
    ///
    /// Live: `AppController.applySettings` writes this on every settings change.
    /// A countdown already in flight keeps the delay it was scheduled with — at
    /// most one card opens on the old timing, and cancelling it would mean the
    /// slider could swallow a hover that was already underway.
    ///
    /// Zero means zero. Not "a very short timer", not a hop through the run
    /// loop: `evaluate` reports the open inline, on the same event, in the same
    /// order every build before this setting did.
    var openDelay: TimeInterval

    /// Called when the cursor enters or leaves the island shape — after the
    /// delay on entry, immediately on exit.
    var onHoverChange: ((Bool) -> Void)?
    /// Called when a click lands anywhere outside the island shape, so a pinned
    /// card can dismiss itself the way a popover would.
    var onClickOutside: (() -> Void)?

    /// `openDelay` defaults to none so that anything constructing a monitor
    /// without an opinion — the self-test's hover checks — behaves exactly as
    /// this class did before the setting existed. The app passes the stored
    /// value.
    init(panel: NSPanel, openDelay: TimeInterval = 0) {
        self.panel = panel
        self.openDelay = openDelay
    }

    var isRunning: Bool { globalMonitor != nil }

    /// Whether an open is counting down. Exposed for the self-test, which
    /// asserts on the timer's existence rather than on how the card looks: "the
    /// card did not open" and "nothing is scheduled" are different claims, and
    /// only the second one is the idle-CPU contract.
    var hasPendingOpen: Bool { pendingOpen != nil }

    /// What was last reported to `onHoverChange`, for the same reason.
    var isReportedInside: Bool { isInside }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
        ]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // The global monitor is silent while our own app is active, which
        // happens whenever the menu bar extra's menu is open.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
        ]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    /// Leaves nothing scheduled and nothing installed.
    ///
    /// `AppController.apply` calls this the moment the last session ends, which
    /// is what keeps idle cost at zero rather than merely low — so a pending
    /// open must die here too. A one-shot timer that survived would fire against
    /// a torn-down monitor and open a card over a HUD that has gone dormant.
    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        cancelPendingOpen()
        isOverShape = false
        report(false)
        panel?.ignoresMouseEvents = true
    }

    /// Update the hit region. Passing `.zero` makes the panel fully click-through.
    func setInteractiveRect(_ rect: CGRect, evaluatingAt cursor: CGPoint? = nil) {
        interactiveRect = rect
        // Re-evaluate immediately. The shape can grow or shrink out from under
        // a stationary cursor, and no mouse move would follow to correct it.
        evaluate(at: cursor ?? NSEvent.mouseLocation)
    }

    // MARK: - Private

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        evaluate(at: location)
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // A global mouse-down is by definition in another app; a local one
            // outside the shape is a click on our own transparent area.
            if interactiveRect.isEmpty || !interactiveRect.contains(location) {
                onClickOutside?()
            }
        default:
            break
        }
    }

    private func evaluate(at location: CGPoint) {
        let inside = !interactiveRect.isEmpty && interactiveRect.contains(location)
        guard inside != isOverShape else { return }
        isOverShape = inside
        // Accept clicks only over the visible shape; everywhere else in the
        // panel's frame the click must reach whatever is underneath.
        //
        // Deliberately *not* delayed, unlike the hover report below. This flag
        // decides where a click is delivered, and the honest answer to that is
        // wherever the cursor is now: hold it click-through for the length of
        // the dwell and a click on the resting pill within 150ms of arriving
        // falls through to the menu bar behind it. The delay is about when the
        // card opens, never about who owns the pointer.
        panel?.ignoresMouseEvents = !inside

        if inside {
            scheduleOpen()
        } else {
            // Both lines matter, in this order. Cancelling is what makes a
            // pointer that swept across and left open nothing at all — the
            // pending open is dropped, not deferred to whenever the timer
            // happens to fire.
            cancelPendingOpen()
            report(false)
        }
    }

    /// Opens now, or after the dwell.
    private func scheduleOpen() {
        guard openDelay > 0 else {
            report(true)
            return
        }
        // Cannot already be pending — `isOverShape` only flips to true here —
        // but invalidating first keeps that an assumption this code does not
        // depend on being true.
        cancelPendingOpen()
        let timer = Timer(timeInterval: openDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                // Cleared before the report: opening resizes the shape, which
                // calls straight back into `setInteractiveRect`, and that
                // re-entry must not see a timer that has already fired.
                self?.pendingOpen = nil
                self?.report(true)
            }
        }
        // .common, like the HUD's own ticker: the card should still open on time
        // while a menu somewhere is tracking the run loop.
        RunLoop.main.add(timer, forMode: .common)
        pendingOpen = timer
    }

    private func cancelPendingOpen() {
        pendingOpen?.invalidate()
        pendingOpen = nil
    }

    private func report(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside
        onHoverChange?(inside)
    }
}

extension HoverMonitor {
    /// Drives the same evaluation a real mouse move would, from an explicit
    /// cursor position. Exists because a synthetic `CGWarpMouseCursorPosition`
    /// does not generate the `mouseMoved` event a global monitor observes, so
    /// the self-test cannot probe the live event path.
    func setInteractiveRectForTesting(_ rect: CGRect, cursorAt cursor: CGPoint) {
        setInteractiveRect(rect, evaluatingAt: cursor)
    }
}
