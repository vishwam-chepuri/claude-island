import AppKit
import SwiftUI

/// The settings window, and the invisible main menu that makes it usable.
///
/// The app runs `.accessory` (LSUIElement) and must keep doing so — the HUD
/// panel is non-activating precisely so interacting with it never pulls focus
/// off the terminal, and flipping to `.regular` to host a window would put a
/// Dock icon and a menu bar on an app whose whole point is to stay out of the
/// way. An accessory app cannot *display* a menu bar, but `NSApplication` still
/// routes key equivalents through `mainMenu`, so installing one is what makes
/// ⌘C, ⌘V, ⌘W and ⌘Q work inside this window even though nothing renders.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeContent: () -> AnyView

    init(content: @escaping () -> AnyView) {
        self.makeContent = content
        super.init()
        Self.installMainMenuIfNeeded()
    }

    /// What the window ended up doing, for the log.
    ///
    /// Worth keeping past the debugging it was written for: "the settings
    /// window did not open" and "it opened behind your terminal because the
    /// system declined the activation" look identical from the outside, and
    /// this is the only thing that tells them apart.
    var diagnostics: String {
        guard let w = window else { return "no window" }
        return "frame \(w.frame) visible \(w.isVisible) key \(w.isKeyWindow) "
            + "onActiveSpace \(w.isOnActiveSpace) appActive \(NSApp.isActive)"
    }

    func show() {
        // Reopened rather than rebuilt, so a window the user moved or resized
        // comes back where they left it.
        let window = window ?? build()
        self.window = window
        // Accessory apps start out inactive by definition, so ordering the
        // window front is not enough on its own — without activating, it opens
        // behind whatever the user was looking at. `.accessory` is kept
        // throughout: an accessory app is allowed a key window, and flipping to
        // `.regular` to force the point would put a Dock icon and a menu bar on
        // an app whose whole purpose is to have neither.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Belt and braces. If the system declines the activation — it can, for
        // a background app that the user did not visibly launch — the window
        // must at least be on screen rather than silently not open at all.
        window.orderFrontRegardless()
    }

    private func build() -> NSWindow {
        // Wide enough for the sidebar and a pane beside it without the pane's
        // labels wrapping, and tall enough that the longest pane — Hooks, once
        // it is reporting an install — fits above the pinned footer.
        //
        // The 100 points over that came with the Appearance preview. On a
        // notched Mac an open card is around 600pt across, because both flanks
        // have to clear a 220pt cutout, and at the old width the preview opened
        // already shrunk by a fifth. Still only a default: the window resizes,
        // the preview scales to whatever it is given, and `minWidth` is
        // unchanged, so nothing here is load-bearing.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
            // Still resizable: the panes scroll, and a fixed height would clip
            // whichever pane happens to be longest today on a short display.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "ClaudeIsland Settings"
        // The controller owns the window across open/close cycles; without this
        // AppKit frees it on the first close and the second open crashes.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: makeContent())
        window.setContentSize(NSSize(width: 820, height: 580))
        window.center()
        return window
    }

    /// Hands focus back when the window closes.
    ///
    /// Opening settings is the one time this app is allowed to take focus.
    /// Keeping it afterwards would leave the user's keystrokes going to an app
    /// with no windows left to receive them.
    func windowWillClose(_ notification: Notification) {
        NSApp.deactivate()
    }

    // MARK: - Main menu

    private static var menuInstalled = false

    /// Builds a menu that is never drawn, purely so its key equivalents resolve.
    private static func installMainMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true

        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit ClaudeIsland", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
