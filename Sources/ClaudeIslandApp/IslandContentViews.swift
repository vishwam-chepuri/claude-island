import AppKit
import ClaudeIslandCore
import SwiftUI

// MARK: - Compact

struct CompactContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        FlankingRow(model: model) {
            HStack(spacing: 8) {
                SessionGlyph(
                    state: session.state,
                    contextFraction: ContextWindow.fraction(
                        used: session.tokens.contextTokens, model: session.model))
                Text(model.compactLeadingText(session))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        } trailing: {
            HStack(spacing: 8) {
                if let elapsed = model.compactElapsedText(session) {
                    Text(elapsed)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(IslandPalette.tertiary)
                        .monospacedDigit()
                }
                Text(session.state.statusWord)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandPalette.accentPair(for: session.state).gradient)
                if model.attentionCount > 0 {
                    CountBadge(count: model.attentionCount, tint: IslandPalette.alert)
                }
                StatusMark(state: session.state)
            }
        }
    }

}

// MARK: - Alert

struct AlertContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        FlankingRow(model: model) {
            HStack(spacing: 8) {
                PulsingGlyph(
                    symbolName: "hand.raised.fill",
                    color: NSColor(IslandPalette.alert),
                    pointSize: 12,
                    animating: true)
                Text(Format.name(session.displayName))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        } trailing: {
            HStack(spacing: 8) {
                if let elapsed = model.compactElapsedText(session) {
                    Text(elapsed)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(IslandPalette.tertiary)
                        .monospacedDigit()
                }
                Text(session.state.statusWord)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandPalette.alert)
                if model.attentionCount > 0 {
                    CountBadge(count: model.attentionCount, tint: IslandPalette.alert)
                }
                StatusMark(state: session.state)
            }
        }
    }
}

/// Lays a row out either side of the camera cutout.
///
/// The middle segment is empty on purpose: those pixels are a hole in the
/// display, so anything placed there is not drawn at all. On a notchless
/// display the gap collapses to zero and this is an ordinary row.
struct FlankingRow<Leading: View, Trailing: View>: View {
    @Bindable var model: IslandViewModel
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            flank(leading, width: model.flankLeftWidth, alignment: .leading, edge: .leading)

            // The camera. Nothing may be drawn here — these pixels are a hole
            // in the display, not a region that merely gets clipped.
            Color.clear
                .frame(width: model.notchGap)

