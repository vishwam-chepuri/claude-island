import ClaudeIslandCore
import Foundation

/// One entry in the shape Claude Code actually writes, recorded from
/// `~/.claude/sessions` on 2.1.235. Trimmed of the fields the reader ignores
/// except for a couple left in on purpose — `status` and `version` — so that a
/// build which starts caring about them has a fixture that already carries them.
private func entry(pid: Int32, session: String, cwd: String = "/Users/dev/code") -> String {
    """
    {"pid":\(pid),"sessionId":"\(session)","cwd":"\(cwd)","startedAt":1787146980910,
    "procStart":"Wed Aug 19 12:05:26 2026","version":"2.1.235","kind":"interactive",
    "entrypoint":"cli","status":"busy","updatedAt":1787146993457}
    """
}

/// Runs `body` against a registry directory holding `files`.
private func withRegistry(
    _ files: [String: String], _ body: (URL) async throws -> Void
) async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("island-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, contents) in files {
        try contents.write(
            to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try await body(dir)
}

func registerLiveSessionRegistryTests() {
    suite("LiveSessionRegistry") {

        test("A listed session whose process is alive is running") {
            try await withRegistry(["4242.json": entry(pid: 4242, session: "a")]) { dir in
                let live = LiveSessionRegistry.read(from: dir, isProcessAlive: { $0 == 4242 })
                await expectEqual(live.isReadable, true)
                await expectEqual(live.ids, ["a"])
                await expect(live.isRunning("a"))
            }
        }

        // The one exit that leaves an entry behind: `kill -9` gives the session no
        // chance to clean up after itself. Without the pid check the file alone
        // would keep the HUD showing it forever.
        test("An entry whose process has exited is not running") {
            try await withRegistry(["4242.json": entry(pid: 4242, session: "a")]) { dir in
                let live = LiveSessionRegistry.read(from: dir, isProcessAlive: { _ in false })
                await expectEqual(live.isReadable, true)
                await expect(live.ids.isEmpty, "a killed session was reported alive")
            }
        }

        // The directory is Claude Code's, not ours: it holds whatever that build
        // decides to put there, in whatever shape a future version prefers. One
        // unreadable file must cost that file only.
        test("Unreadable entries cost only themselves") {
            let files = [
                "1.json": entry(pid: 1, session: "good"),
                "2.json": "{ this is not json",
                "3.json": "{\"pid\":3}",
                "4.json": "{\"sessionId\":\"no-pid\"}",
                "5.json": "{\"pid\":5,\"sessionId\":\"\"}",
                "notes.txt": entry(pid: 6, session: "wrong-extension"),
            ]
            try await withRegistry(files) { dir in
                let live = LiveSessionRegistry.read(from: dir, isProcessAlive: { _ in true })
                await expectEqual(live.ids, ["good"])
            }
        }

        test("Several sessions are all read") {
            let files = [
                "1.json": entry(pid: 1, session: "a"),
                "2.json": entry(pid: 2, session: "b"),
                "3.json": entry(pid: 3, session: "c"),
            ]
            try await withRegistry(files) { dir in
                let live = LiveSessionRegistry.read(from: dir, isProcessAlive: { $0 != 2 })
                await expectEqual(live.ids, ["a", "c"])
            }
        }

        // The distinction the whole type turns on. A missing directory has said
        // nothing, and reading that as "no sessions are running" would sweep every
        // session on a machine whose Claude Code keeps no registry.
        test("A missing directory answers nothing, not nothing-running") {
            let absent = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("island-registry-absent-\(UUID().uuidString)")
            let live = LiveSessionRegistry.read(from: absent, isProcessAlive: { _ in true })
            await expectEqual(live.isReadable, false)
            await expectEqual(live, .unavailable)
        }

        test("An empty directory is an answer") {
            try await withRegistry([:]) { dir in
                let live = LiveSessionRegistry.read(from: dir, isProcessAlive: { _ in true })
                await expectEqual(live.isReadable, true)
                await expect(live.ids.isEmpty)
            }
        }
    }
}
