import AppKit

/// Measures text with the font it will actually be drawn in.
///
/// The flanking layout needs real widths, not estimates: each side is sized
/// independently and an under-measured side pushes its content into the camera
/// cutout, where it is not merely clipped but absent.
@MainActor
enum TextMetrics {
    private static var cache: [String: CGFloat] = [:]

    static func width(_ text: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)"
        if let hit = cache[key] { return hit }
        // A hair of slack absorbs any residual difference between AppKit's
        // metrics and SwiftUI's typesetting. Overshooting costs a pixel of
        // padding; undershooting truncates the label.
        let measured = (text as NSString)
            .size(withAttributes: [.font: font]).width.rounded(.up) + 2
        // Bounded so a long-running HUD cannot accumulate every string it ever
        // rendered; the set of labels in play at once is tiny.
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = measured
        return measured
    }
}

extension NSFont {
    /// Matches `.system(size:weight:design: .rounded)` in the SwiftUI views.
    static func roundedMedium(_ size: CGFloat) -> NSFont { rounded(size, weight: .medium) }

    /// The weight the header and alert rows draw their session label in.
    static func roundedSemibold(_ size: CGFloat) -> NSFont { rounded(size, weight: .semibold) }

    private static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Weight matters: the compact row renders its target at `.medium`, and
    /// measuring the same string at `.regular` under-measures it by roughly a
    /// character — enough to truncate a label inside a frame sized from it.
    static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}
