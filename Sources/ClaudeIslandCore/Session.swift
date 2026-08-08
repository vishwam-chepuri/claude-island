import Foundation

/// Cumulative and live token accounting for a session, fed by TranscriptWatcher.
///
/// Split rather than summed: `input_tokens` alone reads near zero on a cached
/// session (observed: 2 against a 50,211 cache read), and summing cache reads
/// across a long session produces a millions-scale number that misleads at a
/// glance. `contextTokens` is what is actually in the window right now.
public struct TokenStats: Sendable, Equatable {
    /// Last assistant message's input + cache_read + cache_creation.
    public var contextTokens: Int = 0
    public var cumulativeOutput: Int = 0
    public var cumulativeCacheCreation: Int = 0
    public var cumulativeCacheRead: Int = 0
    public var cumulativeFreshInput: Int = 0
    public var messageCount: Int = 0

    public init() {}

    /// Share of input tokens served from cache. Nil until there is input.
    public var cacheHitRatio: Double? {
        let total = cumulativeCacheRead + cumulativeCacheCreation + cumulativeFreshInput
        guard total > 0 else { return nil }
        return Double(cumulativeCacheRead) / Double(total)
    }

    /// Below this the cache has stopped paying for itself.
    public static let cacheHitFloor = 0.85
    /// Turns the cache needs before its cumulative ratio means anything.
    public static let cacheHitJudgeableAfter = 5

    /// The hit ratio, but only while it is news.
    ///
    /// A healthy session sits at 97–99% — the harness caches the prompt
    /// aggressively and there is nothing the reader can do to move the figure,
    /// so shown unconditionally it is a constant occupying a chip. Shown only
    /// once it collapses, it is the explanation for a turn that went slow and
    /// expensive.
    ///
    /// Withheld until `cacheHitJudgeableAfter` turns because the ratio is
    /// cumulative: turn one has nothing to read back, so a fresh session reads
    /// 0% by construction rather than by fault.
    public var degradedCacheHitRatio: Double? {
        guard messageCount >= Self.cacheHitJudgeableAfter,
            let ratio = cacheHitRatio, ratio < Self.cacheHitFloor
        else { return nil }
        return ratio
    }
}

/// One tracked Claude Code session.
public struct Session: Sendable, Equatable, Identifiable {
    public let id: String
    public var state: SessionState
    public var cwd: String?
    public var transcriptPath: String?
    /// The `/rename` title, read from the transcript's `custom-title` record.
    public var customTitle: String?
    /// Claude Code's own generated topic label, read from the transcript's
    /// `ai-title` record. Appears after the first assistant turn.
    public var aiTitle: String?
    public var model: String?
    public var gitBranch: String?
    public var effort: String?
    public var tasks = TaskProgress()
    public var tokens = TokenStats()
    public var startedAt: Date
    public var lastEventAt: Date
    /// Most recent completed or in-flight tool calls, newest first, capped.
    public var recentTools: [ToolActivity] = []
    /// Depth of nested `Task` subagents. While > 0 the HUD shows the subagent
    /// glyph with the inner tool, because that is the informative thing.
    public var subagentDepth: Int = 0
    /// Set once SessionEnd arrives; the store drops it after the fade.
    public var endedAt: Date?

    /// The expanded card scrolls its trail, so this is how much history the
    /// session keeps, not how much it shows. At the old value of 3 there was
    /// nothing to scroll and no memory worth opening the card for; the card
    /// budgets for five rows and scrolls the rest.
    ///
    /// Includes the in-flight call, so the trail of *finished* calls is at most
    /// this minus one.
    public static let recentToolLimit = 30

    public init(id: String, startedAt: Date) {
        self.id = id
        self.state = .idle
        self.startedAt = startedAt
        self.lastEventAt = startedAt
    }

    /// Label for the HUD, matching what Claude Code puts in the terminal tab:
    /// the `/rename` title, else its generated topic title.
    ///
    /// Claude Code's own chain ends `?? agentType ?? "Claude Code"`. This one
    /// ends at the folder because a HUD row has to say *which* session it is:
    /// several at once in one repo is the ordinary case here, and a column of
    /// four rows all reading "Claude Code" names none of them. The folder also
    /// covers the first turn of every session, before the title is generated.
    public var displayName: String {
        if let n = customTitle, !n.isEmpty { return n }
        if let n = aiTitle, !n.isEmpty { return n }
        if let c = cwd, !c.isEmpty {
            let base = (c as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return String(id.prefix(8))
    }

    public var isInSubagent: Bool { subagentDepth > 0 }

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(startedAt) }

    public func idleFor(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(lastEventAt) }
}

/// Pure state machine. Given a session and an event, produce the next session
/// plus any timed follow-up the caller must schedule.
///
/// Kept free of actors, clocks and I/O so the whole transition table is
/// exercisable in a unit test with no async at all.
public enum SessionReducer {
    public struct Outcome: Sendable {
        public var session: Session
        public var pending: [PendingTransition]
    }

