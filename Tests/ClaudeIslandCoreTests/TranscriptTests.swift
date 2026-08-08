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

        test("A healthy cache is not worth reporting") {
            var acc = TranscriptAccumulator()
            for i in 0..<8 { acc.consume(line: assistantLine(requestID: "r\(i)", output: 10)) }

            let ratio = try await require(acc.tokens.cacheHitRatio)
            await expect(ratio > 0.9, "expected a warm cache, got \(ratio)")
            await expectEqual(acc.tokens.degradedCacheHitRatio, nil)
        }

        test("A collapsed cache is") {
            var acc = TranscriptAccumulator()
            for i in 0..<8 {
                acc.consume(
                    line: assistantLine(
                        requestID: "r\(i)", output: 10, cacheRead: 1_000, cacheCreate: 50_000))
            }

            let ratio = try await require(acc.tokens.degradedCacheHitRatio)
            await expect(ratio < 0.1, "got \(ratio)")
        }

        test("A young session is not blamed for a cache it has not filled yet") {
            // Turn one has nothing to read back, so the cumulative ratio is 0 by
            // construction — reporting it would flag every new session.
            var acc = TranscriptAccumulator()
            for i in 0..<(TokenStats.cacheHitJudgeableAfter - 1) {
                acc.consume(
                    line: assistantLine(
                        requestID: "r\(i)", output: 10, cacheRead: 0, cacheCreate: 50_000))
            }

            await expectEqual(acc.tokens.cacheHitRatio, 0)
            await expectEqual(acc.tokens.degradedCacheHitRatio, nil)

            acc.consume(
                line: assistantLine(
                    requestID: "last", output: 10, cacheRead: 0, cacheCreate: 50_000))
            await expectEqual(acc.tokens.messageCount, TokenStats.cacheHitJudgeableAfter)
            await expectEqual(acc.tokens.degradedCacheHitRatio, 0)
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

private func toolUseLine(
    _ name: String, _ input: String, requestID: String = "r1", branch: String? = nil,
    effort: String? = nil
) -> Data {
    var extras = ""
    if let branch { extras += ",\"gitBranch\":\"\(branch)\"" }
    if let effort { extras += ",\"effort\":\"\(effort)\"" }
    return Data(
        """
        {"type":"assistant","requestId":"\(requestID)","isSidechain":false\(extras),"message":{"model":"claude-opus-5","content":[{"type":"tool_use","name":"\(name)","input":\(input)}]}}
        """.utf8)
}

func registerTaskProgressTests() {
    suite("Task progress") {

        test("TaskCreate appends with 1-based ids, TaskUpdate mutates by id") {
            var acc = TranscriptAccumulator()
            acc.consume(line: toolUseLine("TaskCreate", #"{"subject":"Write parser"}"#))
            acc.consume(line: toolUseLine("TaskCreate", #"{"subject":"Add tests"}"#))
            acc.consume(line: toolUseLine("TaskUpdate", #"{"taskId":"1","status":"completed"}"#))
            acc.consume(line: toolUseLine("TaskUpdate", #"{"taskId":"2","status":"in_progress"}"#))

            await expectEqual(acc.tasks.total, 2)
            await expectEqual(acc.tasks.completed, 1)
            await expectEqual(acc.tasks.summary, "1/2")
            await expectEqual(acc.tasks.current?.subject, "Add tests")
            await expectEqual(acc.tasks.current?.status, .inProgress)
        }

        test("Task calls are read even when they share a requestId with other blocks") {
            // Claude Code splits one response across lines that repeat the
            // requestId. The usage dedupe must not swallow the tool_use line.
            var acc = TranscriptAccumulator()
            acc.consume(line: assistantLine(requestID: "shared", output: 100))
            acc.consume(line: toolUseLine("TaskCreate", #"{"subject":"Later block"}"#,
                                          requestID: "shared"))
            await expectEqual(acc.tasks.total, 1, "tool_use on a deduped line was dropped")
            await expectEqual(acc.tokens.cumulativeOutput, 100, "usage was double counted")
        }

        test("TodoWrite replaces the whole list") {
            var acc = TranscriptAccumulator()
            acc.consume(line: toolUseLine("TaskCreate", #"{"subject":"stale"}"#))
            acc.consume(
                line: toolUseLine(
                    "TodoWrite",
                    #"{"todos":[{"content":"A","status":"completed"},{"content":"B","status":"in_progress"}]}"#
                ))
            await expectEqual(acc.tasks.total, 2)
            await expectEqual(acc.tasks.summary, "1/2")
            await expectEqual(acc.tasks.current?.subject, "B")
        }

        test("A deleted task leaves the list") {
            var acc = TranscriptAccumulator()
            acc.consume(line: toolUseLine("TaskCreate", #"{"subject":"one"}"#))
            acc.consume(line: toolUseLine("TaskUpdate", #"{"taskId":"1","status":"deleted"}"#))
            await expectEqual(acc.tasks.total, 0)
        }

        test("An update for an unknown id is ignored") {
            var acc = TranscriptAccumulator()
            acc.consume(line: toolUseLine("TaskUpdate", #"{"taskId":"99","status":"completed"}"#))
            await expectEqual(acc.tasks.total, 0)
        }

        test("current prefers in_progress, else the first pending") {
            var p = TaskProgress()
            p.applyCreate(.object(["subject": .string("a")]))
            p.applyCreate(.object(["subject": .string("b")]))
            await expectEqual(p.current?.subject, "a")
            p.applyUpdate(.object(["taskId": .string("2"), "status": .string("in_progress")]))
            await expectEqual(p.current?.subject, "b")
        }

        test("Branch and effort are picked up from any line") {
            var acc = TranscriptAccumulator()
            acc.consume(
                line: toolUseLine(
                    "TaskCreate", #"{"subject":"x"}"#, branch: "feature/auth", effort: "xhigh"))
            await expectEqual(acc.gitBranch, "feature/auth")
            await expectEqual(acc.effort, "xhigh")
        }

        test("Titles are read from the sidecar records the terminal tab uses") {
            var acc = TranscriptAccumulator()
            acc.consume(
                line: Data(
                    #"{"type":"ai-title","aiTitle":"Do not truncate the branch name","sessionId":"s1"}"#
                        .utf8))
            await expectEqual(acc.aiTitle, "Do not truncate the branch name")
            await expectEqual(acc.customTitle, nil)

            acc.consume(
                line: Data(
                    #"{"type":"custom-title","customTitle":"debug playwright","sessionId":"s1"}"#
                        .utf8))
            await expectEqual(acc.customTitle, "debug playwright")
            // The two are kept apart: a rename must not erase what it outranks,
            // or clearing it later would leave the session with no title at all.
            await expectEqual(acc.aiTitle, "Do not truncate the branch name")
        }

        test("A re-emitted title on resume does not disturb the accumulator") {
            // Claude Code writes the ai-title record again on every resume. In 50
            // real transcripts the value never varied within a session, so last
            // -wins is stable — but an empty re-emission must not blank it.
            var acc = TranscriptAccumulator()
            let line = #"{"type":"ai-title","aiTitle":"Fix scroll functionality issue"}"#
            acc.consume(line: Data(line.utf8))
            acc.consume(line: Data(line.utf8))
            acc.consume(line: Data(#"{"type":"ai-title","aiTitle":""}"#.utf8))
            await expectEqual(acc.aiTitle, "Fix scroll functionality issue")
        }

        test("An empty plan reports no summary") {
            await expectEqual(TaskProgress().summary, nil)
            await expect(TaskProgress().isEmpty)
        }
    }
}
