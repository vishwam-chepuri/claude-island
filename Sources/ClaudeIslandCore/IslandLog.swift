import Foundation

public enum IslandPaths {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".claude-island", isDirectory: true)
    }
    public static var socket: URL { root.appendingPathComponent("island.sock") }
    public static var logFile: URL { root.appendingPathComponent("log") }
    public static var rotatedLogFile: URL { root.appendingPathComponent("log.1") }
    /// Every user-visible setting. See `IslandSettings`.
    ///
    /// The `dnd`, `debug`, `tint` and `force-mode` sentinel files this replaced
    /// are named only in `IslandSettings.bootstrap()`, which consumes them.
    /// Nothing else may read them — a second reader is how two files start
    /// disagreeing about one setting.
    public static var settingsFile: URL { root.appendingPathComponent("settings.json") }

    public static var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".claude", isDirectory: true)
    }
    public static var claudeProjects: URL {
        claudeHome.appendingPathComponent("projects", isDirectory: true)
    }
    public static var claudeSettings: URL {
        claudeHome.appendingPathComponent("settings.json")
    }

    @discardableResult
    public static func ensureRoot() -> Bool {
        (try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])) != nil
    }
}

/// Append-only log with a hard size cap and a single rotation. Off unless
/// explicitly enabled, because a HUD has no business writing to disk on every
/// tool call by default.
public final class IslandLog: @unchecked Sendable {
    public static let maxBytes = 1 << 20  // 1 MiB, then rotate once.

    public static let disabled = IslandLog(enabled: false)

    /// The one log the app writes through.
    ///
    /// Shared rather than one per owner because each instance opens its own
    /// `FileHandle` and counts its own bytes: two of them appending to the same
    /// file rotate independently, and the one that did not rotate goes on
    /// writing into `log.1` — the file the next rotation deletes. Sharing is
    /// also the only way the settings pane's logging switch reaches every
    /// writer, since `setEnabled` is per instance.
    ///
    /// Lazy, like every `static let`, so nothing is read from disk until
    /// something logs — which matters because `fromEnvironment` reads settings
    /// and must not run before `IslandSettings.bootstrap()`.
    public static let shared = fromEnvironment()

    private let queue = DispatchQueue(label: "island.log", qos: .utility)
    private var enabled: Bool
    private var handle: FileHandle?
    private var written: Int = 0

    public init(enabled: Bool) {
        self.enabled = enabled
        if enabled { queue.async { self.open() } }
    }

    /// Enabled when settings say so, or when the environment overrides them.
    ///
    /// The environment variable stays a pure runtime override — it turns logging
    /// on for one run without writing anything, which is what makes it usable
    /// from a test harness or a one-off `--replay`.
    ///
    /// Callers that also read settings must run `IslandSettings.bootstrap()`
    /// first, or a migrating install reads `logging: false` here and then finds
    /// the sentinel a moment later.
    public static func fromEnvironment() -> IslandLog {
        let on =
            IslandSettings.load().logging
            || ProcessInfo.processInfo.environment["CLAUDE_ISLAND_DEBUG"] == "1"
        return IslandLog(enabled: on)
    }

    public var isEnabled: Bool { queue.sync { enabled } }

    public func setEnabled(_ on: Bool) {
        queue.async {
            guard on != self.enabled else { return }
            self.enabled = on
            if on {
                self.open()
            } else {
                try? self.handle?.close()
                self.handle = nil
            }
        }
    }

    public func debug(_ message: @autoclosure @escaping () -> String) {
        guard enabled else { return }
        let line = message()
        queue.async { self.write(line) }
    }

    // MARK: - Private

    private func open() {
        IslandPaths.ensureRoot()
        let fm = FileManager.default
        let path = IslandPaths.logFile.path
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: IslandPaths.logFile)
        if let h = handle {
            written = Int((try? h.seekToEnd()) ?? 0)
        }
    }

    private func write(_ line: String) {
        guard let h = handle else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        try? h.write(contentsOf: data)
        written += data.count
        if written >= Self.maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: IslandPaths.rotatedLogFile)
        try? fm.moveItem(at: IslandPaths.logFile, to: IslandPaths.rotatedLogFile)
        written = 0
        open()
    }
}
