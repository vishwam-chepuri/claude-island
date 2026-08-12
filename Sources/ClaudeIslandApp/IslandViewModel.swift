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

    /// Maps the stored `forcedMode` string onto a tier. Unknown and absent both
    /// mean "not pinned" — a typo in the settings file must not pin the HUD to
    /// something arbitrary.
    init?(forcedName: String?) {
        switch forcedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "compact": self = .compact
        case "alert": self = .alert
        case "peek": self = .peek
        case "expanded": self = .expanded
        default: return nil
        }
    }
}

/// What the island's edge should be doing.
///
/// The edge is reserved for the two events worth looking up for. A running
/// session gets nothing: it is the longest-lived state there is, and an edge lit
/// most of the time is one the eye stops reading.
enum BorderPulse: Equatable {
    /// A permission prompt. Repeating, yellow — a standing condition that stays
    /// true until you answer, so its signal has to stay visible.
    case attention
    /// A session just finished. One shot, blue — an instant, not a condition, so
    /// it must not linger.
    case completion
}

@MainActor
@Observable
final class IslandViewModel {
    private(set) var snapshot = HUDSnapshot()
    private(set) var geometry: NotchGeometry?
    /// The reset countdown keeps moving while every session is still, so the
    /// ticker has to follow the card being open as well as work being done.
    var isHovered = false {
        didSet { if oldValue != isHovered { syncTicker() } }
    }
    /// Set by clicking the island. Keeps the card open after the cursor leaves,
    /// so it can actually be read; hover alone collapses the moment you move.
    private(set) var isPinnedOpen = false
    /// Set false from the settings window; the HUD hides and all timers stop.
    /// Seeded from `IslandSettings.hudEnabled` by `AppController`.
    var isEnabled = true
    /// Answers a permission prompt. Set by `AppController`, which owns the socket
    /// the waiting hook client is on.
    var onAnswerPermission: ((UInt64, PermissionDecision) -> Void)?
    /// Development aid, off by default. See `IslandSettings.debugTint`.
    var debugTint = false
    /// Development aid: pins the HUD to a tier so peek and expanded can be
    /// inspected without a real cursor. See `IslandSettings.forcedMode`.
    ///
    /// Defaults here are all inert — every one of these is seeded from settings
    /// by `AppController`, and the self-test drives them directly.
    var forcedMode: IslandMode?

    /// Drives elapsed-time labels. Nil — and therefore not scheduled at all —
    /// whenever nothing is running. This is the idle-CPU contract: no session,
    /// no timer, no redraws.
    private(set) var tick = Date()
    private var tickTimer: Timer?

    /// The session whose completion is currently being announced, if any.
    /// Cleared by a one-shot timer — a completion is an instant, so nothing here
    /// outlives its own window.
    private(set) var completionPulseID: String?
    private var completionTimer: Timer?
    /// Every session's state as of the last snapshot, so a completion can be
    /// detected as a crossing rather than as a condition.
    private var lastStates: [String: SessionState] = [:]

    /// How long a completion is announced for: the sweep reaches the flares,
    /// holds long enough to read the name, then fades.
    static let completionPulseDuration: TimeInterval = 1.8

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

    /// Which pulse the edge should run, if any.
    ///
    /// A prompt outranks a completion: it blocks Claude entirely, and the edge
    /// can only say one thing at a time.
    var borderPulse: BorderPulse? {
        guard mode != .dormant else { return nil }
        if mode == .alert { return .attention }
        if let id = completionPulseID, displaySession?.id == id { return .completion }
        return nil
    }

    var primary: Session? { snapshot.primary }
    var others: [Session] { snapshot.others }

