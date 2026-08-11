import Foundation

/// A pending permission prompt.
public struct PermissionAsk: Sendable, Equatable {
    public let toolName: String
    public let kind: ToolKind
    public let target: String?
    public let since: Date
    /// Handle for answering this prompt from the HUD, or nil when it cannot be
    /// answered here — because it was inferred from notification prose rather
    /// than a held connection, because it was replayed from a trace, or because
    /// the terminal already settled it.
    ///
    /// Claude Code keeps its own dialog up either way, so nil is never a dead
    /// end: it only means this particular prompt has to be answered there.
    public var decisionToken: UInt64?
    /// The whole command or path the prompt is about, redacted but not clamped to
    /// the 60 characters `target` allows itself.
    ///
    /// `target` exists to fit on a pill and will happily cut a command in half.
    /// Anything that offers to approve one has to show all of it instead —
    /// approving a truncated `rm -rf ./build && …` from a glance is strictly
    /// worse than walking back to the terminal, which shows everything.
    public let detail: String?
    /// How many *other* prompts are waiting in this same session.
    ///
    /// Claude Code runs tool calls in parallel and fires a `PermissionRequest`
    /// hook for each, while showing one dialog at a time. The state machine keeps
    /// one ask per session, so with siblings present the card is showing the
    /// newest prompt while the terminal may be asking about an older one — and a
    /// press would approve the tool call the human is not reading. There is no
    /// signal available to pair them up, so the honest move is to answer neither
    /// and say why.
    public var siblingCount: Int

    public init(
        toolName: String, kind: ToolKind, target: String?, since: Date,
        decisionToken: UInt64? = nil, detail: String? = nil, siblingCount: Int = 0
    ) {
        self.toolName = toolName
        self.kind = kind
        self.target = target
        self.since = since
        self.decisionToken = decisionToken
        self.detail = detail
        self.siblingCount = siblingCount
    }

    /// Whether the HUD can settle this prompt itself.
    public var isAnswerable: Bool { decisionToken != nil && siblingCount == 0 }
}

/// Derived display state for one Claude Code session.
public enum SessionState: Sendable, Equatable {
    /// No work in flight. `waitingOnUser` is set when Claude has nudged that it
    /// is waiting for input, which is idle-but-worth-a-glance.
    case idle(waitingOnUser: Bool)
    /// A prompt was just submitted. A brief flash; auto-advances to `.thinking`.
    case prompting
    /// Assistant is working with no tool in flight. Inferred, never observed —
    /// Claude Code has no "started responding" hook.
    case thinking
    case running(ToolActivity)
    case awaitingPermission(PermissionAsk)
    case compacting
    case done
    case error(String)

    public static let idle: SessionState = .idle(waitingOnUser: false)

    public var isAlert: Bool {
        if case .awaitingPermission = self { return true }
        return false
    }

    /// The session is blocked on the human: work has stopped and cannot resume
    /// until the prompt is answered.
    ///
    /// The idle nudge, `idle(waitingOnUser: true)`, is deliberately excluded.
    /// It only means no prompt has arrived in a while, which is true of every
    /// session you are not currently typing into and stays true until you come
    /// back — so counting it here turned the attention badge into a tally of
    /// sessions you had walked away from rather than of things blocking work,
    /// and the two were indistinguishable at a glance.
    ///
    /// Identical to `isAlert` today, and defined in terms of it so the two
    /// cannot drift. The names are kept apart because they answer different
    /// questions — what the HUD escalates, versus what the human owes — and any
    /// future blocking state has to satisfy both.
    public var needsUser: Bool { isAlert }

    public var isActive: Bool {
        switch self {
        case .prompting, .thinking, .running, .awaitingPermission, .compacting: true
        case .idle, .done, .error: false
        }
    }

    /// Whether the HUD should run a continuous animation for this state.
    /// Anything false here must leave zero redraws scheduled.
    public var wantsAnimation: Bool {
        switch self {
        case .running, .thinking, .prompting, .compacting, .awaitingPermission: true
        case .idle, .done, .error: false
        }
    }

