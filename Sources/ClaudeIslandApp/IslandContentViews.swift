import AppKit
import ClaudeIslandCore
import SwiftUI

// MARK: - Compact

struct CompactContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        // Below the cutout: on a notched display the top band of this shape is
        // the physical hole, and anything drawn there is invisible.
        HStack(spacing: 8) {
            ToolGlyph(session: session)

            Text(leadingText)
                .font(
                    .system(
                        size: 11, weight: .medium,
                        design: isShowingTarget ? .monospaced : .rounded)
                )
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 6)

            if let elapsed = operationElapsed {
                Text(Format.compactDuration(elapsed))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(IslandPalette.tertiary)
                    .monospacedDigit()
            }

            Text(session.state.statusWord)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(IslandPalette.accent(for: session.state))
                .lineLimit(1)
                .fixedSize()

            if model.attentionCount > 0 {
                CountBadge(count: model.attentionCount, tint: IslandPalette.alert)
            }

            StatusMark(state: session.state)
        }
        .frame(height: IslandViewModel.lineHeight)
        .padding(.top, model.contentTopInset)
    }

    /// The name normally; the live tool target while a tool is running, since
    /// that is the more informative of the two in that moment.
    private var isShowingTarget: Bool {
        if case .running(let tool) = session.state { return tool.target != nil }
        return false
    }

    private var leadingText: String {
        if case .running(let tool) = session.state {
            return tool.target ?? tool.toolName
        }
        return Format.name(session.displayName)
    }

    /// Elapsed time for the *current operation*, not the session.
    private var operationElapsed: TimeInterval? {
        guard case .running(let tool) = session.state else { return nil }
        // Reading model.tick makes this recompute on the shared 1 Hz timer.
        return tool.elapsed(now: model.tick)
    }
}

// MARK: - Alert

struct AlertContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
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
                .layoutPriority(1)

            Spacer(minLength: 6)

            if let since = ask?.since {
                Text(Format.compactDuration(model.tick.timeIntervalSince(since)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(IslandPalette.tertiary)
                    .monospacedDigit()
            }

            Text(session.state.statusWord)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandPalette.alert)
                .fixedSize()

            if model.attentionCount > 0 {
                CountBadge(count: model.attentionCount, tint: IslandPalette.alert)
            }

            StatusMark(state: session.state)
        }
        .frame(height: IslandViewModel.lineHeight)
        .padding(.top, model.contentTopInset)
    }

    private var ask: PermissionAsk? {
        if case .awaitingPermission(let a) = session.state { return a }
        return nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: model.contentTopInset)

            HStack(spacing: 8) {
                ToolGlyph(session: session)
                Text(Format.name(session.displayName, limit: 28))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(session.state.statusWord)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(IslandPalette.accent(for: session.state))
                StatusMark(state: session.state)
            }

            if let sub = subline {
                Text(sub)
                    .font(.system(size: 10, design: subIsMonospaced ? .monospaced : .default))
                    .foregroundStyle(
                        session.state.isAlert ? IslandPalette.alert : IslandPalette.secondary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 3)
            }

            MetaLine(session: session, tick: model.tick)
                .padding(.top, 4)

            HStack(spacing: 14) {
                TokenStat(
                    label: "context",
                    value: Format.tokens(session.tokens.contextTokens), tint: .white)
                TokenStat(
                    label: "output",
                    value: Format.tokens(session.tokens.cumulativeOutput),
                    tint: IslandPalette.secondary)
                if let tasks = session.tasks.summary {
                    TokenStat(label: "tasks", value: tasks, tint: IslandPalette.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)

            if let current = session.tasks.current {
                CurrentTaskLine(task: current)
                    .padding(.top, 5)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Expanded (click) — session switcher

struct ExpandedContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: model.contentTopInset)

            HStack(spacing: 6) {
                Text("SESSIONS")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
                    .tracking(0.6)
                Text("\(model.allSessions.count)")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
                Spacer(minLength: 0)
                if model.isOverriddenByAlert {
                    // The selection is kept and will resume; say so rather than
                    // let the view look like it jumped for no reason.
                    Text("permission request took over")
                        .font(.system(size: 8))
                        .foregroundStyle(IslandPalette.alert)
                }
            }

            ForEach(model.allSessions.prefix(4)) { candidate in
                SessionRow(
                    candidate: candidate,
                    isShown: candidate.id == session.id,
                    onSelect: { model.select(candidate.id) })
            }

            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 7)

            MetaLine(session: session, tick: model.tick)

            HStack(spacing: 14) {
                TokenStat(
                    label: "context",
                    value: Format.tokens(session.tokens.contextTokens), tint: .white)
                TokenStat(
                    label: "output",
                    value: Format.tokens(session.tokens.cumulativeOutput),
                    tint: IslandPalette.secondary)
                TokenStat(
                    label: "cache hit",
                    value: session.tokens.cacheHitRatio.map(Format.percent) ?? "—",
                    tint: IslandPalette.secondary)
                TokenStat(
                    label: "written",
                    value: Format.tokens(session.tokens.cumulativeCacheCreation),
                    tint: IslandPalette.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            if !session.tasks.isEmpty {
                HStack(spacing: 6) {
                    Text("TASKS")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(IslandPalette.tertiary)
                        .tracking(0.6)
                    Text(session.tasks.summary ?? "")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(IslandPalette.secondary)
                }
                .padding(.top, 8)
                if let current = session.tasks.current {
                    CurrentTaskLine(task: current).padding(.top, 2)
                }
            }

            if !session.recentTools.isEmpty {
                Text("RECENT")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
                    .tracking(0.6)
                    .padding(.top, 8)
                ForEach(session.recentTools) { tool in
                    HStack(spacing: 6) {
                        Image(systemName: tool.kind.symbolName)
                            .font(.system(size: 9))
                            .foregroundStyle(
                                tool.failed ? IslandPalette.error : IslandPalette.secondary
                            )
                            .frame(width: 12)
                        Text(tool.toolName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(tool.target ?? "")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(IslandPalette.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Format.compactDuration(tool.elapsed(now: model.tick)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(IslandPalette.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

/// One selectable row in the switcher.
struct SessionRow: View {
    let candidate: Session
    let isShown: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(IslandPalette.accent(for: candidate.state))
                .frame(width: 5, height: 5)
            Text(Format.name(candidate.displayName, limit: 26))
                .font(.system(size: 10, weight: isShown ? .semibold : .regular))
                .foregroundStyle(isShown ? .white : .white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 4)
            if candidate.state.isAlert {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(IslandPalette.alert)
            }
            Text(candidate.state.statusWord)
                .font(.system(size: 9))
                .foregroundStyle(IslandPalette.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isShown ? Color.white.opacity(0.10) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// On a notched display the top of the card must clear the physical cutout.
@MainActor
func notchClearance(_ model: IslandViewModel) -> CGFloat {
    (model.geometry?.hasNotch == true) ? (model.geometry?.islandRect.height ?? 38) : 6
}

// MARK: - Pieces

struct TokenStat: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(IslandPalette.tertiary)
        }
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

