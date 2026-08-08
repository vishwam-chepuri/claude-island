import Foundation

/// Threads the island into an existing status-line script.
///
/// The status-line payload is the only place Claude Code publishes the exact
/// context window, and a session may have only one status-line command — so the
/// island cannot install its own without taking over territory the user wrote.
/// Instead one line is added to the script already configured, forwarding the
/// payload to the same socket the hooks use.
///
/// Everything here is conservative by construction: it edits only a script that
/// settings.json already points at, only where it can see stdin being captured,
/// always after a backup, and it declines rather than guesses.
public enum StatuslineInstaller {
    /// Marks our line so reinstall is idempotent and uninstall is exact.
    public static let marker = "# claude-island: forward status-line payload"

    public enum Outcome: Sendable, Equatable {
        case installed(script: String, backupPath: String?)
        case alreadyInstalled(script: String)
        case removed(script: String)
        case notPresent
        /// Everything we declined to touch, with the reason and the line to add.
        case skipped(reason: SkipReason)

        public var didChange: Bool {
            switch self {
            case .installed, .removed: true
            case .alreadyInstalled, .notPresent, .skipped: false
            }
        }
    }

    public enum SkipReason: Sendable, Equatable {
        case noStatuslineConfigured
        case notACommandStatusline
        case scriptNotFound(String)
        case noStdinCapture(String)

        public var description: String {
            switch self {
            case .noStatuslineConfigured:
                "no statusLine configured in settings.json"
            case .notACommandStatusline:
                "statusLine is not a command this can edit"
            case .scriptNotFound(let p):
                "status-line script not found at \(p)"
            case .noStdinCapture(let p):
                "could not find where \(p) reads stdin"
            }
        }
    }

    /// The line to add, for pasting by hand when we decline to edit.
    public static func forwardLine(binaryPath: String, variable: String = "input") -> String {
        "printf '%s' \"$\(variable)\" | \(quoteIfNeeded(binaryPath)) &  \(marker)"
    }

    // MARK: - Install

    public static func install(
        binaryPath: String, settingsURL: URL = IslandPaths.claudeSettings
    ) throws -> Outcome {
        guard let script = try scriptURL(settingsURL: settingsURL) else {
            return .skipped(reason: .noStatuslineConfigured)
        }
        return try install(binaryPath: binaryPath, scriptURL: script)
    }

    public static func install(binaryPath: String, scriptURL: URL) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return .skipped(reason: .scriptNotFound(scriptURL.path))
        }
        let text = try String(contentsOf: scriptURL, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")

        if lines.contains(where: { $0.contains(marker) }) {
            return .alreadyInstalled(script: scriptURL.path)
        }

        // The payload is on stdin and can be read exactly once, so our line has
        // to go after the script's own capture and reuse its variable.
        guard let capture = findStdinCapture(lines) else {
            return .skipped(reason: .noStdinCapture(scriptURL.path))
        }

        let backup = try backupIfExists(scriptURL)
        lines.insert(
            forwardLine(binaryPath: binaryPath, variable: capture.variable),
            at: capture.index + 1)
        try write(lines.joined(separator: "\n"), to: scriptURL)
        return .installed(script: scriptURL.path, backupPath: backup?.path)
    }

    // MARK: - Uninstall

    public static func uninstall(settingsURL: URL = IslandPaths.claudeSettings) throws -> Outcome {
        guard let script = try scriptURL(settingsURL: settingsURL) else { return .notPresent }
        return try uninstall(scriptURL: script)
    }

    public static func uninstall(scriptURL: URL) throws -> Outcome {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return .notPresent }
        let text = try String(contentsOf: scriptURL, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { !$0.contains(marker) }
        guard kept.count != lines.count else { return .notPresent }

        _ = try backupIfExists(scriptURL)
        try write(kept.joined(separator: "\n"), to: scriptURL)
        return .removed(script: scriptURL.path)
    }

    public static func isInstalled(settingsURL: URL = IslandPaths.claudeSettings) -> Bool {
        guard let script = try? scriptURL(settingsURL: settingsURL),
            let text = try? String(contentsOf: script, encoding: .utf8)
        else { return false }
        return text.contains(marker)
    }

    // MARK: - Finding the script

    /// The script `statusLine.command` runs, when it is a command that runs one.
    ///
    /// An inline command (`jq -r '…'`) has no file to edit, so it is declined
    /// rather than rewritten into something the user did not author.
    public static func scriptURL(settingsURL: URL) throws -> URL? {
        guard let data = try? Data(contentsOf: settingsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let statusLine = root["statusLine"] as? [String: Any],
            (statusLine["type"] as? String) == "command",
            let command = statusLine["command"] as? String
        else { return nil }

        for token in tokenize(command) {
            let expanded = expandTilde(token)
            guard expanded.hasPrefix("/") || expanded.hasPrefix(".") else { continue }
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    /// Splits on whitespace, honouring the single and double quotes a path with
    /// spaces would have been written with.
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in command {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSString(string: path).expandingTildeInPath
    }

    /// Finds `name=$(cat)` / `name=`cat`` / `read -r name`, and the variable it
    /// binds. Without one there is no captured payload to forward.
    static func findStdinCapture(_ lines: [String]) -> (index: Int, variable: String)? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }

            if let eq = trimmed.firstIndex(of: "=") {
                let name = String(trimmed[trimmed.startIndex..<eq])
                let rhs = String(trimmed[trimmed.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                let readsStdin =
                    rhs.hasPrefix("$(cat)") || rhs.hasPrefix("`cat`")
                    || rhs.hasPrefix("$(</dev/stdin)") || rhs.hasPrefix("$(cat -)")
                if readsStdin, isShellName(name) { return (i, name) }
            }

            if trimmed.hasPrefix("read ") {
                if let name = trimmed.split(separator: " ").last.map(String.init),
                    isShellName(name)
                {
                    return (i, name)
                }
            }
        }
        return nil
    }

    private static func isShellName(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && !(s.first?.isNumber ?? true)
    }

    // MARK: - Writing

    private static func quoteIfNeeded(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    private static func backupIfExists(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).island-backup-\(stamp)")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    /// Write-then-rename, preserving the executable bit the shell needs.
    private static func write(_ text: String, to url: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let tmp = url.appendingPathExtension("island-tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        if let posix = attrs?[.posixPermissions] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: posix], ofItemAtPath: tmp.path)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