    /// The sound-worthy transition this state represents, if any.
    ///
    /// `nil` covers every state with no attention-worthy audio cue, including
    /// the non-nudged half of `idle`. Deduplicating repeats — a second
    /// permission ask arriving right behind the first, or an idle nudge that
    /// keeps re-firing while a session sits untouched — is the caller's job:
    /// it compares cues across snapshots rather than full state values, so a
    /// change of `PermissionAsk` payload with the same cue does not re-ring.
    ///
    /// `running(.question)` gets the same cue as `awaitingPermission`: a
    /// clarifying question (`AskUserQuestion`) or a plan to approve
    /// (`ExitPlanMode`) blocks the turn on the user exactly like a permission
    /// prompt does, just without going through the permission hook.
    public var soundCue: SoundCue? {
        switch self {
        case .done: .done
        case .awaitingPermission: .inputRequired
        case .idle(let waitingOnUser): waitingOnUser ? .waiting : nil
        case .running(let activity): activity.kind == .question ? .inputRequired : nil
        case .prompting, .thinking, .compacting, .error: nil
        }
    }

    public var label: String {
        switch self {
        case .idle(let waiting): waiting ? "waiting for you" : "idle"
        case .prompting: "sent"
        case .thinking: "thinking"
        case .running(let t): t.toolName
        case .awaitingPermission(let a): "allow \(a.toolName)?"
        case .compacting: "compacting"
        case .done: "done"
        case .error(let m): m
        }
    }

    /// Stable identifier used by golden-file replay traces.
    public var traceName: String {
        switch self {
        case .idle(let waiting): waiting ? "idle(waiting)" : "idle"
        case .prompting: "prompting"
        case .thinking: "thinking"
        case .running(let t): "running(\(t.toolName))"
        case .awaitingPermission(let a): "awaitingPermission(\(a.toolName))"
        case .compacting: "compacting"
        case .done: "done"
        case .error: "error"
        }
    }
}

/// A sound-worthy transition into a `SessionState`. See `SessionState.soundCue`.
///
/// `CaseIterable` because each cue carries its own settings — see `CueSound` —
/// and the settings pane draws one row per case rather than three hand-written
/// ones that could fall out of step with this enum.
public enum SoundCue: Sendable, Hashable, CaseIterable {
    case done
    case inputRequired
    case waiting
}

/// Classification of `Notification` payload text.
///
/// `PermissionRequest` is the primary permission signal, but `Notification` also
/// fires for permission prompts on some paths and for idle nudges. Matching the
/// prose is a fallback, so it is deliberately conservative: unrecognized text
/// leaves state alone rather than guessing.
public enum NotificationKind: Sendable, Equatable {
    case permission
    case idleNudge
    case other

    public init(message: String?) {
        let m = (message ?? "").lowercased()
        if m.isEmpty {
            self = .other
        } else if m.contains("permission") || m.contains("needs your approval")
            || m.contains("wants to use") || m.contains("approve")
        {
            self = .permission
        } else if m.contains("waiting for your input") || m.contains("is idle")
            || m.contains("waiting for you")
        {
            self = .idleNudge
        } else {
            self = .other
        }
    }
}

/// Timed transitions the state machine cannot make on its own, because no hook
/// event will arrive to trigger them.
public enum PendingTransition: Sendable, Equatable {
    /// `.prompting` is a flash; advance to `.thinking` after this delay.
    case promptingToThinking(after: TimeInterval)
    /// `.error` decays back to `.thinking` so a failed tool does not pin the HUD
    /// red for the rest of the session.
    case errorToThinking(after: TimeInterval)
    /// The session ended; drop it after a short fade.
    case removeSession(after: TimeInterval)
}

public enum Timings {
    public static let promptingFlash: TimeInterval = 1.0
    public static let errorDecay: TimeInterval = 4.0
    public static let sessionEndFade: TimeInterval = 5.0
    public static let sessionExpiry: TimeInterval = 30 * 60
    public static let expirySweepInterval: TimeInterval = 60
}
