import ClaudeIslandCore
import Foundation

/// A status-line payload shaped like the one Claude Code actually emits,
/// trimmed to the fields that matter here.
private func statuslinePayload(
    sessionID: String = "s1", windowSize: Int? = 1_000_000, modelID: String = "claude-opus-5[1m]",
    linesAdded: Int? = 412, linesRemoved: Int? = 86,
    fiveHourUsed: Double? = 43.5, resetsAt: Any? = 1_786_300_200
) -> Data {
    var context: [String: Any] = [
        "total_input_tokens": 95860,
        "total_output_tokens": 465,
        "used_percentage": 10,
        "remaining_percentage": 90,
    ]
    if let windowSize { context["context_window_size"] = windowSize }
    var cost: [String: Any] = [
        "total_cost_usd": 1.42,
        "total_duration_ms": 900_000,
        "total_api_duration_ms": 310_000,
    ]
    if let linesAdded { cost["total_lines_added"] = linesAdded }
    if let linesRemoved { cost["total_lines_removed"] = linesRemoved }
    var body: [String: Any] = [
        "session_id": sessionID,
        "cwd": "/w/island",
        "transcript_path": "/t/\(sessionID).jsonl",
        "model": ["id": modelID, "display_name": "Opus 5 (1M context)"],
        "context_window": context,
        "cost": cost,
        "version": "2.1.224",
    ]
    if let fiveHourUsed {
        var window: [String: Any] = ["used_percentage": fiveHourUsed]
        if let resetsAt { window["resets_at"] = resetsAt }
        body["rate_limits"] = ["five_hour": window, "seven_day": ["used_percentage": 12.0]]
    }
    return try! JSONSerialization.data(withJSONObject: body)
}

private func tempScript(_ contents: String, name: String = "statusline-command.sh") throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("island-statusline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func tempSettings(_ object: [String: Any]) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("island-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("settings.json")
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    return url
}

private let realScript = """
    #!/bin/sh
    input=$(cat)

    cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty')
    model=$(echo "$input" | jq -r '.model.display_name // empty')
    printf '%s %s' "$model" "$cwd"
    """

