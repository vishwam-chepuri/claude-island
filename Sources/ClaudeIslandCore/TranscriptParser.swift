import Foundation

public struct TranscriptUpdate: Sendable, Equatable {
    public let sessionID: String
    public var model: String?
    public var tokens: TokenStats
    public var gitBranch: String?
    public var effort: String?
    public var tasks: TaskProgress

    public init(
        sessionID: String, model: String?, tokens: TokenStats,
        gitBranch: String? = nil, effort: String? = nil, tasks: TaskProgress = TaskProgress()
    ) {
        self.sessionID = sessionID
        self.model = model
        self.tokens = tokens
        self.gitBranch = gitBranch
        self.effort = effort
        self.tasks = tasks
    }
}

/// Incremental accumulator over a transcript's lines.
///
/// Holds the running totals for one session so the watcher can feed it only the
/// newly-appended tail and never re-read the file.
public struct TranscriptAccumulator: Sendable {
    public private(set) var tokens = TokenStats()
    public private(set) var model: String?
    public private(set) var gitBranch: String?
    public private(set) var effort: String?
    public private(set) var tasks = TaskProgress()

    /// Claude Code writes one JSONL line per content block, and every line of a
    /// single API response repeats that response's `usage`. Measured on a real
    /// transcript: 55 assistant lines carrying 26 distinct `requestId`s. Summing
    /// without deduping overcounts output tokens by roughly 2x.
    private var countedRequestIDs: [String] = []
    private static let recentWindow = 64

    public init() {}

    public mutating func consume(line: Data) {
        guard let row = try? JSONDecoder().decode(TranscriptRow.self, from: line) else { return }

        // Present on nearly every line type, not just assistant ones.
        if let branch = row.gitBranch, !branch.isEmpty { gitBranch = branch }
        if let effortValue = row.effort, !effortValue.isEmpty { effort = effortValue }

        guard row.type == "assistant", let message = row.message else { return }

        if let m = message.model, !m.isEmpty, row.isSidechain != true { model = m }

        // Task calls are parsed on EVERY assistant line. They arrive on a line
        // that shares its requestId with the response's text and thinking
        // blocks, so folding this into the usage dedupe below would drop them
        // whenever the tool_use block was not the first line of the response.
        for block in message.content ?? [] where block.type == "tool_use" {
            guard let name = block.name else { continue }
            tasks.apply(toolName: name, input: block.input)
        }

        guard let usage = message.usage else { return }
        if let rid = row.requestID {
            if countedRequestIDs.contains(rid) { return }
            countedRequestIDs.append(rid)
            if countedRequestIDs.count > Self.recentWindow { countedRequestIDs.removeFirst() }
        }

        tokens.messageCount += 1
        tokens.cumulativeFreshInput += usage.inputTokens ?? 0
        tokens.cumulativeOutput += usage.outputTokens ?? 0
        tokens.cumulativeCacheCreation += usage.cacheCreationInputTokens ?? 0
        tokens.cumulativeCacheRead += usage.cacheReadInputTokens ?? 0

        // Context occupancy comes from the main thread of conversation only. A
        // subagent runs in its own window, so counting it here would report a
        // context size that does not exist.
        if row.isSidechain != true {
            tokens.contextTokens =
                (usage.inputTokens ?? 0) + (usage.cacheReadInputTokens ?? 0)
                + (usage.cacheCreationInputTokens ?? 0)
        }
    }

    struct TranscriptRow: Decodable {
        let type: String?
        let requestID: String?
        let isSidechain: Bool?
        let gitBranch: String?
        let effort: String?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type
            case requestID = "requestId"
            case isSidechain
            case gitBranch
            case effort
            case message
        }

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
            let content: [ContentBlock]?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                model = try? c.decodeIfPresent(String.self, forKey: .model)
                usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
                // `content` is a string on user lines and an array on assistant
                // lines; only the array form carries tool calls.
                content = try? c.decodeIfPresent([ContentBlock].self, forKey: .content)
            }

            enum CodingKeys: String, CodingKey { case model, usage, content }
        }

        struct ContentBlock: Decodable {
            let type: String?
            let name: String?
            let input: JSONValue?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }
}

/// Splits an appended byte range into complete lines, returning the length of
/// any trailing partial line so the caller can rewind its offset.
///
/// A transcript is appended to while we read it, so the tail routinely ends
/// mid-line. Parsing that fragment would silently drop a message.
public enum LineSplitter {
    public static func completeLines(from data: Data) -> (lines: [Data], leftover: Int) {
        var lines: [Data] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                if index > start { lines.append(data[start..<index]) }
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        return (lines, data.distance(from: start, to: data.endIndex))
    }
}
