import Foundation

/// The tools the HUD draws a distinct glyph for. Anything else falls to
/// `.other`, which still renders — with a generic glyph and the real name.
public enum ToolKind: String, Sendable, Equatable, CaseIterable {
    case bash
    case edit
    case read
    case write
    case grep
    case glob
    case webFetch
    case webSearch
    case task
    case todo
    case notebook
    /// Blocks the turn on a decision only the user can make — a multiple-choice
    /// question, a plan to approve — as opposed to `awaitingPermission`, which
    /// blocks on a yes/no tool grant. `SessionState.soundCue` treats the two
    /// alike: both need the same "come look" ring.
    case question
    case other

    public init(toolName: String?) {
        switch (toolName ?? "").lowercased() {
        case "bash", "bashoutput", "killshell": self = .bash
        case "edit", "multiedit": self = .edit
        case "read": self = .read
        case "write": self = .write
        case "grep": self = .grep
        case "glob", "ls": self = .glob
        case "webfetch", "fetch": self = .webFetch
        case "websearch": self = .webSearch
        case "task", "agent": self = .task
        case "todowrite", "taskcreate", "taskupdate": self = .todo
        case "notebookedit": self = .notebook
        case "askuserquestion", "exitplanmode": self = .question
        default: self = .other
        }
    }

    /// SF Symbol name. Chosen to read at 11pt inside a 38pt-tall notch.
    public var symbolName: String {
        switch self {
        case .bash: "terminal"
        case .edit: "pencil"
        case .read: "doc.text"
        case .write: "square.and.pencil"
        case .grep: "magnifyingglass"
        case .glob: "folder"
        case .webFetch: "globe"
        case .webSearch: "magnifyingglass.circle"
        case .task: "person.2"
        case .todo: "checklist"
        case .notebook: "book"
        case .question: "questionmark.circle"
        case .other: "gearshape"
        }
    }
}

/// A tool invocation in flight, or a completed one in the recent-calls list.
public struct ToolActivity: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ToolKind
    /// Real tool name as reported, for display when `kind == .other`.
    public let toolName: String
    /// Sanitized, truncated target: a file path, a command, a URL, a pattern.
    public let target: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var failed: Bool

    public init(
        id: UUID = UUID(),
        kind: ToolKind,
        toolName: String,
        target: String?,
        startedAt: Date,
        endedAt: Date? = nil,
        failed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.target = target
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.failed = failed
    }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }

    /// Build from a hook envelope, extracting and sanitizing the target.
    public static func from(_ e: HookEnvelope) -> ToolActivity {
        let name = e.toolName ?? "Tool"
        return ToolActivity(
            kind: ToolKind(toolName: name),
            toolName: name,
            target: extractTarget(toolName: name, input: e.toolInput),
            startedAt: e.receivedAt
        )
    }

    /// Pull the one field worth showing for a given tool.
    ///
    /// Paths get path-shortening, everything else gets whitespace collapse.
    /// Both then go through redaction and the 60-char clamp.
    public static func extractTarget(toolName: String, input: JSONValue?) -> String? {
        guard let input else { return nil }
        switch ToolKind(toolName: toolName) {
        case .bash:
            return Redactor.sanitize(input["command"]?.stringValue)
        case .read, .edit, .write, .notebook:
            if let p = input.firstString(["file_path", "notebook_path", "path"]) {
                return Redactor.sanitize(Redactor.shortenPath(p))
            }
            return nil
        case .grep:
            let pattern = input["pattern"]?.stringValue
            let path = input["path"]?.stringValue.map { Redactor.shortenPath($0, limit: 24) }
            return Redactor.sanitize([pattern, path].compactMap { $0 }.joined(separator: "  in  "))
        case .glob:
            return Redactor.sanitize(input.firstString(["pattern", "path"]))
        case .webFetch, .webSearch:
            return Redactor.sanitize(input.firstString(["url", "query"]))
        case .task:
            return Redactor.sanitize(input.firstString(["description", "subagent_type", "prompt"]))
        case .todo:
            return nil
        case .question:
            // AskUserQuestion carries an array of questions, ExitPlanMode a
            // full markdown plan — neither has one field worth clamping to 60
            // chars, so this shows a glyph and the tool name only, like `.todo`.
            return nil
        case .other:
            // Best-effort across common field names for tools we don't model.
            return Redactor.sanitize(
                input.firstString([
                    "command", "file_path", "path", "pattern", "url", "query", "description",
                ]))
        }
    }
}
