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
    public static func hookBlockJSON(binaryPath: String, trackSessionApp: Bool) -> String {
        let block = hooksDictionary(binaryPath: binaryPath, trackSessionApp: trackSessionApp)
        let wrapped: [String: Any] = ["hooks": block]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func hooksDictionary(binaryPath: String, trackSessionApp: Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        for event in HookEvent.installable {
            result[event.name] = [
                matcher(binaryPath: binaryPath, event: event, trackSessionApp: trackSessionApp)
            ]
        }
        return result
    }

    /// The one place an entry of ours is shaped, so the printable block and the
    /// merged install cannot drift apart on arguments or timeouts.
    private static func matcher(
        binaryPath: String, event: HookEvent, trackSessionApp: Bool
    ) -> [String: Any] {
        [
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": command(
                        binaryPath: binaryPath, event: event, trackSessionApp: trackSessionApp),
                    "timeout": event.hookTimeoutSeconds,
                ] as [String: Any]
            ],
        ]
    }

    /// Event arguments first, then arguments that apply to every event.
    ///
    /// That order is load-bearing rather than tidy: `isCurrent` compares whole
    /// command strings, so an order that varied between calls would make a
    /// block read as stale against the build that had just written it, and the
    /// Hooks pane would offer an update that changed nothing.
    private static func command(
        binaryPath: String, event: HookEvent, trackSessionApp: Bool
    ) -> String {
        // Passed in rather than read here: Core takes its inputs as parameters
        // so the suites can drive both states without a settings file on disk,
        // the same reason `rings` is handed the frontmost bundle id.
        let global = trackSessionApp ? [] : ["--no-ancestry"]
        return ([quoteIfNeeded(binaryPath)] + event.clientArguments + global)
            .joined(separator: " ")
    }

    private static func quoteIfNeeded(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    // MARK: - Merge

    @discardableResult
    public static func install(
        binaryPath: String,
        trackSessionApp: Bool,
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
                matcher(binaryPath: binaryPath, event: event, trackSessionApp: trackSessionApp))
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

    /// Whether the installed block matches what this build would write.
    ///
    /// `isInstalled` only answers "is there an entry of ours", which was enough
    /// when every event got an identical command. It no longer is: a block
    /// installed before `PermissionRequest` gained `--await-decision` looks
    /// installed and is, but silently cannot answer a prompt from the card. The
    /// symptom is an absence — no controls, no explanation — so the app has to be
    /// able to tell the difference and say so.
    public static func isCurrent(
        binaryPath: String, trackSessionApp: Bool,
        settingsURL: URL = IslandPaths.claudeSettings
    ) -> Bool {
        guard let settings = try? loadSettings(settingsURL),
            let hooks = settings["hooks"] as? [String: Any]
        else { return false }

        for event in HookEvent.installable {
            let expected = command(
                binaryPath: binaryPath, event: event, trackSessionApp: trackSessionApp)
            let entries = ((hooks[event.name] as? [[String: Any]]) ?? [])
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .filter(isOurs)
            guard
                entries.contains(where: {
                    ($0["command"] as? String) == expected
                        && ($0["timeout"] as? Int) == event.hookTimeoutSeconds
                })
            else { return false }
        }
        return true
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