    /// The account's 5-hour usage window, when a status-line render has
    /// published one. Not on `Session`: it belongs to every row at once.
    var rateLimit: RateLimitWindow? { snapshot.rateLimit }

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
    ///
    /// A session announcing its completion takes over too, but only briefly and
    /// only if you are not already reading something: hover and pin both hold
    /// the display where it is, because losing your place mid-read costs more
    /// than a completion notice is worth.
    var displaySession: Session? {
        if let alerting = allSessions.first(where: { $0.state.isAlert }) { return alerting }
        if let id = completionPulseID, !isHovered, !isPinnedOpen,
            let finished = allSessions.first(where: { $0.id == id })
        {
            return finished
        }
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
    ///   subline 13 + meta 13 + context block 22, three gaps of 7, plus top and
    ///   bottom. The chip row is added separately: it is conditional now, so a
    ///   constant that included it would leave a hole whenever it did not draw.
    static let peekBodyHeight: CGFloat =
        bodyTopPadding + 13 + 7 + 13 + 7 + 22 + bodyBottomPadding
    /// The chip row and the 7pt gap above it.
    static let chipRowHeight: CGFloat = 7 + 34

    /// The answer block's fixed furniture: the gap above it and the button row.
    /// The command area is measured on top of this — see `answerBlockHeight`.
    static let answerBlockChrome: CGFloat = 7 + 26 + 6

    static let commandLineHeight: CGFloat = 12
    /// The font the answer block draws the command in. Measuring with anything
    /// else under-measures and the last line gets clipped.
    static let commandFont: NSFont = .monospaced(9.5, weight: .regular)

    /// Where the card stops growing to fit a command.
    ///
    /// Six lines is roughly 500 monospaced characters at this width — past that
    /// the card would be taller than the thing it is meant to be a glance at, and
    /// a command that long wants a terminal anyway. Beyond this the block still
    /// shows what it can, but Allow is withheld; see `canShowCommandInFull`.
    static let maxCommandLines = 6
    /// The 5-hour meter, grouped downward with the list it describes rather
    /// than sitting equidistant between that list and the header above it.
    /// Equidistant, it read as a figure belonging to the shown session, which
    /// is the one thing it is not.
    static let usageWindowTopPadding: CGFloat = 5
    static let usageWindowBottomPadding: CGFloat = 6
    static let usageWindowHeight: CGFloat =
        usageWindowTopPadding + 20 + usageWindowBottomPadding
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
        + bodyBottomPadding  // 13
    // The chip row (`chipRowHeight` + 4 for the taller emphasised figure) and
    // the 5-hour meter are both conditional, so they are added in `shapeSize`
    // rather than tallied here.
    static let expandedChipRowHeight: CGFloat = chipRowHeight + 4
    /// Breathing room between content and the camera cutout.
    static let notchPadding: CGFloat = 12

    var hasNotch: Bool { geometry?.hasNotch == true }

    /// The camera's width, which content must route around. Zero on a display
    /// without one, where the row is simply continuous.
    var notchGap: CGFloat { hasNotch ? (geometry?.islandRect.width ?? 0) : 0 }

    /// The band the camera occupies. Anything drawn here is not on the screen.
    var notchBandHeight: CGFloat { hasNotch ? (geometry?.islandRect.height ?? 38) : 0 }

    /// The flanking row: the camera band plus the lip, so its content centres in
    /// the band the shape actually draws. On a notchless display it is a plain
    /// row. Every tier's header is this same row — see `PeekHeader` — so the lip
    /// has to be in here rather than on the shape alone, or the header would
    /// shift by half a point the moment the card opened.
    var rowHeight: CGFloat {
        // The lip is the band hanging past the *cutout* so its bottom edge does
        // not stop exactly where the hardware does. With no cutout there is
        // nothing to hang past, and adding it anyway drew a resting pill one
        // point taller than the pill the geometry asked for — so changing
        // `pillSize.height` moved the dormant shape and left the one with
        // content in it exactly where it was.
        // No `lineHeight` floor on a notchless display: the pill's height is a
        // deliberate choice there, not a fallback, and flooring it silently
        // ignored a smaller one.
        //
        // Nothing automated guards the lower bound. Two attempts were made:
        // hosting `CompactContent` at the row's height, and hosting it
        // unbounded — both reported it fitting at a 14pt pill, so both were
        // checking nothing and were removed rather than left to look like
        // cover. The label is a fixed-height row that compresses without
        // complaint, so the only honest test is looking at it. 29pt is verified
        // by eye; go much below and check by eye again.
        guard hasNotch else { return pillHeight }
        return max(notchBandHeight, Self.lineHeight) + Self.compactLip
    }

    /// The notchless island's own height, which the resting row matches.
    private var pillHeight: CGFloat {
        geometry?.islandRect.height ?? NotchGeometryResolver.pillSize.height
    }

    /// How far the resting band hangs below the camera band, giving its bottom
    /// edge a line of its own to end on instead of stopping exactly where the
    /// cutout does.
    static let compactLip: CGFloat = 1

    /// Extra rows in peek and expanded start below the header row.
    ///
    /// The header's height, not the camera band's. The two are the same number
    /// on notched hardware — the band is 38pt and a line of text is 30 — which
    /// is why budgeting the band was wrong for a year without showing it. On a
    /// display with no cutout the band is zero while the header is still a full
    /// line, so the card budgeted 1pt for a 31pt row, came out 30pt short of
    /// its own contents, and — because the content is centred in the shape and
    /// then clipped to it — lost half a row off the top and half off the
    /// bottom. That is only reachable since the HUD learned to draw on a second
    /// display; `notchlessFitChecks` is what now measures it on any hardware.
    var bodyTopInset: CGFloat { rowHeight }

    // MARK: - Flanking widths
    //
    // Content sits to the LEFT and RIGHT of the camera, so each side is sized to
    // its own text. Measured with the real font rather than estimated: an
    // under-measured side pushes content into the cutout, where it vanishes.

    private var shownSession: Session? { displaySession }

    func leftClusterWidth(for session: Session) -> CGFloat {
        clusterWidth(leading: compactLeadingText(session))
    }

    /// The open tiers draw the title whole, so they must be measured from the
    /// unclamped string. Measuring the pill's would size the card to an
    /// ellipsis and truncate the very label the card exists to show.
    func headerLeftClusterWidth(for session: Session) -> CGFloat {
        clusterWidth(leading: headerLeadingText(session))
    }

    /// Measured at semibold, the heavier of the two weights the leading label
    /// is drawn in — the pill uses medium, the header and the alert row
    /// semibold. Overshooting the pill costs it a pixel of padding;
    /// undershooting the header would truncate a title mid-word.
    private func clusterWidth(leading: String) -> CGFloat {
        let text = TextMetrics.width(leading, font: .roundedSemibold(11))
        return Self.sidePadding + SessionGlyph.size + 8 + text + Self.notchPadding
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
    var headerLeftClusterWidth: CGFloat { shownSession.map(headerLeftClusterWidth(for:)) ?? 0 }
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
            max(widest, max(headerLeftClusterWidth(for: session), rightClusterWidth(for: session)))
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

    /// The prompt the shown session is blocked on, when this HUD can settle it.
    ///
    /// Nil covers both "not waiting" and "waiting, but not ours to answer" — a
    /// prompt reconstructed from notification prose, replayed from a trace, or
    /// already settled in the terminal. The card must not offer a control it
    /// cannot honour, so every answer affordance hangs off this being non-nil.
    var answerablePrompt: PermissionAsk? {
        guard case .awaitingPermission(let ask) = displaySession?.state, ask.isAnswerable
        else { return nil }
        return ask
    }

    /// Whether any session has a prompt this HUD could settle.
    ///
    /// The expanded card sizes itself across every session so that changing the
    /// selection never resizes it, so the answer block has to be reserved on the
    /// same terms — see `shapeSize`.
    var anyAnswerablePrompt: Bool { !allAnswerablePrompts.isEmpty }

    /// Every prompt this HUD could settle, across all sessions.
    var allAnswerablePrompts: [PermissionAsk] {
        allSessions.compactMap {
            guard case .awaitingPermission(let ask) = $0.state, ask.isAnswerable else { return nil }
            return ask
        }
    }

    /// How many lines the command needs at a given column width.
    ///
    /// Measured rather than assumed, because the whole point of the answer block
    /// is that you can read what you are approving. `TextMetrics` measures one
    /// line, so this divides; word wrapping breaks on token boundaries and can
    /// therefore need one line more than the raw ratio, which is what the margin
    /// absorbs.
    func commandLines(_ ask: PermissionAsk, width: CGFloat? = nil) -> Int {
        let column = (width ?? cardContentWidth) * 0.95
        guard let detail = ask.detail, !detail.isEmpty, column > 20 else { return 0 }
        let measured = TextMetrics.width(detail, font: Self.commandFont)
        return max(1, Int(ceil(measured / column)))
    }

    /// Whether the command can be shown in its entirety.
    ///
    /// Gates the Allow control. Approving a command whose middle has been elided
    /// is the one hazard this feature could add that the terminal does not already
    /// have — the terminal wraps and shows everything. Deny stays available
    /// regardless: refusing something you cannot fully see is always safe.
    func canShowCommandInFull(_ ask: PermissionAsk, width: CGFloat? = nil) -> Bool {
        commandLines(ask, width: width) <= Self.maxCommandLines
    }

    /// Lines the block will actually draw, which is the need clamped to the cap.
    func drawnCommandLines(_ ask: PermissionAsk, width: CGFloat? = nil) -> Int {
        min(commandLines(ask, width: width), Self.maxCommandLines)
    }

    /// Height for the answer block, sized to the tallest command it must show.
    ///
    /// Takes every prompt it may have to display rather than just the current one:
    /// the expanded card is measured across all sessions so that changing the
    /// selection never resizes it mid-decision.
    func answerBlockHeight(for asks: [PermissionAsk], width: CGFloat? = nil) -> CGFloat {
        guard !asks.isEmpty else { return 0 }
        let lines = asks.map { drawnCommandLines($0, width: width) }.max() ?? 1
        return Self.answerBlockChrome + CGFloat(lines) * Self.commandLineHeight
    }
    private var anyCurrentTask: Bool { allSessions.contains { $0.tasks.current != nil } }

    /// Whether peek's chip row draws anything: lines changed, a cache ratio
    /// worth reporting, or plan progress.
    static func peekHasChips(_ s: Session) -> Bool {
        s.hasLineChanges || s.tokens.degradedCacheHitRatio != nil || s.tasks.summary != nil
    }

    /// The same question for the expanded card, which carries no tasks chip —
    /// the plan gets a section of its own further down.
    static func expandedHasChips(_ s: Session) -> Bool {
        s.hasLineChanges || s.tokens.degradedCacheHitRatio != nil
    }

    /// Measured across every session, like the rest of the expanded card's
    /// budget, so browsing the switcher never resizes it.
    private var anyExpandedChips: Bool { allSessions.contains(where: Self.expandedHasChips) }

    /// What each flank of the resting pill measures: the wider side's width,
    /// taken by both.
    ///
    /// The alternative is sizing each side to its own content, which is snugger
    /// — the pill is then never wider than it has to be — but it puts the
    /// cutout off-centre by the difference, and that reads as a mistake rather
    /// than as economy. The shape is the most-looked-at object on the screen
    /// and it sits on a physical feature the eye already uses as a midpoint.
    /// The cost is dead space on the shorter side, usually the right, of the
    /// order of the gap between the title and the status word.
    var evenFlankWidth: CGFloat { max(leftClusterWidth, rightClusterWidth) }

    /// How far the drawn shape sits from the panel's centre.
    ///
    /// Zero everywhere: the panel is centred on the camera and so is every tier
    /// of the island, now that the resting flanks match.
    var shapeOffsetX: CGFloat { 0 }

    /// Width of each flank for the row layout. Equal to each other while
    /// resting; an even split once the card is open, which comes to the same
    /// thing by a different route.
    var flankLeftWidth: CGFloat? {
        switch mode {
        case .compact, .alert: evenFlankWidth
        case .dormant, .peek, .expanded: nil
        }
    }

    var flankRightWidth: CGFloat? {
        switch mode {
        case .compact, .alert: evenFlankWidth
        case .dormant, .peek, .expanded: nil
        }
    }

    /// The resting pill names the session and nothing else. Which tool is
    /// running is detail for the peek; on the pill it churns with every call and
    /// says less than the status word already does.
    func compactLeadingText(_ session: Session) -> String {
        Format.name(session.displayName)
    }

    /// The header the open tiers share. Longer than the pill's label but still
    /// bounded — a hover is a glance, and a header that grew to whatever the
    /// title happened to be made the shape lurch outward on its way open.
    func headerLeadingText(_ session: Session) -> String {
        Format.headerName(session.displayName)
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

    /// Width of the drawn shape for the current mode.
    ///
    /// Split out of `shapeSize` because the answer block's height depends on how
    /// many lines the command wraps to, which depends on the width — while the
    /// width depends on nothing but the header and meta line. Computing it on its
    /// own is what keeps that from being circular.
    var shapeWidth: CGFloat {
        guard let g = geometry else { return 0 }
        let base = g.dormantSize
        let flanking = notchGap + 2 * evenFlankWidth
        switch mode {
        case .dormant:
            return base.width
        case .compact, .alert:
            return max(flanking, base.width + 80)
        case .peek:
            let even = notchGap + 2 * max(headerLeftClusterWidth, rightClusterWidth)
            let meta = displaySession.map(metaLineWidth(for:)) ?? 0
            return Self.withinPanel(max(even, 460, meta))
        case .expanded:
            let evenWidth = notchGap + 2 * widestFlank
            return Self.withinPanel(
                max(evenWidth, NotchGeometryResolver.cardWidth, widestMetaLine))
        }
    }

    /// The width a card body actually has for text, once its own padding is off.
    var cardContentWidth: CGFloat { max(0, shapeWidth - 2 * Self.sidePadding) }

    /// Size of the drawn shape for the current mode.
    var shapeSize: CGSize {
        guard let g = geometry else { return .zero }
        let base = g.dormantSize
        // Centred on the camera: both flanks take the wider one's width, so the
        // cutout sits at the middle of the shape rather than wherever the
        // longer side happens to leave it.
        let flanking = notchGap + 2 * evenFlankWidth

        switch mode {
        case .dormant:
            return base
        case .compact, .alert:
            // The camera band plus a lip, so the island reads as the cutout
            // having grown sideways rather than as a panel hanging below it.
            return CGSize(width: max(flanking, base.width + 80), height: rowHeight)
        case .peek:
            // Peek shows one session and cannot be browsed, so sizing it to that
            // session is fine.
            let taskRow: CGFloat = (displaySession?.tasks.current != nil) ? 28 : 0
            let chips: CGFloat =
                displaySession.map(Self.peekHasChips) == true ? Self.chipRowHeight : 0
            // The open tiers split their flanks evenly, so the width has to fit
            // TWICE the wider side — sizing to the sum truncates the header.
            let answer = answerBlockHeight(for: [answerablePrompt].compactMap { $0 })
            return CGSize(
                width: shapeWidth,
                height: bodyTopInset + Self.peekBodyHeight + chips + taskRow + answer)
        case .expanded:
            // Every term here is measured across all sessions, so switching
            // between them never changes the card's size.
            let rows = CGFloat(min(allSessions.count, Self.maxSessionRows))
            let overflow: CGFloat =
                sessionOverflowCount > 0 ? Self.sessionOverflowRowHeight : 0
            let taskBlock: CGFloat = anyTasks ? (34 + (anyCurrentTask ? 18 : 0)) : 0
            let chipBlock: CGFloat = anyExpandedChips ? Self.expandedChipRowHeight : 0
            let usageBlock: CGFloat = rateLimit != nil ? Self.usageWindowHeight : 0
            let answerBlock = answerBlockHeight(for: allAnswerablePrompts)
            return CGSize(
                width: shapeWidth,
                height: bodyTopInset + Self.expandedChromeHeight + usageBlock + answerBlock
                    + rows * Self.sessionRowHeight + overflow + chipBlock + taskBlock
                    + Self.nowRowTopPadding + Self.nowRowHeight
                    + Self.trailTopPadding + trailBudget)
        }
    }

    /// The hardware's corner, at every tier. A shape that rounds off further as
    /// it grows reads as a panel doing a reveal; a cutout that grows keeps the
    /// curvature it started with.
    var cornerRadius: CGFloat { IslandCorner.radius }

    /// The concave fillet where the shape meets the screen edge. Zero when
    /// dormant, so the resting shape is exactly the cutout and nothing more,
    /// and zero without a cutout, where there is no bezel to flare into.
    var topFlare: CGFloat {
        guard hasNotch else { return 0 }
        return switch mode {
        case .dormant: 0
        case .compact, .alert: 11
        case .peek, .expanded: 14
        }
    }

    /// How the shape meets its top edge. The fallback pill floats below the
    /// menu bar rather than against the bezel, so it rounds instead of flaring.
    var islandTop: IslandTop { hasNotch ? .flare : .rounded }

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
        syncTicker()
    }

    func unpin() {
        isPinnedOpen = false
        syncTicker()
    }

    /// Settles a permission prompt from the card. Silently does nothing for a
    /// prompt with no connection behind it, which is what `isAnswerable` is for —
    /// the controls are not offered in that case.
    func answer(_ ask: PermissionAsk, with decision: PermissionDecision) {
        guard let token = ask.decisionToken else { return }
        onAnswerPermission?(token, decision)
    }

    func apply(_ snapshot: HUDSnapshot) {
        let previous = lastStates
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
        lastStates = Dictionary(
            allSessions.map { ($0.id, $0.state) }, uniquingKeysWith: { _, latest in latest })
        // A session that has gone away takes its pulse with it.
        if let id = completionPulseID, !allSessions.contains(where: { $0.id == id }) {
            endCompletionPulse()
        }
        noteCompletions(since: previous)
        syncTicker()
    }

    /// Starts a completion pulse for the first session that crossed into `done`.
    ///
    /// Suppressed while a prompt is up — a prompt blocks Claude entirely and the
    /// edge can only say one thing — and while a pulse is already running, so a
    /// burst of completions does not make the display hop.
    private func noteCompletions(since previous: [String: SessionState]) {
        guard completionPulseID == nil else { return }
        guard !allSessions.contains(where: { $0.state.isAlert }) else { return }
        let finished = allSessions.first { session in
            guard let was = previous[session.id] else { return false }
            return was != .done && session.state == .done
        }
        guard let finished else { return }
        beginCompletionPulse(finished.id)
    }

    private func beginCompletionPulse(_ id: String) {
        completionPulseID = id
        completionTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.completionPulseDuration, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCompletionPulse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    /// Ends the announcement. Called by the one-shot timer, and directly by the
    /// self-test so the checks do not have to sleep through the window.
    func endCompletionPulse() {
        completionTimer?.invalidate()
        completionTimer = nil
        completionPulseID = nil
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            isPinnedOpen = false
            selectedSessionID = nil
            endCompletionPulse()
        }
        syncTicker()
    }

    /// Whether the card is drawing a countdown that no session's activity keeps
    /// moving.
    ///
    /// `NowRow` shows no elapsed figure on a settled session precisely because
    /// a counter on screen is a promise that it is running — and a frozen one
    /// is the exact bug that row exists to prevent. The reset countdown makes
    /// the same promise while every session is idle, so the card holds the
    /// ticker open for as long as it is drawing one.
    private var showsResetCountdown: Bool {
        mode == .expanded && snapshot.rateLimit?.resetsAt != nil
    }

    /// One shared 1 Hz timer for every elapsed label, running only when
    /// something is actually elapsing.
    private func syncTicker() {
        let wanted = isEnabled && (snapshot.wantsAnimation || showsResetCountdown)
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
        endCompletionPulse()
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
    /// Titles run long — Claude Code's generated ones average five words, and a
    /// `/rename` has no limit at all — while the resting pill sits in the menu
    /// bar and has to stay narrow. 18 keeps it to the two or three words that
    /// carry the subject; the open card shows it whole (`headerLeadingText`).
    ///
    /// Unlike a branch, a title is read rather than matched against something,
    /// so shortening here costs comprehension, not identification.
    ///
    /// Cut on a word, and with no ellipsis. The pill is a label, not a claim to
    /// be complete: "Implement Claude session" reads as a name, where
    /// "Implement Claude sessio…" reads as a name that broke. The card holding
    /// the whole title is one hover away, so nothing here has to advertise that
    /// there is more.
    static func name(_ raw: String, limit: Int = 18) -> String {
        guard raw.count > limit else { return raw }
        let end = raw.index(raw.startIndex, offsetBy: limit)
        let cut = raw[..<end]
        // Already on a boundary — the character we stopped before is the space.
        if raw[end] == " " { return String(cut) }
        // Otherwise back up to the last whole word, unless so little of it
        // survives that the blunt cut says more. One long token has no boundary
        // to find and is left cut.
        if let space = cut.lastIndex(of: " "),
            cut.distance(from: cut.startIndex, to: space) >= limit / 2
        {
            return String(cut[..<space])
        }
        return String(cut)
    }

    /// The open tiers' header: longer than the pill, and marked where it ends.
    ///
    /// The ellipsis the pill omits earns its place here. At 18 characters the
    /// cut lands on a word and reads as a name; at 25 it lands most of the way
    /// through a title, and the mark is what says "there is a little more"
    /// rather than leaving a phrase that looks finished but isn't. The
    /// switcher rows below carry the titles whole, so nothing is out of reach.
    static func headerName(_ raw: String, limit: Int = 25) -> String {
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

    /// `+412 −86`.
    ///
    /// A true minus (U+2212) rather than a hyphen: beside the `+` it has to
    /// match its weight and width, and a hyphen sitting between two numbers
    /// reads as a range.
    ///
    /// Exact below ten thousand, where every other count on the card
    /// abbreviates. A line count is nearly always three or four digits, and
    /// `+412` tells you something `+0.4k` does not — which is the entire reason
    /// this figure replaced a token total.
    static func lines(added: Int, removed: Int) -> String {
        "+\(lineCount(added)) \u{2212}\(lineCount(removed))"
    }

    private static func lineCount(_ n: Int) -> String {
        n < 10_000 ? "\(n)" : tokens(n)
    }

    /// How long until a usage window rolls over. Nil once it has.
    ///
    /// Coarse on purpose. A countdown to the second invites watching it, and
    /// the answer only ever changes a decision at the scale of minutes.
    static func untilReset(_ date: Date, now: Date) -> String? {
        let s = date.timeIntervalSince(now)
        guard s > 0 else { return nil }
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(Int(s) / 60)m" }
        return "\(Int(s) / 3600)h \((Int(s) % 3600) / 60)m"
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
