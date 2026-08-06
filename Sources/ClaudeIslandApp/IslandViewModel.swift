import AppKit
import ClaudeIslandCore
import Combine
import SwiftUI

/// The four shapes the island takes.
enum IslandMode: Equatable {
    /// Exactly notch-shaped, invisible against the cutout. No sessions.
    case dormant
    /// Pill: glyph + session name (or the live tool target), status on the right.
    case compact
    /// A permission request. Loud.
    case alert
    /// Hover. Adds branch, model, effort, context and plan progress.
    case peek
    /// Click. A switcher across every active session, plus that session's detail.
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

    /// The switcher selection. Nil means "follow automatic priority".
    private(set) var selectedSessionID: String?

    var mode: IslandMode {
        guard isEnabled, let shown = displaySession else { return .dormant }
        if isPinnedOpen { return .expanded }
        if isHovered { return .peek }
        if shown.state.isAlert { return .alert }
        // Every tracked session rests as a single line. `done` and "your turn"
        // used to collapse to dormant, which hid exactly the two states you are
        // most likely to be waiting on.
        return .compact
    }

    var primary: Session? { snapshot.primary }
    var others: [Session] { snapshot.others }

    /// Every tracked session, already ranked by the store.
    var allSessions: [Session] {
        guard let primary = snapshot.primary else { return [] }
        return [primary] + snapshot.others
    }

    /// The session whose details are on screen.
    ///
    /// A permission prompt always takes over, even from an explicit selection —
    /// missing one is worse than losing your place. The selection is kept, not
    /// cleared, so the view returns to it once the prompt is answered.
    var displaySession: Session? {
        if let alerting = allSessions.first(where: { $0.state.isAlert }) { return alerting }
        if let id = selectedSessionID,
            let selected = allSessions.first(where: { $0.id == id })
        {
            return selected
        }
        return snapshot.primary
    }

    /// Other sessions waiting on you. A plain session count says nothing about
    /// whether any of them need attention, which is the only reason to look.
    var attentionCount: Int {
        guard let shown = displaySession else { return 0 }
        return allSessions.filter { $0.id != shown.id && $0.state.needsUser }.count
    }

    func select(_ id: String) {
        selectedSessionID = (selectedSessionID == id) ? nil : id
    }

    var isOverriddenByAlert: Bool {
        guard let id = selectedSessionID, let shown = displaySession else { return false }
        return shown.id != id
    }

    /// Height of one content row. On a notched display the shape must be at
    /// least this much TALLER than the cutout, because anything drawn inside the
    /// notch band simply is not on the screen — it is a hole in the panel.
    static let lineHeight: CGFloat = 30

    /// Vertical space the content must skip to clear the physical cutout.
    var contentTopInset: CGFloat {
        (geometry?.hasNotch == true) ? (geometry?.islandRect.height ?? 38) : 0
    }

    /// Size of the drawn shape for the current mode.
    var shapeSize: CGSize {
        guard let g = geometry else { return .zero }
        let base = g.dormantSize
        switch mode {
        case .dormant:
            return base
        case .compact:
            return CGSize(
                width: max(base.width + 170, 300),
                height: contentTopInset + Self.lineHeight)
        case .alert:
            // Same single-line height as compact — the ask itself moves to the
            // peek. Only the accent and the pulse mark it out at rest.
            return CGSize(
                width: max(base.width + 190, 320),
                height: contentTopInset + Self.lineHeight)
        case .peek:
            let taskRow: CGFloat = (displaySession?.tasks.isEmpty == false) ? 18 : 0
            return CGSize(width: 380, height: contentTopInset + 76 + taskRow)
        case .expanded:
            let rows = CGFloat(min(allSessions.count, 4))
            let tools = CGFloat(min(displaySession?.recentTools.count ?? 0, 3))
            let taskBlock: CGFloat = (displaySession?.tasks.isEmpty == false) ? 34 : 0
            return CGSize(
                width: NotchGeometryResolver.panelWidth - 24,
                height: base.height + 118 + rows * 22 + tools * 15 + taskBlock)
        }
    }

    var cornerRadius: CGFloat {
        switch mode {
        case .dormant: geometry?.hasNotch == true ? 12 : 16
        case .compact: 18
        case .alert: 18
        case .peek: 22
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
        if snapshot.primary == nil {
            isPinnedOpen = false
            selectedSessionID = nil
        }
        // Drop a selection whose session has ended.
        if let id = selectedSessionID, !snapshot.others.contains(where: { $0.id == id }),
            snapshot.primary?.id != id
        {
            selectedSessionID = nil
        }
        syncTicker()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            isPinnedOpen = false
            selectedSessionID = nil
        }
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

extension SessionState {
    /// The single word shown on the compact pill's right side.
    var statusWord: String {
        switch self {
        case .running: "Working"
        case .thinking: "Thinking"
        case .prompting: "Sent"
        case .awaitingPermission: "Your turn"
        case .compacting: "Compacting"
        case .done: "Done"
        case .error: "Failed"
        case .idle(let waiting): waiting ? "Your turn" : "Idle"
        }
    }
}

enum Format {
    /// Session names are user-chosen and can be long; the pill has a fixed slot.
    static func name(_ raw: String, limit: Int = 14) -> String {
        raw.count <= limit ? raw : String(raw.prefix(limit - 1)) + "\u{2026}"
    }

    /// `HEAD` means detached, which reads better than showing the literal.
    static func branch(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw == "HEAD" ? "detached" : name(raw, limit: 20)
    }

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
