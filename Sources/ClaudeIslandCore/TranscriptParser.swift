import Foundation

public struct TranscriptUpdate: Sendable, Equatable {
    public let sessionID: String
    public var model: String?
    public var tokens: TokenStats

    public init(sessionID: String, model: String?, tokens: TokenStats) {
        self.sessionID = sessionID
        self.model = model
        self.tokens = tokens
    }
}

/// Incremental accumulator over a transcript's assistant lines.
///
/// Holds the running totals for one session so the watcher can feed it only the
/// newly-appended tail and never re-read the file.
public struct TranscriptAccumulator: Sendable {
    public private(set) var tokens = TokenStats()
    public private(set) var model: String?

    /// Claude Code writes one JSONL line per content block, and every line of a
    /// single API response repeats that response's `usage`. Measured on a real
    /// transcript: 55 assistant lines carrying 26 distinct `requestId`s. Summing
    /// without deduping overcounts output tokens by roughly 2x.
    private var lastRequestID: String?
    /// Small ring of recently-counted ids, in case sidechain lines interleave
    /// and break the contiguity that `lastRequestID` alone assumes.
    private var recentRequestIDs: [String] = []
    private static let recentWindow = 64

    public init() {}

    public mutating func consume(line: Data) {
        guard let row = try? JSONDecoder().decode(AssistantRow.self, from: line),
            row.type == "assistant",
            let message = row.message
        else { return }

        if let m = message.model, !m.isEmpty, row.isSidechain != true {
            model = m
        }

        guard let usage = message.usage else { return }

        if let rid = row.requestID {
            if rid == lastRequestID || recentRequestIDs.contains(rid) { return }
            lastRequestID = rid
            recentRequestIDs.append(rid)
            if recentRequestIDs.count > Self.recentWindow { recentRequestIDs.removeFirst() }
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

    struct AssistantRow: Decodable {
        let type: String?
        let requestID: String?
        let isSidechain: Bool?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type
            case requestID = "requestId"
            case isSidechain
            case message
        }

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
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

/// Splits an appended byte range into complete lines, returning any trailing
/// partial line so the caller can rewind its offset.
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
