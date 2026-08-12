import Foundation

/// Feeds a recorded event log through the real pipeline with no UI.
///
/// Runs on a virtual clock so timed transitions (prompting flash, error decay,
/// session fade) fire deterministically and the trace is byte-stable — which is
/// what makes golden-file tests possible.
public struct ReplayDriver: Sendable {
    public struct TraceLine: Sendable, Equatable, CustomStringConvertible {
        public let elapsedMs: Int
        public let event: String
        public let sessionID: String
        public let state: String
        public let detail: String?

        public var description: String {
            let ms = String(elapsedMs).leftPadded(to: 6)
            let ev = event.rightPadded(to: 20)
            let sid = String(sessionID.prefix(8)).rightPadded(to: 8)
            let base = "\(ms)ms  \(ev) \(sid) -> \(state)"
            if let detail, !detail.isEmpty { return base + "  [\(detail)]" }
            return base
        }
    }

    public struct Output: Sendable {
        public let trace: [TraceLine]
        public let finalSessions: [Session]
        public let decodedCount: Int
        public let skippedCount: Int

        public var text: String { trace.map(\.description).joined(separator: "\n") }
    }

    public let baseDate: Date

    public init(baseDate: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.baseDate = baseDate
    }

    public func run(fileURL: URL) async throws -> Output {
        try await run(data: Data(contentsOf: fileURL))
    }

    public func run(data: Data) async throws -> Output {
        let (lines, _) = LineSplitter.completeLines(from: data)
        let scheduler = VirtualScheduler()
        let clock = ClockBox(now: baseDate)
        let store = SessionStore(scheduler: scheduler, log: .disabled, now: { clock.value })
        let collector = TraceCollector(base: baseDate)

        var virtualNow = baseDate
        var trace: [TraceLine] = []
        var decoded = 0
        var skipped = 0

        for line in lines where !line.isEmpty {
            guard let parsed = (try? HookEnvelope.decodeReplayLine(line, receivedAt: virtualNow))
                    ?? nil
            else {
                skipped += 1
                continue
            }

            virtualNow = virtualNow.addingTimeInterval(Double(parsed.delayMs) / 1000.0)
            clock.value = virtualNow

            // Fire anything that came due during the gap before this event, so
            // timer-driven transitions land in the trace in the right order.
            await scheduler.advance(to: virtualNow)
            trace += await collector.collect(from: store, at: virtualNow, event: "(timer)")

            await store.ingest(parsed.envelope.restamped(virtualNow))
            decoded += 1
            trace += await collector.collect(
                from: store, at: virtualNow, event: parsed.envelope.event.name)
        }

        // Drain trailing fades so the trace ends in a settled state.
        await scheduler.drain()
        clock.value = virtualNow.addingTimeInterval(Timings.sessionEndFade)
        trace += await collector.collect(from: store, at: clock.value, event: "(drain)")

        let final = await store.allSessions()
        await store.shutdown()
        return Output(
            trace: trace, finalSessions: final, decodedCount: decoded, skippedCount: skipped)
    }
}

extension HookEnvelope {
    /// Same payload, different arrival time. Replay assigns virtual timestamps.
    ///
    /// Every other field is forwarded unchanged — this was, for a while, not
    /// true of `ancestorPIDs`: the memberwise call here predates that field by
    /// a lot of history and was never updated when it was added, so a replayed
    /// envelope silently lost its ancestry on the very first virtual tick. No
    /// existing fixture carried `_island_pids`, so nothing caught it until one
    /// did.
    func restamped(_ date: Date) -> HookEnvelope {
        HookEnvelope(
            sessionID: sessionID, event: event, cwd: cwd, transcriptPath: transcriptPath,
            toolName: toolName, toolInput: toolInput, message: message, trigger: trigger,
            source: source, reason: reason, contextWindowSize: contextWindowSize,
            linesAdded: linesAdded, linesRemoved: linesRemoved, rateLimit: rateLimit,
            receivedAt: date, ancestorPIDs: ancestorPIDs, decisionToken: decisionToken,
            siblingPromptCount: siblingPromptCount)
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
    fileprivate func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

/// Mutable clock shared with the store. A class so the store's `@Sendable`
/// closure observes updates.
public final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    public init(now: Date) { storage = now }
    public var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Emits a trace line whenever an observed session's rendered state changes.
private actor TraceCollector {
    private var lastStates: [String: String] = [:]
    private let base: Date

    init(base: Date) { self.base = base }

    func collect(from store: SessionStore, at now: Date, event: String) async
        -> [ReplayDriver.TraceLine]
    {
        let sessions = await store.allSessions()
        var lines: [ReplayDriver.TraceLine] = []
        var seen = Set<String>()

        for s in sessions {
            seen.insert(s.id)
            let rendered = s.state.traceName
            guard lastStates[s.id] != rendered else { continue }
            lastStates[s.id] = rendered
            lines.append(
                ReplayDriver.TraceLine(
                    elapsedMs: Int(now.timeIntervalSince(base) * 1000),
                    event: event, sessionID: s.id, state: rendered, detail: detail(for: s)))
        }

        for id in lastStates.keys where !seen.contains(id) {
            lastStates[id] = nil
            lines.append(
                ReplayDriver.TraceLine(
                    elapsedMs: Int(now.timeIntervalSince(base) * 1000),
                    event: event, sessionID: id, state: "removed", detail: nil))
        }
        return lines.sorted { $0.sessionID < $1.sessionID }
    }

    private func detail(for s: Session) -> String? {
        switch s.state {
        case .running(let t): t.target
        case .awaitingPermission(let a): a.target
        default: nil
        }
    }
}
