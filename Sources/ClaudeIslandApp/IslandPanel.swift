import AppKit

/// The HUD window.
///
/// An `NSPanel`, not an `NSWindow`, and specifically a non-activating one: the
/// single most important behavioural requirement is that interacting with the
/// island never pulls focus away from the terminal running Claude Code.
final class IslandPanel: NSPanel {

    /// `aboveOtherNotchHUDs` defaults to off so a panel built without an opinion
    /// gets the conservative level — the same one every build before the setting
    /// existed used.
    init(contentRect: NSRect, aboveOtherNotchHUDs: Bool = false) {
        super.init(
            contentRect: contentRect,
            // .nonactivatingPanel is what stops a click from activating the app.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = Self.level(aboveOtherNotchHUDs: aboveOtherNotchHUDs)
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

    /// The window level to draw at, and the whole of the policy behind it.
    ///
    /// Off — the default — is `.statusBar + 1`: above the menu bar, and
    /// deliberately no higher, so the HUD never floats above things it should
    /// not. It loses the hit test to any notch app sitting higher, which is
    /// reported by `--selftest` as a conflict rather than a failure.
    ///
    /// On is one above screen-saver level, because that is the only thing that
    /// works: other notch HUDs sit *at* screen-saver level, so 1000 is the
    /// number to beat and anything that beats it is above the screen saver by
    /// definition. There is no middle setting to offer, which is why this is a
    /// switch rather than a slider — and why it is off unless asked for.
    ///
    /// A function rather than two literals at the call sites so the arithmetic
    /// is asserted in one place, and so raising a live panel on a settings
    /// change cannot drift from what `init` chose.
    static func level(aboveOtherNotchHUDs: Bool) -> NSWindow.Level {
        NSWindow.Level(
            rawValue: aboveOtherNotchHUDs
                ? NSWindow.Level.screenSaver.rawValue + 1
                : NSWindow.Level.statusBar.rawValue + 1)
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
