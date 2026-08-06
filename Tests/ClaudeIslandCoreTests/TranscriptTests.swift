import ClaudeIslandCore
import Foundation

private func assistantLine(
    requestID: String, output: Int, input: Int = 2, cacheRead: Int = 50_000,
    cacheCreate: Int = 1_000, model: String = "claude-opus-5", sidechain: Bool = false
) -> Data {
    Data(
        """
        {"type":"assistant","requestId":"\(requestID)","isSidechain":\(sidechain),"message":{"model":"\(model)","usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreate),"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """.utf8)
}

func registerTranscriptTests() {
    suite("Transcript parsing") {

        test("Repeated lines for one request are counted once") {
            // Claude Code writes one line per content block, each repeating the
            // response's usage. A real transcript showed 55 lines / 26 requestIds.
            var acc = TranscriptAccumulator()
            acc.consume(line: assistantLine(requestID: "req_1", output: 803))
            acc.consume(line: assistantLine(requestID: "req_1", output: 803))
            acc.consume(line: assistantLine(requestID: "req_1", output: 803))
            acc.consume(line: assistantLine(requestID: "req_2", output: 291))

            await expectEqual(acc.tokens.messageCount, 2)
            await expectEqual(acc.tokens.cumulativeOutput, 803 + 291)
        }

        test("Deduping survives an interleaved sidechain line") {
            var acc = TranscriptAccumulator()
            acc.consume(line: assistantLine(requestID: "req_1", output: 100))
            acc.consume(line: assistantLine(requestID: "sub_1", output: 50, sidechain: true))
            acc.consume(line: assistantLine(requestID: "req_1", output: 100))  // back to parent
            await expectEqual(acc.tokens.cumulativeOutput, 150)
        }

        test("Context comes from the last main-thread message, not a sum") {
            var acc = TranscriptAccumulator()
            acc.consume(line: assistantLine(requestID: "r1", output: 10, cacheRead: 10_000))
            acc.consume(line: assistantLine(requestID: "r2", output: 10, cacheRead: 30_000))

            await expectEqual(acc.tokens.contextTokens, 2 + 30_000 + 1_000)
            await expectEqual(acc.tokens.cumulativeCacheRead, 40_000)
        }

        test("A subagent's tokens count toward spend but not toward context") {
            var acc = TranscriptAccumulator()
            acc.consume(line: assistantLine(requestID: "r1", output: 10, cacheRead: 5_000))
            let contextAfterMain = acc.tokens.contextTokens
            acc.consume(
                line: assistantLine(
                    requestID: "s1", output: 40, cacheRead: 90_000, sidechain: true))

            await expectEqual(acc.tokens.contextTokens, contextAfterMain)
            await expectEqual(acc.tokens.cumulativeOutput, 50)
        }

        test("Model is taken from the main thread only") {
            var acc = TranscriptAccumulator()
            acc.consume(line: assistantLine(requestID: "r1", output: 1, model: "claude-opus-5"))
            acc.consume(
                line: assistantLine(
                    requestID: "s1", output: 1, model: "claude-haiku-4-5", sidechain: true))
            await expectEqual(acc.model, "claude-opus-5")
        }

        test("Non-assistant and malformed lines are skipped") {
            var acc = TranscriptAccumulator()
            acc.consume(line: Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8))
            acc.consume(line: Data("not json".utf8))
            acc.consume(line: Data(#"{"type":"assistant"}"#.utf8))
            await expectEqual(acc.tokens.messageCount, 0)
        }

        test("Cache hit ratio reflects the split") {
            var acc = TranscriptAccumulator()
            acc.consume(
                line: assistantLine(
                    requestID: "r1", output: 10, input: 0, cacheRead: 75, cacheCreate: 25))
            let ratio = try await require(acc.tokens.cacheHitRatio)
            await expect(abs(ratio - 0.75) < 0.0001, "got \(ratio)")
        }

        test("Cache hit ratio is nil before any input") {
            await expectEqual(TokenStats().cacheHitRatio, nil)
        }
    }

    suite("Incremental line splitting") {

        test("A trailing partial line is reported, not parsed") {
            let data = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":".utf8)
            let (lines, leftover) = LineSplitter.completeLines(from: data)
            await expectEqual(lines.count, 2)
            await expectEqual(leftover, 5)  // the 5 bytes of `{"c":`
        }

        test("A clean boundary leaves no leftover") {
            let (lines, leftover) = LineSplitter.completeLines(from: Data("a\nb\n".utf8))
            await expectEqual(lines.count, 2)
            await expectEqual(leftover, 0)
        }

        test("Blank lines are skipped") {
            let (lines, _) = LineSplitter.completeLines(from: Data("a\n\n\nb\n".utf8))
            await expectEqual(lines.count, 2)
        }

        test("A partial line is parsed once completed on the next read") {
            // Simulates the watcher's rewind: the first read ends mid-line, the
            // second starts at the rewound offset and sees the whole line.
            var acc = TranscriptAccumulator()
            let full = assistantLine(requestID: "r1", output: 500)
            var buffer = Data(full.prefix(30))

            var (lines, leftover) = LineSplitter.completeLines(from: buffer)
            await expectEqual(lines.count, 0)
            await expectEqual(leftover, 30)

            buffer.append(full.dropFirst(30))
            buffer.append(0x0A)
            (lines, leftover) = LineSplitter.completeLines(from: buffer)
            await expectEqual(lines.count, 1)
            for line in lines { acc.consume(line: line) }
            await expectEqual(acc.tokens.cumulativeOutput, 500)
        }
    }

    suite("Transcript watcher") {

        test("Appends are read incrementally and never re-counted") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("island-tw-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let file = dir.appendingPathComponent("session.jsonl")
            var contents = Data()
            contents.append(assistantLine(requestID: "r1", output: 100))
            contents.append(0x0A)
            try contents.write(to: file)

            let box = UpdateBox()
            let watcher = TranscriptWatcher(onUpdate: { box.append($0) })
            watcher.track(sessionID: "s1", transcriptPath: file.path)

            // FSEvents latency plus the initial catch-up read.
            try await Task.sleep(nanoseconds: 400_000_000)
            await expectEqual(box.latest()?.tokens.cumulativeOutput, 100)

            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            var more = assistantLine(requestID: "r2", output: 250)
            more.append(0x0A)
            try handle.write(contentsOf: more)
            try handle.close()

            try await Task.sleep(nanoseconds: 900_000_000)
            let final = try await require(box.latest(), "no transcript update after append")
            // 350, not 450 — the first message must not be counted twice.
            await expectEqual(final.tokens.cumulativeOutput, 350)
            await expectEqual(final.model, "claude-opus-5")
            watcher.stop()
        }
    }
}

/// Collects watcher callbacks from an arbitrary queue.
private final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TranscriptUpdate] = []

    func append(_ u: TranscriptUpdate) {
        lock.lock()
        updates.append(u)
        lock.unlock()
    }

    func latest() -> TranscriptUpdate? {
        lock.lock()
        defer { lock.unlock() }
        return updates.last
    }
}
