import Foundation

/// The line Claude Code's own classifier wrote for a background session.
public struct JobState: Sendable, Equatable {
    public var detail: String
    public var updatedAt: Date

    public init(detail: String, updatedAt: Date) {
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

/// Reads `~/.claude/jobs/<id>/state.json`, the store behind Claude Code's agents
/// view.
///
/// Only background sessions have one — a job directory is created for `--agent`
/// runs and nothing else — so this is a decoration for some sessions rather than
/// a source for all of them. `ActivityPhrase` covers the rest.
///
/// The file is private to Claude Code and carries no version marker, so every
/// field here is optional and a decode failure is simply no reading. The one
/// contract worth relying on is `sessionId`, which is the same UUID the hook
/// client already stamps on every envelope.
public final class JobStateReader: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    /// Which directory holds which session, so the steady state is one small
    /// file read rather than a scan of every job ever run. There were 63
    /// directories in this store on the machine the feature was written on, most
    /// of them days old.
    private var directoryBySession: [String: URL] = [:]
    private var lastScan: Date?

    /// How often the store may be walked looking for a directory we have not
    /// seen before.
    ///
    /// Rate-limited because the miss path is the *common* path, not the rare
    /// one: an ordinary terminal session has no job directory and never will, so
    /// an unthrottled rescan would walk every directory in the store on every
    /// transcript event, for every session that is not a background job. There
    /// were 63 of those directories on the machine this was written on.
    public static let rescanInterval: TimeInterval = 5

    /// One reader for the process, so the directory map is built once rather
    /// than per store.
    public static let shared = JobStateReader()

    public init(root: URL = IslandPaths.claudeJobs) {
        self.root = root
    }

    /// The classifier's current line for `id`, or nil when this session has no
    /// job directory, the file will not decode, or the line is empty.
    ///
    /// Rescans once on a miss: a job directory appears the moment a background
    /// session starts, which is necessarily after any scan that preceded it.
    public func state(forSessionID id: String, now: Date = Date()) -> JobState? {
        if let cached = cachedDirectory(for: id), let state = read(cached, expecting: id) {
            return state
        }
        guard beginScanIfDue(now: now) else { return nil }
        rescan()
        guard let dir = cachedDirectory(for: id) else { return nil }
        return read(dir, expecting: id)
    }

    /// Whether a scan is due, marking it as started if so.
    private func beginScanIfDue(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastScan, now.timeIntervalSince(last) < Self.rescanInterval { return false }
        lastScan = now
        return true
    }

    private func cachedDirectory(for id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return directoryBySession[id]
    }

    /// Rebuilds the session-to-directory map.
    ///
    /// Cheap enough to run on a miss rather than on a timer: the map only misses
    /// for a session whose directory did not exist last time we looked, which
    /// happens once per background session.
    private func rescan() {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
        var map: [String: URL] = [:]
        for dir in entries {
            let file = dir.appendingPathComponent("state.json")
            guard let record = decode(file), let session = record.sessionId, !session.isEmpty
            else { continue }
            map[session] = file
        }
        lock.lock()
        directoryBySession = map
        lock.unlock()
    }

    /// Reads one `state.json`, rejecting it if it has come to describe a
    /// different session.
    ///
    /// A job directory is reused when a session is resumed, so a cached path can
    /// legitimately start pointing at another session's line. Checking the id on
    /// every read is what stops one session's card showing another's work.
    private func read(_ file: URL, expecting id: String) -> JobState? {
        guard let record = decode(file), record.sessionId == id else { return nil }
        guard let detail = record.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty
        else { return nil }
        return JobState(detail: detail, updatedAt: record.updated ?? .distantPast)
    }

    private func decode(_ file: URL) -> Record? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private struct Record: Decodable {
        let sessionId: String?
        let detail: String?
        let updatedAt: String?

        /// `updatedAt` is ISO-8601 with fractional seconds. Parsed leniently —
        /// a reading that will not parse costs the line its freshness check,
        /// which is better than costing it the line.
        ///
        /// The formatters are built per call rather than shared: `ISO8601Date-`
        /// `Formatter` is not `Sendable`, and this runs once per transcript
        /// event on one session, not once per frame.
        var updated: Date? {
            guard let updatedAt else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: updatedAt) { return parsed }
            return ISO8601DateFormatter().date(from: updatedAt)
        }
    }
}
