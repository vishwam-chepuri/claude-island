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
@MainActor
final class HoverMonitor {
    private weak var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Screen-coordinate rect the island currently occupies. Updated as the
    /// shape morphs so the interactive region always matches what is drawn.
    private var interactiveRect: CGRect = .zero
    private var isInside = false

    /// Called when the cursor enters or leaves the island shape.
    var onHoverChange: ((Bool) -> Void)?
    /// Called when a click lands anywhere outside the island shape, so a pinned
    /// card can dismiss itself the way a popover would.
    var onClickOutside: (() -> Void)?

    init(panel: NSPanel) {
        self.panel = panel
    }

    var isRunning: Bool { globalMonitor != nil }

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

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        setInside(false)
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
        guard inside != isInside else { return }
        setInside(inside)
    }

    private func setInside(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside
        // Accept clicks only over the visible shape; everywhere else in the
        // panel's frame the click must reach whatever is underneath.
        panel?.ignoresMouseEvents = !inside
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