            flank(trailing, width: model.flankRightWidth, alignment: .trailing, edge: .trailing)
        }
        .frame(height: model.rowHeight)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A fixed width while resting, so each flank is snug to its own content;
    /// an even share once the card is open and the shape is wider than needed.
    ///
    /// The edge padding goes INSIDE the frame. Applied outside, it added
    /// `2 * sidePadding` to a row that was already exactly the shape's width,
    /// and the overflow showed up as a truncated label.
    @ViewBuilder
    private func flank<V: View>(
        _ view: V, width: CGFloat?, alignment: Alignment, edge: Edge.Set
    ) -> some View {
        if let width {
            view
                .padding(edge, IslandViewModel.sidePadding)
                .frame(width: width, alignment: alignment)
        } else {
            view
                .padding(edge, IslandViewModel.sidePadding)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

// MARK: - Peek (hover)

/// Hover detail: what the compact pill shows, plus the context you would
/// otherwise have to switch terminals to find.
struct PeekContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    /// The one line of detail the resting pill had no room for: the pending
    /// question, the running command, or what the finished turn produced.
    private var subline: String? {
        switch session.state {
        case .awaitingPermission(let ask):
            return "Allow \(ask.toolName)?" + (ask.target.map { "  \($0)" } ?? "")
        case .running(let tool):
            return tool.target ?? tool.toolName
        case .error(let message):
            return message
        case .done:
            let tools = session.recentTools.count
            return tools > 0 ? "\(tools) recent tool call\(tools == 1 ? "" : "s")" : nil
        default:
            return session.recentTools.first?.target
        }
    }

    private var subIsMonospaced: Bool {
        if case .running = session.state { return true }
        return false
    }

    private var sublineSymbol: String {
        switch session.state {
        case .running(let tool): tool.kind.symbolName
        case .awaitingPermission: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        default: "clock"
        }
    }

    private var accent: Accent { IslandPalette.accentPair(for: session.state) }
    private var contextFraction: Double {
        ContextWindow.fraction(used: session.tokens.contextTokens, model: session.model)
    }
    private var contextAccent: Accent { IslandPalette.contextAccent(contextFraction) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Full width: FlankingRow supplies its own edge padding, and the
            // gap it leaves has to line up with the real camera.
            PeekHeader(session: session, model: model)

            VStack(alignment: .leading, spacing: 7) {
                if let sub = subline {
                    HStack(spacing: 6) {
                        Image(systemName: sublineSymbol)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(accent.base)
                        Text(sub)
                            .font(
                                .system(
                                    size: 10,
                                    design: subIsMonospaced ? .monospaced : .default)
                            )
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                MetaLine(session: session, tick: model.tick)

                // Context gets a bar rather than a bare figure: the number only
                // means something against the window it is filling.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("CONTEXT")
                            .font(.system(size: 7.5, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(IslandPalette.tertiary)
                        Spacer(minLength: 0)
                        Text(Format.tokens(session.tokens.contextTokens))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(contextAccent.bright)
                            .monospacedDigit()
                        Text(
                            "/ \(Format.tokens(ContextWindow.limit(for: session.model, observed: session.tokens.contextTokens)))"
                        )
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(IslandPalette.tertiary)
                            .monospacedDigit()
                    }
                    MeterBar(fraction: contextFraction, accent: contextAccent)
                }

                HStack(spacing: 7) {
                    StatChip(
                        label: "output", value: Format.tokens(session.tokens.cumulativeOutput),
                        accent: accent)
                    StatChip(
                        label: "cache hit",
                        value: session.tokens.cacheHitRatio.map(Format.percent) ?? "—",
                        accent: IslandPalette.doneAccent)
                    if let summary = session.tasks.summary {
                        StatChip(label: "tasks", value: summary, accent: accent)
                    }
                    Spacer(minLength: 0)
                }

                if let current = session.tasks.current {
                    VStack(alignment: .leading, spacing: 4) {
                        TaskSegments(
                            completed: session.tasks.completed, total: session.tasks.total,
                            accent: accent)
                        CurrentTaskLine(task: current)
                    }
                }
            }
            .padding(.horizontal, IslandViewModel.sidePadding)
            .padding(.top, IslandViewModel.bodyTopPadding)

            Spacer(minLength: 0)
        }
    }
}

/// The identity row shared by peek and expanded: same flanking geometry as the
/// resting pill, so the header does not jump when the card opens.
struct PeekHeader: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        FlankingRow(model: model) {
            HStack(spacing: 8) {
                SessionGlyph(
                    state: session.state,
                    contextFraction: ContextWindow.fraction(
                        used: session.tokens.contextTokens, model: session.model))
                Text(Format.name(session.displayName))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        } trailing: {
            HStack(spacing: 8) {
                Text(session.state.statusWord)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandPalette.accentPair(for: session.state).gradient)
                StatusMark(state: session.state)
            }
        }
        .frame(height: model.bodyTopInset)
    }
}

// MARK: - Expanded (click) — session switcher

