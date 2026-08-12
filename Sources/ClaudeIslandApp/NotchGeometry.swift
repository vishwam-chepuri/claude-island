import AppKit
import ClaudeIslandCore

/// Where the island should be drawn on a given screen.
struct NotchGeometry: Equatable {
    /// Bounds of the physical notch (or the synthetic pill area), in screen
    /// coordinates with the origin bottom-left, as AppKit reports.
    let islandRect: CGRect
    /// The panel's frame: wider and taller than the island so the expanded card
    /// has somewhere to grow into without ever resizing the window.
    let panelRect: CGRect
    /// True when this screen has a real notch.
    let hasNotch: Bool
    let screenID: CGDirectDisplayID

    /// Island size when dormant. On a notched display this must match the
    /// hardware cutout exactly so the shape reads as the cutout itself.
    var dormantSize: CGSize { islandRect.size }

    /// The island's top-centre anchor in panel-local coordinates.
    var anchorInPanel: CGPoint {
        CGPoint(
            x: islandRect.midX - panelRect.minX,
            y: islandRect.maxY - panelRect.minY)
    }
}

enum NotchGeometryResolver {
    /// The panel is the container, not the island. It never resizes; only the
    /// drawn shape inside it does, which is what keeps the morph continuous.
    ///
    /// It has to be wide enough for the widest island the flanking layout can
    /// produce — the shape is centred on the camera, so a long label on one side
    /// widens BOTH flanks. Sized too small, the island is silently clipped to
    /// the window and the layout looks like a truncation bug.
    static let panelWidth: CGFloat = 980
    /// Tall enough for the largest card the expanded layout can produce: four
    /// session rows, an overflow line, a task block with a current item, the NOW
    /// row and a full trail comes to ~465pt. At the previous 320 that card was
    /// silently clipped by the window itself, on top of the separate clipping
    /// bug in its own height budget.
    static let panelHeight: CGFloat = 520

    /// The expanded card's own width, independent of the container.
    static let cardWidth: CGFloat = 460

    /// Fallback pill dimensions on a notchless display. Sized to read like a
    /// notch rather than a floating widget.
    static let pillSize = CGSize(width: 200, height: 32)

    /// The display the HUD is to be drawn on, and whether that is the one that
    /// was asked for.
    struct ResolvedDisplay {
        let screen: NSScreen
        /// The stored display name, when nothing attached answers to it. The HUD
        /// is on the menu-bar display in that case — never nowhere.
        let missing: String?

        var geometry: NotchGeometry { NotchGeometryResolver.resolve(for: screen) }
    }

    /// Resolve geometry for the display the HUD is pinned to, or — with no
    /// preference, or one that is not plugged in — the one that owns the menu bar.
    static func current(preferredDisplay: String? = nil) -> NotchGeometry? {
        resolveDisplay(preferred: preferredDisplay)?.geometry
    }

    /// Turns a stored display name into a live `NSScreen`.
    ///
    /// The rule itself lives in `DisplaySelection`, over a list of names, so the
    /// case that matters — a chosen display that is not attached — is testable
    /// without unplugging anything. All this adds is the AppKit half: which names
    /// are attached, and which of them is the menu bar's.
    ///
    /// Nothing here writes to settings. A monitor that is merely asleep, or
    /// unplugged for the afternoon, must come back to the display the user chose
    /// rather than to whatever we quietly saved instead.
    static func resolveDisplay(preferred: String?) -> ResolvedDisplay? {
        let screens = NSScreen.screens
        guard
            let resolution = DisplaySelection.resolve(
                preferred: preferred,
                attached: screens.map(\.localizedName),
                // The menu bar's display is `screens.first`; see `menuBarScreen()`.
                menuBarIndex: 0)
        else { return nil }
        return ResolvedDisplay(screen: screens[resolution.index], missing: resolution.missing)
    }

    /// The displays a picker should offer, in AppKit's order, with duplicate
    /// names collapsed — see `DisplaySelection.options`, which is also where the
    /// reason two identical monitors cannot be told apart is written down.
    static func attachedDisplayNames() -> [String] {
        DisplaySelection.options(attached: NSScreen.screens.map(\.localizedName), chosen: nil)
    }

    /// The screen holding the menu bar is `NSScreen.screens.first` — AppKit
    /// orders that array with the active display first, which is not the same
    /// as `NSScreen.main` (that follows the key window, and this app never has
    /// one).
    static func menuBarScreen() -> NSScreen? {
        NSScreen.screens.first
    }

    /// The window server's id for a screen.
    ///
    /// Carried in the geometry, and the only thing that identifies a screen
    /// unambiguously *within one session* — which is why it is what a check
    /// compares, and why it is not what the setting stores. See
    /// `DisplaySelection` for the difference between those two jobs.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    static func resolve(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let displayID = displayID(of: screen)

        let island: CGRect
        let hasNotch: Bool

        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
            right.minX > left.maxX
        {
            // The notch is the gap the menu bar cannot use, between the two
            // auxiliary areas. Measured on this hardware: left ends at 790,
            // right starts at 1010 -> a 220pt cutout on an 1800pt display.
            let height = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : left.height
            island = CGRect(
                x: frame.minX + left.maxX,
                y: frame.maxY - height,
                width: right.minX - left.maxX,
                height: height)
            hasNotch = true
        } else {
            // Notchless: a pill centred at the top, same visual language.
            //
            // How far down it hangs depends on whether this display owns the
            // menu bar. On the one that does, the menu bar is always drawn, so
            // the pill sits below it — overlapping it would cover live content.
            //
            // On any other display it goes flush against the top edge, where
            // the notch sits on the built-in. macOS reserves a menu-bar strip
            // on every display when "Displays have separate Spaces" is on (the
            // default) — 30pt on the monitor this was found with — but only
            // *draws* that menu bar while the display is active. Subtracting it
            // unconditionally left the island floating 36pt below the top with
            // bare desktop above it, which reads as a misplacement rather than
            // as a cutout. In the rare moment that display is active and does
            // draw its menu bar, the island sits in the menu bar band exactly
            // as the notch does on the built-in, and it is centred where the
            // bar carries nothing.
            let ownsMenuBar =
                menuBarScreen().map { NotchGeometryResolver.displayID(of: $0) == displayID } ?? true
            let topInset = ownsMenuBar ? (frame.maxY - screen.visibleFrame.maxY) + 6 : 0
            island = CGRect(
                x: frame.midX - pillSize.width / 2,
                y: frame.maxY - topInset - pillSize.height,
                width: pillSize.width,
                height: pillSize.height)
            hasNotch = false
        }

        // Centre the panel horizontally on the island and hang it downward.
        var panel = CGRect(
            x: island.midX - panelWidth / 2,
            y: island.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight)

        // Keep the panel on-screen if the island sits near an edge.
        if panel.minX < frame.minX { panel.origin.x = frame.minX }
        if panel.maxX > frame.maxX { panel.origin.x = frame.maxX - panel.width }

        return NotchGeometry(
            islandRect: island, panelRect: panel, hasNotch: hasNotch, screenID: displayID)
    }
}
