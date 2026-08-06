import ClaudeIslandCore
import Foundation

private func tempSettings(_ contents: String?) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("island-installer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("settings.json")
    if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
    return url
}

private func readJSON(_ url: URL) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]) ?? [:]
}

private func hookEntries(_ settings: [String: Any], event: String) -> [[String: Any]] {
    let hooks = (settings["hooks"] as? [String: Any]) ?? [:]
    let matchers = (hooks[event] as? [[String: Any]]) ?? []
    return matchers.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
}

/// A settings.json shaped like the one already on this machine: an unrelated
/// HTTP hook receiver across several events, plus a command hook.
private let existingSettings = """
    {
      "theme": "dark",
      "permissions": {"allow": ["Bash(ls:*)"]},
      "hooks": {
        "PreToolUse": [
          {"matcher": "", "hooks": [{"type": "http", "url": "http://127.0.0.1:19847/hook/pre", "timeout": 3}]}
        ],
        "SessionEnd": [
          {"matcher": "", "hooks": [{"type": "command", "command": "~/.claude/hooks/session-end-notify.sh"}]},
          {"matcher": "", "hooks": [{"type": "http", "url": "http://127.0.0.1:19847/hook/end", "timeout": 3}]}
        ]
      }
    }
    """

private let notifyPath = "/opt/bin/claude-island-notify"

func registerHookInstallerTests() {
    suite("Hook installer") {

        test("Installing preserves unrelated hooks and unrelated settings keys") {
            let url = try tempSettings(existingSettings)
            let result = try HookInstaller.install(binaryPath: notifyPath, settingsURL: url)
            let after = try readJSON(url)

            await expectEqual(after["theme"] as? String, "dark")
            await expect(after["permissions"] != nil, "permissions block was dropped")
            await expect(result.preservedOtherHooks > 0)

            let pre = hookEntries(after, event: "PreToolUse")
            await expect(
                pre.contains { ($0["url"] as? String)?.contains("19847") == true },
                "clobbered the user's HTTP receiver")
            await expect(
                pre.contains { ($0["command"] as? String)?.contains("claude-island-notify") == true }
            )

            // The user's two separate SessionEnd matchers both survive.
            let end = hookEntries(after, event: "SessionEnd")
            await expect(
                end.contains { ($0["command"] as? String)?.contains("session-end-notify") == true })
            await expect(end.contains { ($0["url"] as? String)?.contains("19847") == true })
        }

        test("Every installable event is written") {
            let url = try tempSettings(nil)
            try HookInstaller.install(binaryPath: notifyPath, settingsURL: url)
            let hooks = (try readJSON(url)["hooks"] as? [String: Any]) ?? [:]
            for event in HookEvent.installable {
                await expect(hooks[event.name] != nil, "missing \(event.name)")
            }
            await expectEqual(hooks.count, HookEvent.installable.count)
        }

        test("Reinstalling repeatedly does not duplicate our entries") {
            let url = try tempSettings(existingSettings)
            for _ in 0..<3 {
                try HookInstaller.install(binaryPath: notifyPath, settingsURL: url)
            }
            let ours = hookEntries(try readJSON(url), event: "Stop")
                .filter { ($0["command"] as? String)?.contains("claude-island-notify") == true }
            await expectEqual(ours.count, 1)
        }

        test("Reinstalling at a new path replaces the old entry") {
            let url = try tempSettings(nil)
            try HookInstaller.install(binaryPath: "/old/claude-island-notify", settingsURL: url)
            try HookInstaller.install(binaryPath: "/new/claude-island-notify", settingsURL: url)

            let commands = hookEntries(try readJSON(url), event: "Stop")
                .compactMap { $0["command"] as? String }
            await expectEqual(commands, ["/new/claude-island-notify"])
        }

        test("A path with spaces is quoted") {
            let url = try tempSettings(nil)
            try HookInstaller.install(
                binaryPath:
                    "/Users/dev/my apps/ClaudeIsland.app/Contents/MacOS/claude-island-notify",
                settingsURL: url)
            let command = try await require(
                hookEntries(try readJSON(url), event: "Stop").first?["command"] as? String)
            await expect(command.hasPrefix("\"") && command.hasSuffix("\""), "unquoted: \(command)")
        }

        test("Uninstall removes only our entries") {
            let url = try tempSettings(existingSettings)
            try HookInstaller.install(binaryPath: notifyPath, settingsURL: url)
            await expect(HookInstaller.isInstalled(settingsURL: url))

            try HookInstaller.uninstall(settingsURL: url)
            await expect(!HookInstaller.isInstalled(settingsURL: url))

            let remaining = hookEntries(try readJSON(url), event: "PreToolUse")
            await expectEqual(remaining.count, 1)
            await expectEqual((remaining[0]["url"] as? String)?.contains("19847"), true)
        }

        test("A backup is written before any change") {
            let url = try tempSettings(existingSettings)
            let result = try HookInstaller.install(binaryPath: notifyPath, settingsURL: url)
            let backup = try await require(result.backupPath)
            await expect(FileManager.default.fileExists(atPath: backup))

            let restored = try String(contentsOfFile: backup, encoding: .utf8)
            await expect(restored.contains("19847"), "backup lost the original content")
            await expect(!restored.contains("claude-island-notify"), "backup taken after the write")
        }

        test("A missing settings.json is created from scratch") {
            let url = try tempSettings(nil)
            await expect(!FileManager.default.fileExists(atPath: url.path))
            try HookInstaller.install(binaryPath: notifyPath, settingsURL: url)
            await expect(HookInstaller.isInstalled(settingsURL: url))
        }

        test("Non-object settings are refused rather than overwritten") {
            let url = try tempSettings("[1, 2, 3]")
            await expectThrows("installing into a JSON array should throw") {
                try HookInstaller.install(binaryPath: notifyPath, settingsURL: url)
            }
            let after = try String(contentsOf: url, encoding: .utf8)
            await expectEqual(after, "[1, 2, 3]")
        }

        test("The printable block is valid JSON covering every event") {
            let text = HookInstaller.hookBlockJSON(binaryPath: notifyPath)
            let parsed =
                (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
            let hooks = (parsed["hooks"] as? [String: Any]) ?? [:]
            await expectEqual(hooks.count, HookEvent.installable.count)
        }
    }
}