struct ExpandedContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    private var accent: Accent { IslandPalette.accentPair(for: session.state) }
    private var contextFraction: Double {
        ContextWindow.fraction(used: session.tokens.contextTokens, model: session.model)
    }
    private var contextAccent: Accent { IslandPalette.contextAccent(contextFraction) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PeekHeader(session: session, model: model)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SectionLabel("sessions")
                    Text("\(model.allSessions.count)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(accent.bright)
                    Spacer(minLength: 0)
                    if model.isOverriddenByAlert {
                        // The selection is kept and will resume; say so rather
                        // than let the view look like it jumped for no reason.
                        Text("permission request took over")
                            .font(.system(size: 8))
                            .foregroundStyle(IslandPalette.alert)
                    }
                }
                .padding(.bottom, 3)

                ForEach(model.allSessions.prefix(IslandViewModel.maxSessionRows)) { candidate in
                    SessionRow(
                        candidate: candidate,
                        isShown: candidate.id == session.id,
                        onSelect: { model.select(candidate.id) })
                }
                // Dropping the fifth session silently put the count in the
                // header at odds with the list directly beneath it.
                if model.sessionOverflowCount > 0 {
                    Text("+\(model.sessionOverflowCount) more")
                        .font(.system(size: 8.5))
                        .foregroundStyle(IslandPalette.tertiary)
                        .padding(.leading, 17)
                        .padding(.top, 2)
                }

                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 7)

                MetaLine(session: session, tick: model.tick)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("CONTEXT")
                            .font(.system(size: 7.5, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(IslandPalette.tertiary)
                        Spacer(minLength: 0)
                        Text(Format.tokens(session.tokens.contextTokens))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(contextAccent.bright)
                            .monospacedDigit()
                        Text(
                            "/ \(Format.tokens(ContextWindow.limit(for: session.model, observed: session.tokens.contextTokens)))"
                        )
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(IslandPalette.tertiary)
                            .monospacedDigit()
                    }
                    MeterBar(fraction: contextFraction, accent: contextAccent)
                }
                .padding(.top, 7)

                HStack(spacing: 7) {
                    StatChip(
                        label: "output", value: Format.tokens(session.tokens.cumulativeOutput),
                        accent: accent, emphasised: true)
                    StatChip(
                        label: "cache hit",
                        value: session.tokens.cacheHitRatio.map(Format.percent) ?? "—",
                        accent: IslandPalette.doneAccent)
                    StatChip(
                        label: "written",
                        value: Format.tokens(session.tokens.cumulativeCacheCreation))
                    Spacer(minLength: 0)
                }
                .padding(.top, 7)

                if !session.tasks.isEmpty {
                    HStack(spacing: 6) {
                        SectionLabel("tasks")
                        Text(session.tasks.summary ?? "")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(accent.bright)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 9)
                    TaskSegments(
                        completed: session.tasks.completed, total: session.tasks.total,
                        accent: accent
                    )
                    .padding(.top, 4)
                    if let current = session.tasks.current {
                        CurrentTaskLine(task: current).padding(.top, 4)
                    }
                }

                NowRow(session: session, now: model.tick)
                    .padding(.top, 9)

                // No trailing Spacer: the trail itself is the flexible region.
                // A Spacer with minLength 0 collapses to nothing under pressure
                // and lets everything above it overflow the card, which is how
                // the last recent row came to be sliced in half.
                TrailSection(session: session)
                    .padding(.top, 7)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, IslandViewModel.sidePadding)
            .padding(.top, IslandViewModel.bodyTopPadding)
            .padding(.bottom, IslandViewModel.bodyBottomPadding)
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 7.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(IslandPalette.tertiary)
    }
}

/// What the shown session is doing at this instant.
///
/// The card used to open onto nothing but finished calls, and a finished call's
/// duration never changes — so a session working right now and one that stopped
/// an hour ago rendered identically, and both read as a hung UI. This row is the
/// only part of the body written in the present tense, and it says so even when
/// the answer is "nothing", which is what stops the history below it from being
/// mistaken for a frozen present.
struct NowRow: View {
    let session: Session
    let now: Date

