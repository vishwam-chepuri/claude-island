import AppKit
import ClaudeIslandCore
import SwiftUI

// MARK: - Compact

struct CompactContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        HStack(spacing: 8) {
            ToolGlyph(session: session)

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let elapsed = operationElapsed {
                Text(Format.compactDuration(elapsed))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary)
                    .monospacedDigit()
            }

            if model.snapshot.sessionCount > 1 {
                CountBadge(count: model.snapshot.sessionCount)
            }

            ActivityIndicator(state: session.state)
        }
    }

    private var label: String {
        if case .running(let tool) = session.state {
            return tool.target ?? tool.toolName
        }
        return session.state.label
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
        HStack(spacing: 10) {
            PulsingGlyph(
                symbolName: "hand.raised.fill",
                color: NSColor(IslandPalette.alert),
                pointSize: 13,
                animating: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let target = ask?.target {
                    Text(target)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(IslandPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let since = ask?.since {
                Text(Format.compactDuration(model.tick.timeIntervalSince(since)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(IslandPalette.alert.opacity(0.8))
                    .monospacedDigit()
            }

            if model.snapshot.sessionCount > 1 {
                CountBadge(count: model.snapshot.sessionCount, tint: IslandPalette.alert)
            }
        }
    }

    private var ask: PermissionAsk? {
        if case .awaitingPermission(let a) = session.state { return a }
        return nil
    }

    private var headline: String {
        guard let ask else { return "Permission needed" }
        return "Allow \(ask.toolName)?  ·  \(session.displayName)"
    }
}

// MARK: - Expanded

struct ExpandedContent: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Leave the notch region itself clear on a notched display.
            Spacer(minLength: (model.geometry?.hasNotch == true) ? model.geometry!.islandRect.height : 6)

            header
            Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 8)
            tokenRow

            if !session.recentTools.isEmpty {
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 8)
                recentTools
            }

            if !model.others.isEmpty {
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 8)
                otherSessions
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ToolGlyph(session: session)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(session.state.label)
                    .font(.system(size: 10))
                    .foregroundStyle(IslandPalette.accent(for: session.state))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if let model = Format.model(session.model) {
                    Text(model)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IslandPalette.secondary)
                }
                Text(Format.duration(session.age(now: model.tick)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(IslandPalette.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private var tokenRow: some View {
        HStack(alignment: .top, spacing: 14) {
            // Live window occupancy — the number worth acting on.
            TokenStat(
                label: "context",
                value: Format.tokens(session.tokens.contextTokens),
                tint: .white)
            TokenStat(
                label: "output",
                value: Format.tokens(session.tokens.cumulativeOutput),
                tint: IslandPalette.secondary)
            // Cache reads shown as a ratio: the raw sum runs to millions on a
            // long session and misreads at a glance.
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
    }

    private var recentTools: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(IslandPalette.tertiary)
                .tracking(0.6)
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
    }

    private var otherSessions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALSO RUNNING")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(IslandPalette.tertiary)
                .tracking(0.6)
            ForEach(model.others.prefix(3)) { other in
                HStack(spacing: 6) {
                    Circle()
                        .fill(IslandPalette.accent(for: other.state))
                        .frame(width: 5, height: 5)
                    Text(other.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    Text(other.state.label)
                        .font(.system(size: 10))
                        .foregroundStyle(IslandPalette.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if model.others.count > 3 {
                Text("+\(model.others.count - 3) more")
                    .font(.system(size: 9))
                    .foregroundStyle(IslandPalette.tertiary)
            }
        }
    }
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

/// Three dots that stop entirely when nothing is running.
///
/// A state with `wantsAnimation == false` renders a single static dot with no
/// animation attached, so a finished session leaves no repeating work.
struct ActivityIndicator: View {
    let state: SessionState

    var body: some View {
        Group {
            if state.wantsAnimation {
                BouncingDots(color: NSColor(IslandPalette.accent(for: state)), animating: true)
                    .frame(
                        width: BouncingDots.intrinsicSize.width,
                        height: BouncingDots.intrinsicSize.height)
            } else {
                Circle()
                    .fill(IslandPalette.accent(for: state))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 20, alignment: .trailing)
    }
}
