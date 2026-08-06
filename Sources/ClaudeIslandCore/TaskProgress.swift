import Foundation

public enum TaskStatus: String, Sendable, Equatable {
    case pending
    case inProgress
    case completed

    init?(raw: String) {
        switch raw.lowercased() {
        case "pending": self = .pending
        case "in_progress", "inprogress", "active": self = .inProgress
        case "completed", "done": self = .completed
        default: return nil
        }
    }
}

public struct TaskItem: Sendable, Equatable, Identifiable {
    public let id: String
    public var subject: String
    public var status: TaskStatus

    public init(id: String, subject: String, status: TaskStatus) {
        self.id = id
        self.subject = subject
        self.status = status
    }
}

/// The session's plan, reconstructed from the transcript.
///
/// Two tool families write it and they behave differently: `TodoWrite` sends the
/// entire list every time (a snapshot), while `TaskCreate`/`TaskUpdate` send
/// deltas. Both are replayed into the same list so the HUD does not care which
/// one a session happens to use.
public struct TaskProgress: Sendable, Equatable {
    public var items: [TaskItem] = []

    public init(items: [TaskItem] = []) { self.items = items }

    public var total: Int { items.count }
    public var completed: Int { items.filter { $0.status == .completed }.count }
    public var isEmpty: Bool { items.isEmpty }

    /// The task being worked on, else the next one not yet done.
    public var current: TaskItem? {
        items.first { $0.status == .inProgress } ?? items.first { $0.status == .pending }
    }

    public var summary: String? {
        guard total > 0 else { return nil }
        return "\(completed)/\(total)"
    }

    // MARK: - Replay

    public mutating func applySnapshot(_ todos: JSONValue?) {
        guard case .array(let entries)? = todos else { return }
        items = entries.enumerated().compactMap { index, entry in
            guard let subject = entry.firstString(["content", "subject", "activeForm"])
            else { return nil }
            let status = TaskStatus(raw: entry["status"]?.stringValue ?? "pending") ?? .pending
            return TaskItem(id: "todo-\(index)", subject: subject, status: status)
        }
    }

    /// `TaskCreate` carries no id — the tool assigns them in creation order,
    /// 1-based, which is what its result text ("Task #7 created") reflects.
    public mutating func applyCreate(_ input: JSONValue?) {
        guard let subject = input?.firstString(["subject", "content", "description"]) else {
            return
        }
        items.append(
            TaskItem(id: String(items.count + 1), subject: subject, status: .pending))
    }

    public mutating func applyUpdate(_ input: JSONValue?) {
        guard let id = input?["taskId"]?.stringValue ?? input?["taskId"]?.intValue.map(String.init),
            let index = items.firstIndex(where: { $0.id == id })
        else { return }
        if let raw = input?["status"]?.stringValue {
            // "deleted" removes the task rather than being a status it can hold.
            if raw.lowercased() == "deleted" {
                items.remove(at: index)
                return
            }
            if let status = TaskStatus(raw: raw) { items[index].status = status }
        }
        if let subject = input?["subject"]?.stringValue, !subject.isEmpty {
            items[index].subject = subject
        }
    }

    /// Route a tool call to the right replay path. Returns true if it was a
    /// task-management call.
    @discardableResult
    mutating func apply(toolName: String, input: JSONValue?) -> Bool {
        switch toolName {
        case "TodoWrite":
            applySnapshot(input?["todos"])
            return true
        case "TaskCreate":
            applyCreate(input)
            return true
        case "TaskUpdate":
            applyUpdate(input)
            return true
        default:
            return false
        }
    }
}
