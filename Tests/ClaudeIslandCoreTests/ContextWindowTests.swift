import ClaudeIslandCore
import Foundation

/// Writes a `~/.claude.json`-shaped file recording, per project, which models
/// that project's last session used.
private func tempConfig(_ projects: [String: [String]]) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("island-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(".claude.json")

    var body: [String: Any] = [:]
    for (cwd, models) in projects {
        var usage: [String: Any] = [:]
        for m in models {
            usage[m] = ["inputTokens": 1, "outputTokens": 1, "costUSD": 0.1]
        }
        body[cwd] = ["lastModelUsage": usage, "lastSessionId": UUID().uuidString]
    }
    let root: [String: Any] = ["projects": body, "theme": "dark"]
    try JSONSerialization.data(withJSONObject: root).write(to: url)
    return url
}

func registerContextWindowTests() {
    suite("ContextWindow") {
        test("plain model id with nothing else known reads as the small tier") {
            await expectEqual(ContextWindow.limit(for: "claude-opus-5"), 200_000)
        }

        test("a model id carrying the suffix reads as the large tier") {
            await expectEqual(ContextWindow.limit(for: "claude-opus-5[1m]"), 1_000_000)
            await expectEqual(ContextWindow.limit(for: "claude-sonnet-4-5-1m"), 1_000_000)
        }

        test("usage past a tier proves the next one up") {
            await expectEqual(
                ContextWindow.limit(for: "claude-opus-5", observed: 603_200), 1_000_000)
        }

        test("a long-context session is never demoted by a low reading") {
            await expectEqual(
                ContextWindow.limit(for: "claude-opus-5", observed: 12, longContext: true),
                1_000_000)
        }

        test("fraction clamps and stays at zero before the first reading") {
            await expectEqual(ContextWindow.fraction(used: 0, model: "claude-opus-5"), 0)
            await expectEqual(ContextWindow.fraction(used: 100_000, model: "claude-opus-5"), 0.5)
            await expectEqual(ContextWindow.fraction(used: 5_000_000, model: "claude-opus-5"), 1)
        }
    }

    suite("ClaudeConfig") {
        // The bug this whole path exists for: the transcript records the plain
        // id for a session running the million-token variant, so the suffix has
        // to be recovered from the project's usage ledger.
        test("the suffix recorded for this project promotes the plain id") {
            let url = try tempConfig(["/w/island": ["claude-haiku-4-5", "claude-opus-5[1m]"]])
            await expect(
                ClaudeConfig.usesLongContext(model: "claude-opus-5", cwd: "/w/island", url: url))
            await expectEqual(
                ContextWindow.limit(
                    for: "claude-opus-5", observed: 41_000,
                    longContext: ClaudeConfig.usesLongContext(
                        model: "claude-opus-5", cwd: "/w/island", url: url)),
                1_000_000)
        }

        test("a suffix belonging to another model does not promote this one") {
            let url = try tempConfig(["/w/island": ["claude-sonnet-5[1m]"]])
            await expect(
                !ClaudeConfig.usesLongContext(model: "claude-opus-5", cwd: "/w/island", url: url))
        }

        test("a suffix belonging to another project does not promote this one") {
            let url = try tempConfig(["/w/other": ["claude-opus-5[1m]"]])
            await expect(
                !ClaudeConfig.usesLongContext(model: "claude-opus-5", cwd: "/w/island", url: url))
        }

        test("a project that has only ever run the small tier stays small") {
            let url = try tempConfig(["/w/island": ["claude-opus-5"]])
            await expect(
                !ClaudeConfig.usesLongContext(model: "claude-opus-5", cwd: "/w/island", url: url))
        }

        test("an absent or unreadable config is not an opinion") {
            let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
            await expect(
                !ClaudeConfig.usesLongContext(model: "claude-opus-5", cwd: "/w/x", url: missing))
            await expect(ClaudeConfig.usesLongContext(model: nil, cwd: "/w/x", url: missing) == false)
        }

        test("the ledger is re-read once the file changes underneath us") {
            let url = try tempConfig(["/w/island": ["claude-opus-5"]])
            await expect(
                !ClaudeConfig.usesLongContext(model: "claude-opus-5", cwd: "/w/island", url: url))

            let rewritten = try tempConfig(["/w/island": ["claude-opus-5[1m]"]])
            try FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: rewritten, to: url)

            await expect(
                ClaudeConfig.usesLongContext(model: "claude-opus-5", cwd: "/w/island", url: url),
                "a config rewritten on disk must not be served from the cache")
        }
    }

    suite("SessionStore context tier") {
        test("the tier is stamped on the session when the model arrives") {
            let store = SessionStore(
                scheduler: VirtualScheduler(),
                longContextResolver: { model, cwd in
                    model == "claude-opus-5" && cwd == "/w/island"
                })
            await store.ingest(
                HookEnvelope(sessionID: "a", event: .sessionStart, cwd: "/w/island"))
            await store.applyTranscript(
                TranscriptUpdate(
                    sessionID: "a", model: "claude-opus-5", tokens: TokenStats()))

            let session = try await require(await store.session("a"))
            await expect(session.usesLongContext)
            await expectEqual(ContextWindow.limit(for: session), 1_000_000)
        }

        test("a project with no long-context history stays on the small tier") {
            let store = SessionStore(
                scheduler: VirtualScheduler(), longContextResolver: { _, _ in false })
            await store.ingest(
                HookEnvelope(sessionID: "b", event: .sessionStart, cwd: "/w/plain"))
            await store.applyTranscript(
                TranscriptUpdate(
                    sessionID: "b", model: "claude-opus-5", tokens: TokenStats()))

            let session = try await require(await store.session("b"))
            await expect(!session.usesLongContext)
            await expectEqual(ContextWindow.limit(for: session), 200_000)
        }
    }
}
