import AppKit
import ClaudeIslandCore
import Combine
import SwiftUI

/// The four shapes the island takes.
enum IslandMode: Equatable {
    /// Exactly notch-shaped, invisible against the cutout. No sessions.
    case dormant
    /// Pill with a tool glyph, elapsed timer and an activity indicator.
    case compact
    /// A permission request. Loud.
    case alert
    /// The card, on hover or click.
    case expanded
}

@MainActor
@Observable
final class IslandViewModel {
    private(set) var snapshot = HUDSnapshot()
    private(set) var geometry: NotchGeometry?
    var isHovered = false
    /// Set by clicking the island. Keeps the card open after the cursor leaves,
    /// so it can actually be read; hover alone collapses the moment you move.
    private(set) var isPinnedOpen = false
    /// Set false by the menu bar extra; the HUD hides and all timers stop.
    var isEnabled = true

    /// Drives elapsed-time labels. Nil — and therefore not scheduled at all —
    /// whenever nothing is running. This is the idle-CPU contract: no session,
    /// no timer, no redraws.
    private(set) var tick = Date()
    private var tickTimer: Timer?

    var mode: IslandMode {
        guard isEnabled, let primary = snapshot.primary else { return .dormant }
        if isPinnedOpen || isHovered { return .expanded }
        if primary.state.isAlert { return .alert }
        if case .idle = primary.state, snapshot.sessionCount == 1 { return .dormant }
        if case .done = primary.state { return .dormant }
        return .compact
    }

    var primary: Session? { snapshot.primary }
    var others: [Session] { snapshot.others }

    /// Size of the drawn shape for the current mode.
    var shapeSize: CGSize {
        guard let g = geometry else { return .zero }
        let base = g.dormantSize
        switch mode {
        case .dormant:
            return base
        case .compact:
            return CGSize(width: max(base.width + 170, 300), height: base.height + 6)
        case .alert:
            return CGSize(width: max(base.width + 210, 340), height: base.height + 14)
        case .expanded:
            let rows = min(others.count, 3)
            return CGSize(
                width: NotchGeometryResolver.panelWidth - 24,
                height: 150 + CGFloat(rows) * 22 + base.height)
        }
    }

    var cornerRadius: CGFloat {
        switch mode {
        case .dormant: geometry?.hasNotch == true ? 12 : 16
        case .compact: 18
        case .alert: 20
        case .expanded: 26
        }
    }

    /// The drawn shape in screen coordinates, for the hover monitor's hit test.
    ///
    /// Always exactly the shape being rendered, so the region the panel accepts
    /// clicks in and the region the user can see are the same thing.
    var interactiveScreenRect: CGRect {
        guard let g = geometry else { return .zero }
        let size = shapeSize
        return CGRect(
            x: g.islandRect.midX - size.width / 2,
            y: g.islandRect.maxY - size.height,
            width: size.width,
            height: size.height)
    }

    // MARK: - Wiring

    func setGeometry(_ g: NotchGeometry?) {
        geometry = g
    }

    func togglePinned() {
        isPinnedOpen.toggle()
    }

    func unpin() {
        isPinnedOpen = false
    }

    func apply(_ snapshot: HUDSnapshot) {
        self.snapshot = snapshot
        // Nothing left to pin open once the last session goes away.
        if snapshot.primary == nil { isPinnedOpen = false }
        syncTicker()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { isPinnedOpen = false }
        syncTicker()
    }

    /// One shared 1 Hz timer for every elapsed label, running only when
    /// something is actually elapsing.
    private func syncTicker() {
        let wanted = isEnabled && snapshot.wantsAnimation
        if wanted, tickTimer == nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick = Date() }
            }
            // .common so the label keeps counting while a menu is tracking.
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !wanted, tickTimer != nil {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}

// MARK: - Formatting

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func compactDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%dh%02d", s / 3600, (s % 3600) / 60)
    }

    static func tokens(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(format: "%.2fM", Double(n) / 1_000_000)
    }

    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// `claude-opus-5` reads better as `Opus 5` at 10pt.
    static func model(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var name = raw
        for prefix in ["claude-", "anthropic."] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        // Drop a trailing date stamp like -20251001.
        let parts = name.split(separator: "-").filter { !($0.count == 8 && Int($0) != nil) }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
