import Foundation

/// Hook events Claude Code can deliver.
///
/// `postToolUseFailure` and `permissionRequest` are not in the original nine:
/// the first is the only clean signal for the error state, the second gives an
/// exact tool + input for a permission prompt instead of inferring one from
/// notification prose.
public enum HookEvent: Sendable, Equatable, Hashable {
    case sessionStart
    case userPromptSubmit
    case preToolUse
    case postToolUse
    case postToolUseFailure
    case permissionRequest
    case notification
    case preCompact
    case stop
    case subagentStop
    case sessionEnd
    /// Not a hook at all: the periodic payload Claude Code feeds the status
    /// line. It arrives over the same socket because it is the only place the
    /// exact context-window size is published.
    case statusline
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "SessionStart": self = .sessionStart
        case "UserPromptSubmit": self = .userPromptSubmit
        case "PreToolUse": self = .preToolUse
        case "PostToolUse": self = .postToolUse
        case "PostToolUseFailure": self = .postToolUseFailure
        case "PermissionRequest": self = .permissionRequest
        case "Notification": self = .notification
        case "PreCompact": self = .preCompact
        case "Stop": self = .stop
        case "SubagentStop": self = .subagentStop
        case "SessionEnd": self = .sessionEnd
        default: self = .unknown(rawValue)
        }
    }

    public var name: String {
        switch self {
        case .sessionStart: "SessionStart"
        case .userPromptSubmit: "UserPromptSubmit"
        case .preToolUse: "PreToolUse"
        case .postToolUse: "PostToolUse"
        case .postToolUseFailure: "PostToolUseFailure"
        case .permissionRequest: "PermissionRequest"
        case .notification: "Notification"
        case .preCompact: "PreCompact"
        case .stop: "Stop"
        case .subagentStop: "SubagentStop"
        case .sessionEnd: "SessionEnd"
        case .statusline: "StatusLine"
        case .unknown(let s): s
        }
    }

    /// The set the installer writes into settings.json.
    public static let installable: [HookEvent] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
        .postToolUseFailure, .permissionRequest, .notification, .preCompact,
        .stop, .subagentStop, .sessionEnd,
    ]
}

/// A single decoded hook payload.
///
/// Every field but `sessionID` is optional and every unknown key is ignored.
/// A payload that surprises us must still update the HUD with whatever it did
/// carry rather than being discarded.
public struct HookEnvelope: Sendable, Equatable {
    public let sessionID: String
    public let event: HookEvent
    public let cwd: String?
    public let transcriptPath: String?
    public let toolName: String?
    public let toolInput: JSONValue?
    public let message: String?
    public let trigger: String?
    public let source: String?
    public let reason: String?
    /// `context_window.context_window_size` from a status-line payload: the
    /// exact window for this session, stated rather than inferred.
    public let contextWindowSize: Int?
    /// Wall clock, used for session age and expiry. Injected so tests are
    /// deterministic.
    public let receivedAt: Date

    public init(
        sessionID: String,
        event: HookEvent,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        message: String? = nil,
        trigger: String? = nil,
        source: String? = nil,
        reason: String? = nil,
        contextWindowSize: Int? = nil,
        receivedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.event = event
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.trigger = trigger
        self.source = source
        self.reason = reason
        self.contextWindowSize = contextWindowSize
        self.receivedAt = receivedAt
    }
}

extension HookEnvelope {
    private enum Key: String, CodingKey {
        case sessionId = "session_id"
        case sessionIdCamel = "sessionId"
        case hookEventName = "hook_event_name"
        case cwd
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case trigger
        case source
        case reason
        case contextWindow = "context_window"
        case delayMs = "_delayMs"
    }

    private enum ContextWindowKey: String, CodingKey {
        case contextWindowSize = "context_window_size"
    }

    /// Decode one payload. Returns nil only when there is no session id at all —
    /// without one there is nothing to key a session on.
    public static func decode(_ data: Data, receivedAt: Date = Date()) throws -> HookEnvelope? {
        let d = JSONDecoder()
        let raw = try d.decode(RawPayload.self, from: data)
        guard let sid = raw.sessionID, !sid.isEmpty else { return nil }
        // The status-line payload names no hook event. It is recognised by the
        // one field no hook carries, so it can never be mistaken for a real
        // event and driven through the state machine.
        let event: HookEvent =
            if let name = raw.hookEventName, !name.isEmpty {
                HookEvent(rawValue: name)
            } else if raw.contextWindowSize != nil {
                .statusline
            } else {
                .unknown("")
            }
        return HookEnvelope(
            sessionID: sid,
            event: event,
            cwd: raw.cwd,
            transcriptPath: raw.transcriptPath,
            toolName: raw.toolName,
            toolInput: raw.toolInput,
            message: raw.message,
            trigger: raw.trigger,
            source: raw.source,
            reason: raw.reason,
            contextWindowSize: raw.contextWindowSize,
            receivedAt: receivedAt
        )
    }

    /// Replay files may carry `_delayMs` to reproduce timing.
    public static func decodeReplayLine(
        _ data: Data, receivedAt: Date
    ) throws -> (envelope: HookEnvelope, delayMs: Int)? {
        let raw = try JSONDecoder().decode(RawPayload.self, from: data)
        guard let env = try decode(data, receivedAt: receivedAt) else { return nil }
        return (env, raw.delayMs ?? 0)
    }

    private struct RawPayload: Decodable {
        let sessionID: String?
        let hookEventName: String?
        let cwd: String?
        let transcriptPath: String?
        let toolName: String?
        let toolInput: JSONValue?
        let message: String?
        let trigger: String?
        let source: String?
        let reason: String?
        let contextWindowSize: Int?
        let delayMs: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            // Hook payloads use snake_case; transcript lines use camelCase.
            // Accept either so recorded fixtures from both sources work.
            sessionID =
                (try? c.decodeIfPresent(String.self, forKey: .sessionId))
                ?? (try? c.decodeIfPresent(String.self, forKey: .sessionIdCamel))
                ?? nil
            hookEventName = try? c.decodeIfPresent(String.self, forKey: .hookEventName)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
            toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
            toolInput = try? c.decodeIfPresent(JSONValue.self, forKey: .toolInput)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            trigger = try? c.decodeIfPresent(String.self, forKey: .trigger)
            source = try? c.decodeIfPresent(String.self, forKey: .source)
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            contextWindowSize = {
                guard
                    let window = try? c.nestedContainer(
                        keyedBy: ContextWindowKey.self, forKey: .contextWindow)
                else { return nil }
                return try? window.decodeIfPresent(Int.self, forKey: .contextWindowSize)
            }()
            delayMs = try? c.decodeIfPresent(Int.self, forKey: .delayMs)
        }
    }
}
