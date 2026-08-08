import CoreServices
import Foundation

/// Watches session transcripts for token counts and the current model.
///
/// FSEvents on `~/.claude/projects`, not polling — a poll loop would violate the
/// idle CPU budget on its own. Each session keeps a byte offset; on a change we
/// seek to it and read only what was appended.
public final class TranscriptWatcher: @unchecked Sendable {
    private struct Tracked {
        let sessionID: String
        var path: String
        var offset: UInt64 = 0
        var accumulator = TranscriptAccumulator()
    }

    private let queue = DispatchQueue(label: "island.transcript", qos: .utility)
    private let log: IslandLog
    private var tracked: [String: Tracked] = [:]  // keyed by resolved path
    private var stream: FSEventStreamRef?
    private var watchedRoots: Set<String> = []
    private let onUpdate: @Sendable (TranscriptUpdate) -> Void

    public init(log: IslandLog = .disabled, onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void)
    {
        self.log = log
        self.onUpdate = onUpdate
    }

    /// Begin tracking a session's transcript. Idempotent.
    public func track(sessionID: String, transcriptPath: String) {
        queue.async {
            let path = (transcriptPath as NSString).standardizingPath
            if let existing = self.tracked[path], existing.sessionID == sessionID { return }
            self.tracked[path] = Tracked(sessionID: sessionID, path: path)
            self.log.debug("tracking transcript \(path)")
            self.ensureStream()
            self.drain(path: path)  // Catch up on whatever already exists.
        }
    }

    public func untrack(sessionID: String) {
        queue.async {
            self.tracked = self.tracked.filter { $0.value.sessionID != sessionID }
            if self.tracked.isEmpty { self.teardownStream() }
        }
    }

    public func stop() {
        queue.async {
            self.tracked.removeAll()
            self.teardownStream()
        }
    }

    // MARK: - FSEvents

    /// Watches the parent directory of every tracked transcript rather than a
    /// fixed root. `transcript_path` is whatever Claude Code reports, and a
    /// custom CLAUDE_CONFIG_DIR puts it outside ~/.claude/projects entirely.
    private func ensureStream() {
        var roots = Set(tracked.keys.map { ($0 as NSString).deletingLastPathComponent })
        roots.insert(IslandPaths.claudeProjects.path)
        guard roots != watchedRoots else { return }
        teardownStream()
        let rootList = roots.sorted()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changed: [String] = []
            for i in 0..<count { changed.append(String(cString: cPaths[i])) }
            watcher.handleEvents(changed)
        }

        guard
            let s = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context,
                rootList as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,  // Coalesce; a transcript is appended to many times a second.
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else {
            log.debug("FSEventStreamCreate failed for \(rootList)")
            return
        }

        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            log.debug("FSEventStreamStart failed for \(rootList)")
            return
        }
        stream = s
        watchedRoots = roots
    }

    private func teardownStream() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        watchedRoots = []
    }

    /// Called on `queue` by FSEvents.
    private func handleEvents(_ paths: [String]) {
        // File-level events give exact paths, but a directory-level event can
        // arrive instead; fall back to draining everything we track.
        let matched = paths.filter { tracked[$0] != nil }
        if matched.isEmpty {
            for path in tracked.keys { drain(path: path) }
        } else {
            for path in matched { drain(path: path) }
        }
    }

    // MARK: - Incremental read

    private func drain(path: String) {
        guard var entry = tracked[path] else { return }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return }
        if size < entry.offset {
            // Truncated or replaced (a /clear rewrites the file). Start over.
            entry.offset = 0
            entry.accumulator = TranscriptAccumulator()
        }
        guard size > entry.offset else { return }

        do {
            try handle.seek(toOffset: entry.offset)
        } catch {
            return
        }
        guard let data = try? handle.read(upToCount: Int(size - entry.offset)), !data.isEmpty
        else { return }

        let (lines, leftover) = LineSplitter.completeLines(from: data)
        for line in lines { entry.accumulator.consume(line: line) }
        // Rewind past a partial trailing line so it is re-read once complete.
        entry.offset = size - UInt64(leftover)
        tracked[path] = entry

        guard !lines.isEmpty else { return }
        onUpdate(
            TranscriptUpdate(
                sessionID: entry.sessionID,
                model: entry.accumulator.model,
                tokens: entry.accumulator.tokens,
                gitBranch: entry.accumulator.gitBranch,
                effort: entry.accumulator.effort,
                tasks: entry.accumulator.tasks,
                customTitle: entry.accumulator.customTitle,
                aiTitle: entry.accumulator.aiTitle))
    }
}
