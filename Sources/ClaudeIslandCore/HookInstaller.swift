import Foundation

/// Generates and installs the Claude Code hook block.
///
/// Merges into an existing settings.json rather than replacing it. Users
/// commonly already run unrelated hooks, and clobbering them would be a nasty
/// surprise from a HUD.
public enum HookInstaller {
    /// Marker used to find our own entries for idempotent reinstall/uninstall.
    public static let marker = "claude-island-notify"

    public struct Result: Sendable {
        public let backupPath: String?
        public let installedEvents: [String]
        public let preservedOtherHooks: Int
    }

    public enum InstallError: Error, CustomStringConvertible {
        case settingsNotObject
        case serializationFailed

        public var description: String {
            switch self {
            case .settingsNotObject: "~/.claude/settings.json is not a JSON object"
            case .serializationFailed: "could not serialize settings.json"
            }
        }
    }

    /// The hook block on its own, for pasting by hand.
    public static func hookBlockJSON(binaryPath: String) -> String {
        let block = hooksDictionary(binaryPath: binaryPath)
        let wrapped: [String: Any] = ["hooks": block]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func hooksDictionary(binaryPath: String) -> [String: Any] {
        var result: [String: Any] = [:]
        let command = quoteIfNeeded(binaryPath)
        for event in HookEvent.installable {
            result[event.name] = [
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "type": "command",
                            "command": command,
                            // The client self-limits to 50 ms; this is a backstop
                            // in case the process itself is slow to start.
                            "timeout": 5,
                        ] as [String: Any]
                    ],
                ] as [String: Any]
            ]
        }
        return result
    }

    private static func quoteIfNeeded(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    // MARK: - Merge

    @discardableResult
    public static func install(
        binaryPath: String,
        settingsURL: URL = IslandPaths.claudeSettings
    ) throws -> Result {
        var settings = try loadSettings(settingsURL)
        let backup = try backupIfExists(settingsURL)

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var preserved = 0

        for event in HookEvent.installable {
            var matchers = (hooks[event.name] as? [[String: Any]]) ?? []
            // Drop any prior entry of ours so reinstall is idempotent, keeping
            // everyone else's.
            matchers = matchers.compactMap { matcher in
                var m = matcher
                let inner = (m["hooks"] as? [[String: Any]]) ?? []
                let kept = inner.filter { !isOurs($0) }
                preserved += kept.count
                if kept.isEmpty && !inner.isEmpty { return nil }
                m["hooks"] = kept
                return m
            }
            matchers.append(
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "type": "command",
                            "command": quoteIfNeeded(binaryPath),
                            "timeout": 5,
                        ] as [String: Any]
                    ],
                ] as [String: Any])
            hooks[event.name] = matchers
        }

        settings["hooks"] = hooks
        try writeSettings(settings, to: settingsURL)

        return Result(
            backupPath: backup?.path,
            installedEvents: HookEvent.installable.map(\.name),
            preservedOtherHooks: preserved)
    }

    @discardableResult
    public static func uninstall(settingsURL: URL = IslandPaths.claudeSettings) throws -> Result {
        var settings = try loadSettings(settingsURL)
        let backup = try backupIfExists(settingsURL)
        guard var hooks = settings["hooks"] as? [String: Any] else {
            return Result(backupPath: backup?.path, installedEvents: [], preservedOtherHooks: 0)
        }

        var preserved = 0
        for (event, value) in hooks {
            guard var matchers = value as? [[String: Any]] else { continue }
            matchers = matchers.compactMap { matcher in
                var m = matcher
                let inner = (m["hooks"] as? [[String: Any]]) ?? []
                let kept = inner.filter { !isOurs($0) }
                preserved += kept.count
                if kept.isEmpty { return nil }
                m["hooks"] = kept
                return m
            }
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings, to: settingsURL)
        return Result(
            backupPath: backup?.path, installedEvents: [], preservedOtherHooks: preserved)
    }

    public static func isInstalled(settingsURL: URL = IslandPaths.claudeSettings) -> Bool {
        guard let settings = try? loadSettings(settingsURL),
            let hooks = settings["hooks"] as? [String: Any]
        else { return false }
        for value in hooks.values {
            guard let matchers = value as? [[String: Any]] else { continue }
            for matcher in matchers {
                let inner = (matcher["hooks"] as? [[String: Any]]) ?? []
                if inner.contains(where: isOurs) { return true }
            }
        }
        return false
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        ((hook["command"] as? String) ?? "").contains(marker)
    }

    private static func loadSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.settingsNotObject
        }
        return object
    }

    private static func backupIfExists(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("settings.json.island-backup-\(stamp)")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        else { throw InstallError.serializationFailed }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write-then-rename so a crash cannot leave a half-written settings.json.
        let tmp = url.appendingPathExtension("island-tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