func registerStatuslineTests() {
    suite("Statusline payload") {
        test("a payload with no hook event decodes as a status-line report") {
            let env = try await require(try HookEnvelope.decode(statuslinePayload()))
            await expectEqual(env.event, .statusline)
            await expectEqual(env.contextWindowSize, 1_000_000)
            await expectEqual(env.sessionID, "s1")
        }

        test("a real hook payload is untouched by the new field") {
            let hook = try! JSONSerialization.data(withJSONObject: [
                "session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "Read",
            ])
            let env = try await require(try HookEnvelope.decode(hook))
            await expectEqual(env.event, .preToolUse)
            await expectEqual(env.contextWindowSize, nil)
        }

        test("a payload with no window size is not mistaken for a report") {
            let env = try await require(
                try HookEnvelope.decode(statuslinePayload(windowSize: nil)))
            await expect(env.event != .statusline, "got \(env.event)")
            await expectEqual(env.contextWindowSize, nil)
        }

        test("the stated window settles the limit, beating both inferences") {
            let store = SessionStore(
                scheduler: VirtualScheduler(), longContextResolver: { _, _ in false })
            await store.ingest(HookEnvelope(sessionID: "s1", event: .sessionStart, cwd: "/w/x"))
            await store.applyTranscript(
                TranscriptUpdate(sessionID: "s1", model: "claude-opus-5", tokens: TokenStats()))

            var before = try await require(await store.session("s1"))
            await expectEqual(ContextWindow.limit(for: before), 200_000)

            await store.ingest(try await require(try HookEnvelope.decode(statuslinePayload())))
            before = try await require(await store.session("s1"))
            await expectEqual(before.contextLimit, 1_000_000)
            await expectEqual(ContextWindow.limit(for: before), 1_000_000)
        }

        // The whole reason this bypasses the reducer: the status line re-renders
        // continuously, and a bumped lastEventAt would pin the session at the
        // top of `priority` and hold the idle sweep off forever.
        test("a status-line report does not count as activity") {
            let clock = ClockBox(now: base)
            let store = SessionStore(scheduler: VirtualScheduler(), now: { clock.value })
            await store.ingest(
                HookEnvelope(sessionID: "s1", event: .stop, cwd: "/w/x", receivedAt: base))
            let idleSince = try await require(await store.session("s1")).lastEventAt

            clock.value = base.addingTimeInterval(600)
            await store.ingest(
                try await require(
                    try HookEnvelope.decode(
                        statuslinePayload(), receivedAt: base.addingTimeInterval(600))))

            let after = try await require(await store.session("s1"))
            await expectEqual(after.lastEventAt, idleSince, "status line must not look like activity")
            await expectEqual(after.state.traceName, "done", "state must be untouched")
        }

        test("a report for a session we do not track is dropped") {
            let store = SessionStore(scheduler: VirtualScheduler())
            await store.ingest(
                try await require(try HookEnvelope.decode(statuslinePayload(sessionID: "ghost"))))
            await expectEqual(await store.allSessions().count, 0)
        }

        test("lines changed and the 5-hour window ride the same payload") {
            let env = try await require(try HookEnvelope.decode(statuslinePayload()))
            await expectEqual(env.linesAdded, 412)
            await expectEqual(env.linesRemoved, 86)
            let window = try await require(env.rateLimit)
            await expect(
                abs(window.usedFraction - 0.435) < 0.0001, "got \(window.usedFraction)")
            await expectEqual(
                window.resetsAt,
                Date(timeIntervalSince1970: 1_786_300_200),
                "2026-08-09T18:30:00Z")
        }

        // Claude Code forwards the `anthropic-ratelimit-unified-5h-reset`
        // header as the epoch integer it arrives as, but converts the same
        // field to an ISO string when it came from the account-usage fetch —
        // and that one carries milliseconds only sometimes. Reading a single
        // shape does not fail loudly; the countdown simply never appears.
        test("every shape the reset stamp arrives in is understood") {
            for stamp in [
                1_786_300_200 as Any,
                "2026-08-09T18:30:00.000Z",
                "2026-08-09T18:30:00Z",
            ] {
                let env = try await require(
                    try HookEnvelope.decode(statuslinePayload(resetsAt: stamp)))
                await expectEqual(
                    try await require(env.rateLimit).resetsAt,
                    Date(timeIntervalSince1970: 1_786_300_200),
                    "\(stamp)")
            }
        }

        test("a window with no reset stamp still reports its usage") {
            let env = try await require(
                try HookEnvelope.decode(statuslinePayload(resetsAt: nil)))
            let window = try await require(env.rateLimit)
            await expect(abs(window.usedFraction - 0.435) < 0.0001, "got \(window.usedFraction)")
            await expectEqual(window.resetsAt, nil)
        }

        // Absent, never zero: a 0% bar is a claim that the account has used
        // nothing, which is the opposite of "nobody told us".
        test("a payload with no rate limits reports none rather than an empty one") {
            let env = try await require(
                try HookEnvelope.decode(statuslinePayload(fiveHourUsed: nil)))
            await expectEqual(env.rateLimit, nil)
        }

        test("a percentage past 100 cannot draw a bar longer than its track") {
            await expectEqual(RateLimitWindow(usedPercentage: 140).usedFraction, 1)
            await expectEqual(RateLimitWindow(usedPercentage: -3).usedFraction, 0)
        }

        test("lines changed land on the session the payload names") {
            let store = SessionStore(scheduler: VirtualScheduler())
            await store.ingest(HookEnvelope(sessionID: "s1", event: .sessionStart, cwd: "/w/x"))
            await store.ingest(try await require(try HookEnvelope.decode(statuslinePayload())))

            let s = try await require(await store.session("s1"))
            await expectEqual(s.linesAdded, 412)
            await expectEqual(s.linesRemoved, 86)
            await expect(s.hasLineChanges)
        }

        // A resumed or cleared session reuses the id, and carrying the previous
        // run's diff into it would credit this session with work it never did.
        test("SessionStart clears the line counts with the rest of the totals") {
            let store = SessionStore(scheduler: VirtualScheduler())
            await store.ingest(HookEnvelope(sessionID: "s1", event: .sessionStart, cwd: "/w/x"))
            await store.ingest(try await require(try HookEnvelope.decode(statuslinePayload())))
            await store.ingest(HookEnvelope(sessionID: "s1", event: .sessionStart, cwd: "/w/x"))

            let s = try await require(await store.session("s1"))
            await expectEqual(s.linesAdded, 0)
            await expect(!s.hasLineChanges)
        }

        // The window is the account's, so it has to survive a session it did
        // not arrive with — including one that has not started yet.
        test("the 5-hour window is kept across sessions, not inside one") {
            let store = SessionStore(scheduler: VirtualScheduler())
            await store.ingest(
                try await require(try HookEnvelope.decode(statuslinePayload(sessionID: "ghost"))))
            await expectEqual(await store.allSessions().count, 0)

            await store.ingest(HookEnvelope(sessionID: "s2", event: .sessionStart, cwd: "/w/x"))
            let window = try await require(await store.currentSnapshot().rateLimit)
            await expect(abs(window.usedFraction - 0.435) < 0.0001, "got \(window.usedFraction)")
        }

        test("a count past the stated window still floors the bar") {
            var s = Session(id: "s1", startedAt: base)
            s.contextLimit = 200_000
            s.tokens.contextTokens = 250_000
            await expectEqual(ContextWindow.limit(for: s), 250_000)
            await expectEqual(ContextWindow.fraction(for: s), 1)
        }
    }

    suite("Statusline installer") {
        test("the forward line lands right after the stdin capture") {
            let script = try tempScript(realScript)
            let outcome = try StatuslineInstaller.install(
                binaryPath: "/Apps/Island.app/claude-island-notify", scriptURL: script)
            await expect(outcome.didChange, "expected an edit, got \(outcome)")

            let lines = try String(contentsOf: script, encoding: .utf8)
                .components(separatedBy: "\n")
            await expectEqual(lines[1], "input=$(cat)")
            await expect(lines[2].contains(StatuslineInstaller.marker))
            await expect(lines[2].contains("\"$input\""), "must reuse the script's own variable")
            // Everything the user wrote survives.
            await expect(lines.contains { $0.contains("jq -r '.model.display_name // empty'") })
        }

        test("a path with spaces is quoted") {
            let script = try tempScript(realScript)
            _ = try StatuslineInstaller.install(
                binaryPath: "/Users/me/personal projects/x/claude-island-notify",
                scriptURL: script)
            let text = try String(contentsOf: script, encoding: .utf8)
            await expect(text.contains("\"/Users/me/personal projects/x/claude-island-notify\""))
        }

        test("reinstalling repeatedly adds nothing further") {
            let script = try tempScript(realScript)
            _ = try StatuslineInstaller.install(binaryPath: "/bin/notify", scriptURL: script)
            let once = try String(contentsOf: script, encoding: .utf8)
            let second = try StatuslineInstaller.install(
                binaryPath: "/bin/notify", scriptURL: script)
            await expectEqual(second, .alreadyInstalled(script: script.path))
            await expectEqual(try String(contentsOf: script, encoding: .utf8), once)
        }

        test("uninstall removes only our line") {
            let script = try tempScript(realScript)
            _ = try StatuslineInstaller.install(binaryPath: "/bin/notify", scriptURL: script)
            let outcome = try StatuslineInstaller.uninstall(scriptURL: script)
            await expectEqual(outcome, .removed(script: script.path))
            await expectEqual(try String(contentsOf: script, encoding: .utf8), realScript)
        }

        test("uninstall on a script we never touched is a no-op") {
            let script = try tempScript(realScript)
            await expectEqual(try StatuslineInstaller.uninstall(scriptURL: script), .notPresent)
            await expectEqual(try String(contentsOf: script, encoding: .utf8), realScript)
        }

        test("a backup is written before the edit") {
            let script = try tempScript(realScript)
            let outcome = try StatuslineInstaller.install(
                binaryPath: "/bin/notify", scriptURL: script)
            guard case .installed(_, let backup) = outcome, let backup else {
                return await fail("expected a backup path, got \(outcome)")
            }
            await expectEqual(
                try String(contentsOf: URL(fileURLWithPath: backup), encoding: .utf8), realScript)
        }

        test("the executable bit survives the rewrite") {
            let script = try tempScript(realScript)
            _ = try StatuslineInstaller.install(binaryPath: "/bin/notify", scriptURL: script)
            let mode = try FileManager.default.attributesOfItem(atPath: script.path)[
                .posixPermissions] as? NSNumber
            await expectEqual(mode?.int16Value, 0o755)
        }

        test("a script whose stdin capture we cannot see is declined, not guessed at") {
            let script = try tempScript("#!/bin/sh\necho hello\n")
            let outcome = try StatuslineInstaller.install(
                binaryPath: "/bin/notify", scriptURL: script)
            await expectEqual(outcome, .skipped(reason: .noStdinCapture(script.path)))
            await expectEqual(try String(contentsOf: script, encoding: .utf8), "#!/bin/sh\necho hello\n")
        }

        test("other stdin idioms are recognised and their variable reused") {
            for (body, variable) in [
                ("#!/bin/sh\npayload=`cat`\n", "payload"),
                ("#!/bin/sh\nraw=$(cat -)\n", "raw"),
                ("#!/bin/sh\njson=$(</dev/stdin)\n", "json"),
            ] {
                let script = try tempScript(body)
                _ = try StatuslineInstaller.install(binaryPath: "/bin/notify", scriptURL: script)
                let text = try String(contentsOf: script, encoding: .utf8)
                await expect(text.contains("\"$\(variable)\""), "expected $\(variable) in \(text)")
            }
        }

        test("a commented-out capture is not mistaken for the real one") {
            let script = try tempScript("#!/bin/sh\n# input=$(cat)\nreal=$(cat)\n")
            _ = try StatuslineInstaller.install(binaryPath: "/bin/notify", scriptURL: script)
            let text = try String(contentsOf: script, encoding: .utf8)
            await expect(text.contains("\"$real\""), "got \(text)")
        }
    }

    suite("Statusline script discovery") {
        test("the script behind a command statusline is found") {
            let script = try tempScript(realScript)
            let settings = try tempSettings([
                "statusLine": ["type": "command", "command": "sh \(script.path)"]
            ])
            await expectEqual(
                try StatuslineInstaller.scriptURL(settingsURL: settings)?.path, script.path)
        }

        test("a quoted path with spaces is found") {
            let script = try tempScript(realScript, name: "my status line.sh")
            let settings = try tempSettings([
                "statusLine": ["type": "command", "command": "sh \"\(script.path)\""]
            ])
            await expectEqual(
                try StatuslineInstaller.scriptURL(settingsURL: settings)?.path, script.path)
        }

        test("an inline command has no script and is declined") {
            let settings = try tempSettings([
                "statusLine": ["type": "command", "command": "jq -r '.model.display_name'"]
            ])
            await expectEqual(try StatuslineInstaller.scriptURL(settingsURL: settings), nil)
            await expectEqual(
                try StatuslineInstaller.install(binaryPath: "/bin/notify", settingsURL: settings),
                .skipped(reason: .noStatuslineConfigured))
        }

        test("no statusLine at all is declined rather than installed over") {
            let settings = try tempSettings(["theme": "dark"])
            await expectEqual(
                try StatuslineInstaller.install(binaryPath: "/bin/notify", settingsURL: settings),
                .skipped(reason: .noStatuslineConfigured))
        }
    }
}
