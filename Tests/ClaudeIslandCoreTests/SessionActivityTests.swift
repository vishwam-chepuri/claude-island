import ClaudeIslandCore
import Foundation

/// A transcript line carrying assistant content blocks in written order.
private func assistantBlocks(_ blocks: String, requestID: String = "r1") -> Data {
    Data(
        """
        {"type":"assistant","requestId":"\(requestID)","message":{"model":"claude-opus-5","content":[\(blocks)]}}
        """.utf8)
}

private func text(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"type\":\"text\",\"text\":\"\(escaped)\"}"
}

private func toolUse(_ name: String, _ input: String) -> String {
    "{\"type\":\"tool_use\",\"name\":\"\(name)\",\"input\":\(input)}"
}

func registerSessionActivityTests() {
    suite("Activity line") {

        // MARK: - Prose

        test("Assistant prose becomes the line") {
            let line = ActivityPhrase.fromProse("Checking whether the tally still adds up.")
            await expectEqual(line, "Checking whether the tally still adds up.")
        }

        test("Newlines and markdown indentation collapse to one line") {
            let line = ActivityPhrase.fromProse("Found it.\n\n  - in auth.ts\n  - and again in api.ts")
            await expectEqual(line, "Found it. - in auth.ts - and again in api.ts")
        }

        test("A fragment too short to mean anything is not a line") {
            // The tool actually running says more than "OK." does, so a block
            // this short must not displace it.
            await expectEqual(ActivityPhrase.fromProse("OK."), nil)
            await expectEqual(ActivityPhrase.fromProse("   "), nil)
        }

        test("A result marker outranks the prose around it") {
            let line = ActivityPhrase.fromProse(
                "That took a while, but everything is green now.\n\nresult:\nthe suite passes")
            // The marker's own line has no capture on it, so this falls back to
            // the prose rather than inventing one.
            await expectEqual(line, "That took a while, but everything is green now. result: the suite passes")

            let captured = ActivityPhrase.fromProse(
                "Long explanation of the fix.\n\nresult: the suite passes on all 183 checks")
            await expectEqual(captured, "the suite passes on all 183 checks")
        }

        test("The last marker in a turn wins") {
            let line = ActivityPhrase.fromProse(
                "result: an early claim\nmore work happened\nresult: the final claim")
            await expectEqual(line, "the final claim")
        }

        test("A marker named mid-sentence is not a use of one") {
            let line = ActivityPhrase.fromProse(
                "The harness asks for a result: line at the end of a background job.")
            await expectEqual(
                line, "The harness asks for a result: line at the end of a background job.")
        }

        // MARK: - Tool phrases

        test("An imperative description is put in the present participle") {
            let line = ActivityPhrase.fromTool(
                name: "Bash", input: .object(["description": .string("Run the test suite")]))
            await expectEqual(line, "Running the test suite")
        }

        test("Verbs that double their final consonant are not mangled") {
            for (given, expected) in [
                ("Commit the fix", "Committing the fix"),
                ("Drop the stale branch", "Dropping the stale branch"),
                ("Write the report", "Writing the report"),
                ("Verify the tally", "Verifying the tally"),
                ("Sync the worktree", "Syncing the worktree"),
                ("Reset the offset", "Resetting the offset"),
            ] {
                let line = ActivityPhrase.fromTool(
                    name: "Bash", input: .object(["description": .string(given)]))
                await expectEqual(line, expected, "\(given) -> \(expected)")
            }
        }

        test("A description that does not open on a known verb is left alone") {
            // The safe failure. Tool descriptions are imperative by convention,
            // not by enforcement, and "Sessioning metadata storage" would be a
            // conspicuous guess.
            let line = ActivityPhrase.fromTool(
                name: "Bash", input: .object(["description": .string("Session metadata storage")]))
            await expectEqual(line, "Session metadata storage")
        }

        test("A tool with no description falls back to its target") {
            let line = ActivityPhrase.fromTool(
                name: "Edit", input: .object(["file_path": .string("/tmp/IslandViewModel.swift")]))
            await expectEqual(line, "Editing /tmp/IslandViewModel.swift")
        }

        test("A tool with neither description nor target still says something") {
            let line = ActivityPhrase.fromTool(name: "TodoWrite", input: .object([:]))
            await expectEqual(line, "Updating its task list")
        }

        test("A blocking question is quoted rather than described") {
            let line = ActivityPhrase.fromTool(
                name: "AskUserQuestion",
                input: .object([
                    "questions": .array([.object(["question": .string("Which tier should ship?")])])
                ]))
            await expectEqual(line, "Which tier should ship?")
        }

        // MARK: - Ordering through the accumulator

        test("The last block written is the line, whichever kind it is") {
            var acc = TranscriptAccumulator()
            acc.consume(
                line: assistantBlocks(
                    [
                        text("Let me look at how the card is sized."),
                        toolUse("Read", "{\"file_path\":\"/tmp/IslandViewModel.swift\"}"),
                    ].joined(separator: ",")))
            // Prose came first, the call came after, so the call is what it is doing.
            await expectEqual(acc.activity, "Reading /tmp/IslandViewModel.swift")

            acc.consume(
                line: assistantBlocks(
                    text("The tally is one point short of what the row draws."), requestID: "r2"))
            await expectEqual(acc.activity, "The tally is one point short of what the row draws.")
        }

        test("A turn with nothing worth saying leaves the previous line standing") {
            var acc = TranscriptAccumulator()
            acc.consume(line: assistantBlocks(text("Rebuilding after the height correction.")))
            acc.consume(line: assistantBlocks(text("OK."), requestID: "r2"))
            await expectEqual(acc.activity, "Rebuilding after the height correction.")
        }

        test("A session that has said nothing has no line at all") {
            var acc = TranscriptAccumulator()
            acc.consume(line: Data("{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}".utf8))
            await expectEqual(acc.activity, nil)
        }

        test("Secrets in narrated output are redacted, not drawn") {
            let line = ActivityPhrase.fromProse(
                "Exported the token: sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            await expect(
                line?.contains("sk-ant-api03-AAAA") != true,
                "a narrated secret must not reach the card: \(line ?? "nil")")
        }

        test("A line too long for any row is capped") {
            let long = String(repeating: "extracting the classifier state machine ", count: 20)
            let line = ActivityPhrase.fromProse(long)
            await expect(
                (line?.count ?? 0) <= ActivityPhrase.limit,
                "expected <= \(ActivityPhrase.limit), got \(line?.count ?? 0)")
        }
    }

    suite("Job store") {

        test("The classifier's line is read for the session that owns it") {
            let root = try jobStore([
                "f62a2786": record(session: "f62a2786-d3e6", detail: "merging the last two worktrees")
            ])
            defer { try? FileManager.default.removeItem(at: root) }

            let state = JobStateReader(root: root).state(forSessionID: "f62a2786-d3e6")
            await expectEqual(state?.detail, "merging the last two worktrees")
        }

        test("A directory that has come to hold another session is not read for this one") {
            // Job directories are reused when a session is resumed, so a cached
            // path can legitimately start describing somebody else's work.
            let root = try jobStore(["j1": record(session: "second-session", detail: "its work")])
            defer { try? FileManager.default.removeItem(at: root) }

            await expectEqual(JobStateReader(root: root).state(forSessionID: "first-session"), nil)
        }

        test("An empty line is no line") {
            let root = try jobStore(["j1": record(session: "s", detail: "   ")])
            defer { try? FileManager.default.removeItem(at: root) }

            await expectEqual(JobStateReader(root: root).state(forSessionID: "s"), nil)
        }

        test("A miss does not rewalk the store until the interval is up") {
            // The miss path is the common one — an ordinary terminal session has
            // no job directory and never will — so this is what keeps a HUD that
            // sees a transcript event per second off the file system.
            let root = try jobStore([:])
            defer { try? FileManager.default.removeItem(at: root) }
            let reader = JobStateReader(root: root)
            let start = Date(timeIntervalSince1970: 1_700_000_000)

            await expectEqual(reader.state(forSessionID: "late", now: start), nil)

            let dir = root.appendingPathComponent("late-job", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(record(session: "late", detail: "started just now").utf8)
                .write(to: dir.appendingPathComponent("state.json"))

            await expectEqual(
                reader.state(forSessionID: "late", now: start.addingTimeInterval(1)), nil,
                "a rescan a second later is throttled")
            await expectEqual(
                reader.state(
                    forSessionID: "late",
                    now: start.addingTimeInterval(JobStateReader.rescanInterval + 1))?.detail,
                "started just now")
        }

        // MARK: - Which line the card ends up drawing

        test("Claude Code's own line outranks the one derived here") {
            let store = SessionStore(
                scheduler: VirtualScheduler(), now: { base },
                isProcessAlive: { _ in true },
                jobState: { _ in
                    JobState(detail: "auditing the tally", updatedAt: base.addingTimeInterval(-10))
                })
            await store.ingest(HookEnvelope(sessionID: "a", event: .sessionStart, receivedAt: base))
            await store.applyTranscript(
                TranscriptUpdate(
                    sessionID: "a", model: nil, tokens: TokenStats(),
                    activity: "Reading SelfTest.swift"))

            let activity = await store.session("a")?.activity
            await expectEqual(activity?.text, "auditing the tally")
            await expectEqual(activity?.source, .jobStore)
        }

        test("A reading that has stopped keeping up gives way to the transcript") {
            let store = SessionStore(
                scheduler: VirtualScheduler(), now: { base },
                isProcessAlive: { _ in true },
                jobState: { _ in
                    JobState(
                        detail: "something from ten minutes ago",
                        updatedAt: base.addingTimeInterval(-600))
                })
            await store.ingest(HookEnvelope(sessionID: "a", event: .sessionStart, receivedAt: base))
            await store.applyTranscript(
                TranscriptUpdate(
                    sessionID: "a", model: nil, tokens: TokenStats(),
                    activity: "Reading SelfTest.swift"))

            let activity = await store.session("a")?.activity
            await expectEqual(activity?.text, "Reading SelfTest.swift")
            await expectEqual(activity?.source, .transcript)
        }

        test("A session with no job directory still gets a line") {
            let store = SessionStore(
                scheduler: VirtualScheduler(), now: { base },
                isProcessAlive: { _ in true }, jobState: { _ in nil })
            await store.ingest(HookEnvelope(sessionID: "a", event: .sessionStart, receivedAt: base))
            await store.applyTranscript(
                TranscriptUpdate(
                    sessionID: "a", model: nil, tokens: TokenStats(),
                    activity: "Running the test suite"))

            await expectEqual(await store.session("a")?.activity?.text, "Running the test suite")
        }
    }
}

/// A `state.json` in the shape Claude Code writes, trimmed to the fields read.
private func record(session: String, detail: String) -> String {
    """
    {"state":"working","detail":"\(detail)","tempo":"active",
     "sessionId":"\(session)","updatedAt":"2026-08-15T11:07:01.926Z"}
    """
}

/// A throwaway job store on disk, so the reader is exercised against real files
/// rather than the machine's own `~/.claude/jobs`.
private func jobStore(_ dirs: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("island-jobs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, json) in dirs {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("state.json"))
    }
    return root
}