    public static func apply(_ envelope: HookEnvelope, to input: Session?) -> Outcome {
        let now = envelope.receivedAt
        var s = input ?? Session(id: envelope.sessionID, startedAt: now)
        var pending: [PendingTransition] = []

        s.lastEventAt = now
        if let c = envelope.cwd, !c.isEmpty { s.cwd = c }
        if let t = envelope.transcriptPath, !t.isEmpty { s.transcriptPath = t }

        switch envelope.event {
        case .sessionStart:
            // A resumed or cleared session reuses the id; reset derived state
            // but keep identity fields we just captured.
            s.state = .idle
            s.recentTools = []
            s.subagentDepth = 0
            s.tokens = TokenStats()
            s.endedAt = nil
            s.startedAt = now

        case .userPromptSubmit:
            s.state = .prompting
            s.subagentDepth = 0
            pending.append(.promptingToThinking(after: Timings.promptingFlash))

        case .preToolUse:
            let activity = ToolActivity.from(envelope)
            if activity.kind == .task { s.subagentDepth += 1 }
            s.state = .running(activity)
            s.recentTools.insert(activity, at: 0)
            s.recentTools = Array(s.recentTools.prefix(Session.recentToolLimit))

        case .postToolUse:
            closeCurrentTool(&s, at: now, failed: false, toolName: envelope.toolName)
            s.state = .thinking

        case .postToolUseFailure:
            closeCurrentTool(&s, at: now, failed: true, toolName: envelope.toolName)
            let name = envelope.toolName ?? "tool"
            s.state = .error("\(name) failed")
            pending.append(.errorToThinking(after: Timings.errorDecay))

        case .permissionRequest:
            let name = envelope.toolName ?? "tool"
            s.state = .awaitingPermission(
                PermissionAsk(
                    toolName: name,
                    kind: ToolKind(toolName: name),
                    target: ToolActivity.extractTarget(toolName: name, input: envelope.toolInput),
                    since: now))

        case .notification:
            switch NotificationKind(message: envelope.message) {
            case .permission:
                // Fallback path. PreToolUse for the same tool usually preceded
                // this, so reuse its target when the payload has none.
                let name = envelope.toolName ?? currentToolName(s) ?? "tool"
                let target =
                    ToolActivity.extractTarget(toolName: name, input: envelope.toolInput)
                    ?? currentTarget(s)
                s.state = .awaitingPermission(
                    PermissionAsk(
                        toolName: name, kind: ToolKind(toolName: name), target: target, since: now))
            case .idleNudge:
                s.state = .idle(waitingOnUser: true)
            case .other:
                break  // Unrecognized prose must not disturb a good state.
            }

        case .preCompact:
            s.state = .compacting

        case .stop:
            closeCurrentTool(&s, at: now, failed: false, toolName: nil)
            s.subagentDepth = 0
            s.state = .done

        case .subagentStop:
            s.subagentDepth = max(0, s.subagentDepth - 1)
            // A subagent finishing does not mean the parent stopped working, so
            // this only ever settles the display back to `thinking` — and only
            // from states that are still mid-turn.
            //
            // Everything else is owned by an event that already arrived and
            // outranks this one: `running` by the parent's own PreToolUse,
            // `done` by Stop, `idle` by a nudge, `awaitingPermission` by a
            // prompt the user can still answer. Background subagents outlive
            // the turn that spawned them — one observed here finished 3m23s
            // after its parent's Stop — and resurrecting a settled session
            // pins the HUD at "thinking" until the 30-minute expiry, because
            // no further event is coming to clear it.
            switch s.state {
            case .thinking, .prompting: s.state = .thinking
            case .running, .done, .idle, .error, .awaitingPermission, .compacting: break
            }

        case .sessionEnd:
            closeCurrentTool(&s, at: now, failed: false, toolName: nil)
            s.state = .done
            s.endedAt = now
            pending.append(.removeSession(after: Timings.sessionEndFade))

        case .unknown:
            break
        }

        // Any event at all clears a pending permission that this event did not
        // itself set. Approve leads to PostToolUse, deny leads to
        // UserPromptSubmit — rather than enumerate every resolution path, treat
        // "something else happened" as resolution.
        return Outcome(session: s, pending: pending)
    }

    private static func closeCurrentTool(
        _ s: inout Session, at now: Date, failed: Bool, toolName: String?
    ) {
        guard let idx = s.recentTools.firstIndex(where: { $0.endedAt == nil }) else { return }
        // Only close a matching tool when we were told which one; unnamed
        // terminators (Stop, SessionEnd) close whatever is open.
        if let toolName, s.recentTools[idx].toolName != toolName { return }
        s.recentTools[idx].endedAt = now
        s.recentTools[idx].failed = failed
    }

    private static func currentToolName(_ s: Session) -> String? {
        if case .running(let t) = s.state { return t.toolName }
        return s.recentTools.first?.toolName
    }

    private static func currentTarget(_ s: Session) -> String? {
        if case .running(let t) = s.state { return t.target }
        return s.recentTools.first?.target
    }
}
