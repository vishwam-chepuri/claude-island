import Foundation

/// A pending permission prompt.
public struct PermissionAsk: Sendable, Equatable {
    public let toolName: String
    public let kind: ToolKind
    public let target: String?
    public let since: Date

    public init(toolName: String, kind: ToolKind, target: String?, since: Date) {
        self.toolName = toolName
        self.kind = kind
        self.target = target
        self.since = since
    }
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
