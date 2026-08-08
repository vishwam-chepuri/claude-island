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
    /// Development aid, off by default. See IslandPaths.tintFlag.
    var debugTint = FileManager.default.fileExists(atPath: IslandPaths.tintFlag.path)
    /// Development aid: pins the HUD to a tier so peek and expanded can be
    /// inspected without a real cursor. See IslandPaths.forceModeFlag.
    var forcedMode: IslandMode? = {
        guard
            let raw = try? String(contentsOf: IslandPaths.forceModeFlag, encoding: .utf8)
        else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "peek": return .peek
        case "expanded": return .expanded
        case "alert": return .alert
        case "compact": return .compact
        default: return nil
        }
    }()

    /// Drives elapsed-time labels. Nil — and therefore not scheduled at all —
    /// whenever nothing is running. This is the idle-CPU contract: no session,
    /// no timer, no redraws.
    private(set) var tick = Date()
    private var tickTimer: Timer?

    /// The switcher selection. Nil means "follow automatic priority".
    private(set) var selectedSessionID: String?

    var mode: IslandMode {
        guard isEnabled, let shown = displaySession else { return .dormant }
        if let forcedMode { return forcedMode }
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

    /// Height of the content row that flanks the camera. Sized to sit inside
    /// the menu bar band rather than below it.
    static let lineHeight: CGFloat = 30

    /// Padding between the shape's outer edge and its content.
    static let sidePadding: CGFloat = 12
    /// Gap above the first body row and below the last.
    static let bodyTopPadding: CGFloat = 7
    static let bodyBottomPadding: CGFloat = 13
    static let bodyRowSpacing: CGFloat = 5

    /// Body heights, kept next to the layouts they describe so the shape and
    /// its contents cannot drift apart and clip.
    ///   subline 13 + meta 13 + tokens 30, three gaps, plus top and bottom.
    ///   subline 13 + meta 13 + context block 22 + chip row 34, four gaps of 7.
    static let peekBodyHeight: CGFloat =
        bodyTopPadding + 13 + 7 + 13 + 7 + 22 + 7 + 34 + bodyBottomPadding
    // MARK: Expanded card metrics
    //
    // A budget, not a contract. The trail at the foot of the card is the one
    // flexible region — it absorbs whatever height is left over and scrolls
    // within it — so an error here changes how many rows are visible at rest
    // and can no longer slice a row against the card's clip shape.
    //
    // What these replace was a single opaque `132` covering all of the chrome
    // at once. It undercounted (a tool row is ~18pt, not the 15 it assumed, and
    // it omitted the "recent" label entirely), so the card drew shorter than its
    // own contents and the last row was cut in half.
    static let maxSessionRows = 4
    static let sessionRowHeight: CGFloat = 22
    static let sessionOverflowRowHeight: CGFloat = 14
    static let nowRowTopPadding: CGFloat = 9
    static let nowRowHeight: CGFloat = 28
    static let trailTopPadding: CGFloat = 7
    static let trailLabelHeight: CGFloat = 13
    static let trailRowHeight: CGFloat = 17
    /// How many trail rows the card budgets for. More than this still render —
    /// the trail scrolls — this only sets how many are visible at rest.
    static let visibleTrailRows = 5

    /// Fixed chrome between the header and the NOW row, tallied per block so a
    /// change to any one of them has an obvious place to land.
    static let expandedChromeHeight: CGFloat =
        bodyTopPadding  // 7
        + 12  // "sessions" label row plus its 3pt bottom padding
        + 15  // divider with 7pt above and below
        + 12  // meta line
        + 27  // context label, its 7pt top padding, and the meter
        + 45  // stat chips with 7pt above
        + bodyBottomPadding  // 13
    /// Breathing room between content and the camera cutout.
    static let notchPadding: CGFloat = 12

    var hasNotch: Bool { geometry?.hasNotch == true }

    /// The camera's width, which content must route around. Zero on a display
    /// without one, where the row is simply continuous.
    var notchGap: CGFloat { hasNotch ? (geometry?.islandRect.width ?? 0) : 0 }

    /// The band the camera occupies. Anything drawn here is not on the screen.
    var notchBandHeight: CGFloat { hasNotch ? (geometry?.islandRect.height ?? 38) : 0 }

    /// The flanking row is as tall as the camera band so it sits beside it; on a
    /// notchless display it is a plain row.
    var rowHeight: CGFloat { max(notchBandHeight, Self.lineHeight) }

    /// Extra rows in peek and expanded start below the camera.
    var bodyTopInset: CGFloat { notchBandHeight }

    // MARK: - Flanking widths
    //
    // Content sits to the LEFT and RIGHT of the camera, so each side is sized to
    // its own text. Measured with the real font rather than estimated: an
    // under-measured side pushes content into the cutout, where it vanishes.

    private var shownSession: Session? { displaySession }

    func leftClusterWidth(for session: Session) -> CGFloat {
        // Must match the font the row actually renders in, or the label
        // truncates inside a frame that looked wide enough.
        let text = TextMetrics.width(compactLeadingText(session), font: .roundedMedium(11))
        return Self.sidePadding + 20 + 8 + text + Self.notchPadding
    }

    func rightClusterWidth(for session: Session) -> CGFloat {
        var width = Self.notchPadding
        if let elapsed = compactElapsedText(session) {
            width += TextMetrics.width(elapsed, font: .monospaced(10)) + 8
        }
        width += TextMetrics.width(session.state.statusWord, font: .roundedMedium(10)) + 8
        if attentionCount > 0 { width += 20 }
        width += StatusMark.size + Self.sidePadding
        return width
    }

    var leftClusterWidth: CGFloat { shownSession.map(leftClusterWidth(for:)) ?? 0 }
    var rightClusterWidth: CGFloat { shownSession.map(rightClusterWidth(for:)) ?? 0 }

    // MARK: - Stable sizing for the open card
    //
    // The expanded card must not resize as you browse. Sizing it from the
    // *selected* session made its width follow that session's name length and
    // its height follow that session's tool count, so every click reflowed the
    // whole HUD. Everything below is measured across ALL sessions, so the card
    // is big enough for any of them and only changes when the session set does.

    /// Widest flank any session would need, so the header never reflows.
    private var widestFlank: CGFloat {
        allSessions.reduce(0) { widest, session in
            max(widest, max(leftClusterWidth(for: session), rightClusterWidth(for: session)))
        }
    }

    /// Sessions the switcher has no room to list.
    var sessionOverflowCount: Int { max(0, allSessions.count - Self.maxSessionRows) }

    /// Height reserved for the trail, measured across all sessions so browsing
    /// between them cannot resize the card. Zero until some session has
    /// actually finished a call.
    private var trailBudget: CGFloat {
        let rows = min(maxTrailRows, Self.visibleTrailRows)
        guard rows > 0 else { return 0 }
        return Self.trailLabelHeight + CGFloat(rows) * Self.trailRowHeight
    }

    /// Most finished calls any session would draw. The in-flight call is
    /// excluded — it belongs to the NOW row, not the trail.
    private var maxTrailRows: Int {
        allSessions.reduce(0) { most, session in
            max(most, session.recentTools.filter { $0.endedAt != nil }.count)
        }
    }

    /// Whether any session has a plan, and whether any has one still in flight.
    private var anyTasks: Bool { allSessions.contains { !$0.tasks.isEmpty } }
    private var anyCurrentTask: Bool { allSessions.contains { $0.tasks.current != nil } }

    /// How far the drawn shape sits from the panel's centre.
    ///
    /// The panel is centred on the camera, but the island is not: it extends
    /// exactly as far as each side's content needs, so a long label on the left
    /// grows the shape leftward rather than padding the right.
    var shapeOffsetX: CGFloat {
        switch mode {
        case .compact, .alert: (rightClusterWidth - leftClusterWidth) / 2
        case .dormant, .peek, .expanded: 0
        }
    }

    /// Width of each flank for the row layout. Snug to content while resting;
    /// an even split once the card is open and the shape is wider than needed.
    var flankLeftWidth: CGFloat? {
        switch mode {
        case .compact, .alert: leftClusterWidth
        case .dormant, .peek, .expanded: nil
        }
    }

    var flankRightWidth: CGFloat? {
        switch mode {
        case .compact, .alert: rightClusterWidth
        case .dormant, .peek, .expanded: nil
        }
    }

    /// The resting pill names the session and nothing else. Which tool is
    /// running is detail for the peek; on the pill it churns with every call and
    /// says less than the status word already does.
    func compactLeadingText(_ session: Session) -> String {
        Format.name(session.displayName)
    }

    func compactElapsedText(_ session: Session) -> String? {
        switch session.state {
        case .running(let tool): Format.compactDuration(tool.elapsed(now: tick))
        case .awaitingPermission(let ask): Format.compactDuration(tick.timeIntervalSince(ask.since))
        default: nil
        }
    }

    // MARK: - Meta line
    //
    // branch · model · effort · elapsed. Assembled here rather than in the view
    // so the width the card is sized to and the string the card draws cannot
    // drift apart — the branch is shown in full, and the only thing that keeps
    // that promise is the card being wide enough for it.

    static let metaSpacing: CGFloat = 5

    /// Stand-in for the elapsed figure while measuring. Sizing to the real one
    /// would widen the card a hair every time a digit rolled over, and the
    /// expanded card is meant to hold still.
    private static let elapsedMeasuringStick = "88h 88m"

    static func metaParts(for session: Session, elapsed: String) -> [String] {
        var out: [String] = []
        if let branch = Format.branch(session.gitBranch) { out.append(branch) }
        if let model = Format.model(session.model) { out.append(model) }
        if let effort = session.effort, !effort.isEmpty { out.append(effort) }
        out.append(elapsed)
        return out
    }

    /// Width the meta line needs to draw in full, body padding included.
    ///
    /// `Format.branch` refuses to abbreviate, so this is what makes that stick:
    /// without it SwiftUI would simply do the truncating instead, at the card's
    /// edge, and the label would be no more readable for having been left whole.
    func metaLineWidth(for session: Session) -> CGFloat {
        let parts = Self.metaParts(for: session, elapsed: Self.elapsedMeasuringStick)
        guard !parts.isEmpty else { return 0 }
        // Same fonts the row renders in — an estimate here truncates the very
        // label this exists to protect.
        let text = parts.reduce(CGFloat(0)) {
            $0 + TextMetrics.width($1, font: .systemFont(ofSize: 10))
        }
        let separator = TextMetrics.width("·", font: .systemFont(ofSize: 9)) + 2 * Self.metaSpacing
        return text + CGFloat(parts.count - 1) * separator + 2 * Self.sidePadding
    }

    /// Widest meta line any session would need, so the card does not resize as
    /// you browse — the same rule `widestFlank` follows.
    private var widestMetaLine: CGFloat {
        allSessions.reduce(0) { max($0, metaLineWidth(for: $1)) }
    }

    /// The panel is a fixed container the shape is drawn inside, so a card wider
    /// than it is not a wide card — it is a clipped one. Growing to fit a branch
    /// stops here; git allows 255 bytes, and past roughly 160 characters nothing
    /// on this screen can show the name whole.
    private static func withinPanel(_ width: CGFloat) -> CGFloat {
        min(width, NotchGeometryResolver.panelWidth)
    }

    /// Size of the drawn shape for the current mode.
    var shapeSize: CGSize {
        guard let g = geometry else { return .zero }
        let base = g.dormantSize
        // Sized to its content, not centred on the camera. Forcing symmetry
        // would make the shorter side carry dead space equal to the difference.
        let flanking = leftClusterWidth + notchGap + rightClusterWidth

        switch mode {
        case .dormant:
            return base
        case .compact, .alert:
            // Exactly the camera band tall, so the island reads as the cutout
            // having grown sideways rather than as a panel hanging below it.
            return CGSize(width: max(flanking, base.width + 80), height: rowHeight)
        case .peek:
            // Peek shows one session and cannot be browsed, so sizing it to that
            // session is fine.
            let taskRow: CGFloat = (displaySession?.tasks.current != nil) ? 28 : 0
            // The open tiers split their flanks evenly, so the width has to fit
            // TWICE the wider side — sizing to the sum truncates the header.
            let even = notchGap + 2 * max(leftClusterWidth, rightClusterWidth)
            let meta = displaySession.map(metaLineWidth(for:)) ?? 0
            return CGSize(
                width: Self.withinPanel(max(even, 460, meta)),
                height: bodyTopInset + Self.peekBodyHeight + taskRow)
        case .expanded:
            // Every term here is measured across all sessions, so switching
            // between them never changes the card's size.
            let rows = CGFloat(min(allSessions.count, Self.maxSessionRows))
            let overflow: CGFloat =
                sessionOverflowCount > 0 ? Self.sessionOverflowRowHeight : 0
            let taskBlock: CGFloat = anyTasks ? (34 + (anyCurrentTask ? 18 : 0)) : 0
            let evenWidth = notchGap + 2 * widestFlank
            return CGSize(
                width: Self.withinPanel(
                    max(evenWidth, NotchGeometryResolver.cardWidth, widestMetaLine)),
                height: bodyTopInset + Self.expandedChromeHeight
                    + rows * Self.sessionRowHeight + overflow + taskBlock
                    + Self.nowRowTopPadding + Self.nowRowHeight
                    + Self.trailTopPadding + trailBudget)
        }
    }

    /// Only the bottom corners are drawn; the top edge is flush with the screen.
    var cornerRadius: CGFloat {
        switch mode {
        case .dormant: hasNotch ? 12 : 16
        case .compact, .alert: 18
        case .peek: 26
        case .expanded: 30
        }
    }

    /// The concave fillet where the shape meets the screen edge. Zero when
    /// dormant, so the resting shape is exactly the cutout and nothing more.
    var topFlare: CGFloat {
        switch mode {
        case .dormant: 0
        case .compact, .alert: 11
        case .peek, .expanded: 14
        }
    }

    /// The drawn shape in screen coordinates, for the hover monitor's hit test.
    ///
    /// Always exactly the shape being rendered, so the region the panel accepts
    /// clicks in and the region the user can see are the same thing.
    var interactiveScreenRect: CGRect {
        guard let g = geometry else { return .zero }
        let size = shapeSize
        // The concave fillets flare past the frame at the top, so the visible
        // shape is slightly wider than shapeSize. The hit region has to match
        // what is drawn, not what was measured.
        return CGRect(
            x: g.islandRect.midX + shapeOffsetX - size.width / 2 - topFlare,
            y: g.islandRect.maxY - size.height,
            width: size.width + topFlare * 2,
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
    ///
    /// "Your turn" belongs to a permission prompt alone, because it is the only
    /// state with an answer that unblocks work. An idle nudge says "Waiting",
    /// which is what `SessionState.label` and the card's NOW row have always
    /// called it — the pill was the one surface claiming a session was owed
    /// something when it was merely unattended. Read down the column the three
    /// settle into an escalation: Idle, Waiting, Your turn.
    var statusWord: String {
        switch self {
        case .running: "Working"
        case .thinking: "Thinking"
        case .prompting: "Sent"
        case .awaitingPermission: "Your turn"
        case .compacting: "Compacting"
        case .done: "Done"
        case .error: "Failed"
        case .idle(let waiting): waiting ? "Waiting" : "Idle"
        }
    }
}

enum Format {
    /// Session names are user-chosen and can be long; the pill has a fixed slot.
    static func name(_ raw: String, limit: Int = 14) -> String {
        raw.count <= limit ? raw : String(raw.prefix(limit - 1)) + "\u{2026}"
    }

    /// `HEAD` means detached, which reads better than showing the literal.
    ///
    /// Never abbreviated. Every other label here is something you read; a branch
    /// is something you match — against a PR, a worktree, a checkout you are
    /// about to type. `feature/attention-border-des…` identifies nothing, and
    /// the two branches it could be are exactly the pair you need told apart.
    /// The card is sized to fit it instead (`metaLineWidth`).
    static func branch(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw == "HEAD" ? "detached" : raw
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
