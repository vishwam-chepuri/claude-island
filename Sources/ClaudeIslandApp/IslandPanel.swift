import AppKit

/// The HUD window.
///
/// An `NSPanel`, not an `NSWindow`, and specifically a non-activating one: the
/// single most important behavioural requirement is that interacting with the
/// island never pulls focus away from the terminal running Claude Code.
final class IslandPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // .nonactivatingPanel is what stops a click from activating the app.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        hidesOnDeactivate = false
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]

        // Transparent window; the island shape is drawn inside it.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // No titlebar affordances, no resize, no move-by-background-drag.
        isMovable = false
        isMovableByWindowBackground = false
        isRestorable = false

        // Belt and braces against ever appearing in window cycling or Exposé.
        animationBehavior = .none
        // Only the shape is interactive; the rest of the frame is switched to
        // click-through by the mouse monitor.
        ignoresMouseEvents = true
    }

    /// Refusing key and main is what makes the panel unable to steal focus.
    /// Without both, clicking the island would defocus the terminal even though
    /// the app never activates.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A borderless panel is not in the responder chain for these by default,
    /// and accepting them would be a route to activation.
    override func makeKey() {}
    override func makeMain() {}
}
