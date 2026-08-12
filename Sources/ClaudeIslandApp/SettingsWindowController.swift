import AppKit
import SwiftUI

/// A window that will not carry a toolbar.
///
/// `NavigationSplitView` installs one whether or not anything asked for it, and
/// this window wants neither half of what it brings. The sidebar toggle offers
/// to collapse a sidebar that is deliberately pinned — five fixed panes, nothing
/// to hide, and a detail column with no other way to say which pane it is
/// showing. The tracking separator that comes with it then lays the window's
/// title out inside the sidebar's column, so "ClaudeIsland Settings" arrived as
/// "ClaudeIsland Sett…" in a window with three hundred points of empty title bar
/// to its right.
///
/// Refused here rather than in SwiftUI because SwiftUI cannot refuse it from
/// inside an `NSHostingView`: `.toolbar(removing: .sidebarToggle)` and
/// `.toolbar(.hidden, for: .windowToolbar)` both left the button and the
/// truncation exactly where they were — captures of the window with and without
/// them were identical to the byte. Those modifiers speak to a SwiftUI-owned
/// scene, and this window is AppKit's.
///
/// Overriding the property rather than nilling it after the fact: SwiftUI sets
/// this during layout, so anything that cleared it afterwards would be racing
/// whichever runloop turn that lands on. `--selftest` asserts on the override
/// directly, by handing one over and reading it back.
final class SettingsWindow: NSWindow {
    override var toolbar: NSToolbar? {
        get { nil }
        set { _ = newValue }
    }
}

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

    /// Fired with true when the window comes on screen and false when it leaves,
    /// so state that is only worth maintaining while someone is looking can be
    /// switched off with it. Set once, by `AppController`.
    ///
    /// This has to live here rather than in the view: the window is kept alive
    /// across open/close cycles, so closing it orders it out without removing
    /// the hosted view from the hierarchy — SwiftUI's `onDisappear` never fires,
    /// and anything anchored to it would run forever.
    var onVisibilityChange: ((Bool) -> Void)?

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
        // Sent unconditionally, including on a `show()` for a window that was
        // already up: the observers of this are idempotent, and the alternative
        // is guessing at AppKit's state from here.
        onVisibilityChange?(true)
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
        //
        // The height went 580 → 700 when the display picker and the hover delay
        // moved onto Appearance, under the preview. At 580 they opened below the
        // fold — a pane whose settings you have to scroll to find, sitting under
        // 350 points of preview that looks like the whole of it. 700 still
        // clears the shortest display this is likely to meet: the built-in panel
        // it is drawn for leaves 1130 points between the menu bar and the Dock.
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
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
        window.setContentSize(NSSize(width: 820, height: 700))
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
        onVisibilityChange?(false)
    }

    /// Miniaturising is the other way a window stops being visible without being
    /// closed, and `NSWindow.isVisible` already agrees: it reports false for a
    /// window in the Dock. Without these two the ticker would keep running
    /// against a window nobody can read.
    func windowDidMiniaturize(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onVisibilityChange?(true)
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