    private var accent: Accent { IslandPalette.accentPair(for: session.state) }
    private var isLive: Bool { session.state.wantsAnimation }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(accent.wash)
                        .frame(width: 19, height: 19)
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(accent.bright)
                }
                Text(headline)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(IslandPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let elapsed {
                    Text(elapsed)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(accent.bright)
                        .monospacedDigit()
                }
            }
            if isLive {
                LiveRail(base: NSColor(accent.base), bright: NSColor(accent.bright))
                    .frame(height: LiveRail.height)
            }
        }
    }

    private var symbol: String {
        switch session.state {
        case .running(let t): t.kind.symbolName
        case .thinking: "ellipsis"
        case .prompting: "paperplane.fill"
        case .compacting: "arrow.down.right.and.arrow.up.left"
        case .awaitingPermission: "hand.raised.fill"
        case .done: "checkmark"
        case .idle(let waiting): waiting ? "hand.raised.fill" : "moon.zzz.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var headline: String {
        switch session.state {
        case .running(let t): t.toolName
        case .thinking: "Thinking"
        case .prompting: "Prompt sent"
        case .compacting: "Compacting context"
        case .awaitingPermission(let a): "Allow \(a.toolName)?"
        case .done: "Finished"
        case .idle(let waiting): waiting ? "Waiting for you" : "Idle"
        case .error(let m): m
        }
    }

    private var detail: String? {
        switch session.state {
        case .running(let t): t.target
        case .awaitingPermission(let a): a.target
        default: nil
        }
    }

    /// Only live states carry a counter, and the presence of one is therefore a
    /// promise that it is moving. Settled states deliberately show nothing: the
    /// ticker stops when no session wants animation, so an "8s ago" on a
    /// finished session would freeze at 8s and look exactly like the bug this
    /// row exists to fix.
    private var elapsed: String? {
        switch session.state {
        case .running(let t): Format.compactDuration(t.elapsed(now: now))
        case .awaitingPermission(let a): Format.compactDuration(now.timeIntervalSince(a.since))
        case .thinking, .prompting, .compacting:
            Format.compactDuration(now.timeIntervalSince(session.lastEventAt))
        case .done, .idle, .error: nil
        }
    }
}

/// Finished calls, newest first, demoted hard against the NOW row above: no
/// filled plate, dimmer text, tighter leading. The hierarchy is carried by
/// weight, which leaves colour free to mean "this one failed".
///
/// This is the card's one flexible region. It takes whatever height is left
/// after the fixed chrome and scrolls within it, so an error in the height
/// budget shrinks the visible list instead of slicing a row in half against the
/// card's clip shape.
struct TrailSection: View {
    let session: Session

