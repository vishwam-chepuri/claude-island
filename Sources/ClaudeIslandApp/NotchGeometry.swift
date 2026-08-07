import AppKit

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

    /// Resolve geometry for the screen that currently owns the menu bar.
    static func current() -> NotchGeometry? {
        guard let screen = menuBarScreen() else { return nil }
        return resolve(for: screen)
    }

    /// The screen holding the menu bar is `NSScreen.screens.first` — AppKit
    /// orders that array with the active display first, which is not the same
    /// as `NSScreen.main` (that follows the key window, and this app never has
    /// one).
    static func menuBarScreen() -> NSScreen? {
        NSScreen.screens.first
    }

    static func resolve(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let displayID =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0

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
            // Notchless: a pill centred under the menu bar, same visual
            // language. Sits just below the menu bar rather than under it.
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            island = CGRect(
                x: frame.midX - pillSize.width / 2,
                y: frame.maxY - menuBarHeight - pillSize.height - 6,
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
