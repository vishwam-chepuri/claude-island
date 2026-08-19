import Darwin
import Foundation

/// Which sessions Claude Code says are running right now.
///
/// `isReadable` is the difference between "nothing is running" and "nobody
/// answered", and the two must never be confused: a build of Claude Code that
/// keeps no such registry would otherwise look exactly like a machine where every
/// session had just died.
public struct LiveSessions: Sendable, Equatable {
    /// Session ids from registry entries whose process is still alive.
    public let ids: Set<String>
    /// Whether the registry directory could be listed at all.
    public let isReadable: Bool

    public init(ids: Set<String>, isReadable: Bool) {
        self.ids = ids
        self.isReadable = isReadable
    }

    /// No answer available. Not the same value as an empty registry, which is an
    /// answer — see `isReadable`.
    public static let unavailable = LiveSessions(ids: [], isReadable: false)

    public func isRunning(_ id: String) -> Bool { ids.contains(id) }
}

/// Claude Code's own record of its running sessions: one small JSON file per live
/// process in `~/.claude/sessions`, named for that process's pid and carrying the
/// session id, its cwd and a status.
///
/// Read because the HUD's other liveness signal is not available to most
/// installs. A session that dies without a `SessionEnd` — a closed tab, a `kill`,
/// a machine that slept — leaves nothing behind to notice it went, and the pid
/// check that covers that case needs the process ancestry the hook client only
/// stamps while "Find the app each session is running in" is on, which it is not
/// by default. This directory needs no ancestry and no cooperation: it is Claude
/// Code writing down what it is doing.
///
/// Measured against claude 2.1.235, which is what the two rules below rest on:
/// the file appears within a second of the session starting, and is deleted
/// during shutdown *before* the process exits. So presence means running, and
/// absence means gone — with a window of about a second at each edge where the
/// registry and the truth disagree, which is why callers wait out
/// `Timings.liveRegistryGrace` rather than acting on absence the instant they see
/// it. A `kill -9` is the one exit that leaves the file behind, having had no
/// chance to clean up, and that is what the pid check is for.
public enum LiveSessionRegistry {
    /// The fields taken from one entry. Everything else Claude Code writes there
    /// — cwd, status, version, job id — is deliberately ignored: this answers one
    /// question, and every field read is a field that can change shape.
    private struct Record: Decodable {
        let pid: Int32?
        let sessionId: String?
    }

    /// Reads the registry.
    ///
    /// Uncached, unlike `ClaudeConfig` and `JobStateReader`, because this runs
    /// once a minute at most and once per refresh — over a handful of files a few
    /// hundred bytes each. A cache would be one more thing to be stale at the
    /// exact moment it decides whether a session disappears.
    public static func read(
        from directory: URL = IslandPaths.claudeSessions,
        isProcessAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) -> LiveSessions {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return .unavailable }

        var ids = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(Record.self, from: data),
                let id = record.sessionId, !id.isEmpty,
                let pid = record.pid
            else { continue }
            // A recycled pid can only make a dead session look alive, which
            // costs it this rule and leaves it to the 30-minute idle expiry.
            // Never the other way round, which is the direction that would
            // matter.
            guard isProcessAlive(pid) else { continue }
            ids.insert(id)
        }
        return LiveSessions(ids: ids, isReadable: true)
    }
}