    private var finished: [ToolActivity] {
        // The in-flight call lives in `recentTools` at index 0 as well as in the
        // NOW row above; without this it would appear twice.
        session.recentTools.filter { $0.endedAt != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !finished.isEmpty {
                SectionLabel("recent").padding(.bottom, 3)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(finished) { tool in
                            TrailRow(tool: tool)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // A row half-cut by the viewport edge is indistinguishable from
                // a row half-cut by a layout bug — which is the exact complaint
                // this section exists to answer. Fading the last few points
                // reads as "there is more below" and cannot be mistaken for
                // damage. Harmless when everything fits: the fade lands on
                // empty space.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.82),
                            .init(color: .black.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

struct TrailRow: View {
    let tool: ToolActivity

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tool.failed ? "exclamationmark" : tool.kind.symbolName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(
                    tool.failed ? IslandPalette.errorAccent.bright : IslandPalette.tertiary
                )
                .frame(width: 12)
            Text(tool.toolName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(tool.failed ? 0.82 : 0.55))
            Text(tool.target ?? "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // No `now`: these are finished, so their duration is fixed. Passing
            // a clock in would imply otherwise.
            Text(Format.compactDuration(tool.elapsed()))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

/// One selectable row in the switcher, carrying a state-coloured rail so the
/// list can be scanned by colour before it is read.
struct SessionRow: View {
    let candidate: Session
    let isShown: Bool
    let onSelect: () -> Void

    private var accent: Accent { IslandPalette.accentPair(for: candidate.state) }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(accent.gradient)
                .frame(width: 2.5, height: 15)
                .shadow(color: accent.glow, radius: isShown ? 3 : 0)

            // Constant weight: switching it on selection changed the label's
            // intrinsic width and reflowed the row under the cursor.
            Text(Format.name(candidate.displayName, limit: 22))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(isShown ? .white : .white.opacity(0.62))
                .lineLimit(1)

            Spacer(minLength: 6)

            if candidate.state.needsUser {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(IslandPalette.turnAccent.bright)
            }
            Text(candidate.state.statusWord)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(isShown ? accent.bright : IslandPalette.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isShown ? accent.wash : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isShown ? accent.base.opacity(0.30) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
    }
}

/// branch · model · effort · elapsed — the identity line shared by peek and
/// expanded.
struct MetaLine: View {
    let session: Session
    let tick: Date

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·").font(.system(size: 9)).foregroundStyle(IslandPalette.tertiary)
                }
                Text(part)
                    .font(.system(size: 10))
                    .foregroundStyle(IslandPalette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var parts: [String] {
        var out: [String] = []
        if let branch = Format.branch(session.gitBranch) { out.append(branch) }
        if let model = Format.model(session.model) { out.append(model) }
        if let effort = session.effort, !effort.isEmpty { out.append(effort) }
        out.append(Format.duration(session.age(now: tick)))
        return out
    }
}

struct CurrentTaskLine: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 5) {
            Image(
                systemName: task.status == .inProgress
                    ? "arrow.triangle.2.circlepath" : "circle.dotted"
            )
            .font(.system(size: 8))
            .foregroundStyle(
                task.status == .inProgress ? IslandPalette.running : IslandPalette.tertiary)
            Text(task.subject)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Pieces


/// The resting pill's leading mark: session identity, tinted by state, wrapped
/// in an arc showing how full the context window is.
///
/// Deliberately not the tool's icon — the pill names the session, and a glyph
/// that changed on every tool call would be noise beside a status word that
/// already says what is happening. The arc earns its place instead: it is the
/// one number you cannot infer from anything else on the row.
struct SessionGlyph: View {
    let state: SessionState
    var contextFraction: Double = 0
    var size: CGFloat = 20

    private var accent: Accent { IslandPalette.accentPair(for: state) }

    var body: some View {
        ContextRing(
            fraction: contextFraction,
            accent: IslandPalette.contextAccent(contextFraction)
        ) {
            ZStack {
                Circle()
                    .fill(accent.wash)
                    .overlay(Circle().strokeBorder(accent.base.opacity(0.30), lineWidth: 1))
                    .frame(width: size, height: size)
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(accent.gradient)
                    .shadow(color: accent.glow, radius: 3)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ToolGlyph: View {
    let session: Session

    var body: some View {
        ZStack {
            Circle()
                .fill(IslandPalette.accent(for: session.state).opacity(0.18))
                .frame(width: 20, height: 20)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(IslandPalette.accent(for: session.state))
        }
        // A subagent's inner tool is the informative thing, so the badge marks
        // that we're inside one rather than replacing the tool glyph.
        .overlay(alignment: .bottomTrailing) {
            if session.isInSubagent {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(2)
                    .background(Circle().fill(IslandPalette.running))
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var symbol: String {
        switch session.state {
        case .running(let tool): tool.kind.symbolName
        case .awaitingPermission(let ask): ask.kind.symbolName
        case .compacting: "arrow.down.right.and.arrow.up.left"
        case .error: "exclamationmark.triangle.fill"
        case .done: "checkmark"
        case .prompting: "arrow.up.circle.fill"
        case .thinking: "sparkle"
        case .idle(let waiting): waiting ? "person.wave.2" : "moon.zzz"
        }
    }
}

struct CountBadge: View {
    let count: Int
    var tint: Color = IslandPalette.running

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(minWidth: 14, minHeight: 14)
            .background(Circle().fill(tint))
    }
}

