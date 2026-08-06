import Foundation

/// Runs a closure at a future instant.
///
/// Abstracted so `--replay` and the tests can drive timed transitions off a
/// virtual clock. Without this, `.prompting -> .thinking` and error decay would
/// land nondeterministically and golden traces would flake.
public protocol TransitionScheduler: Sendable {
    func schedule(at deadline: Date, _ op: @escaping @Sendable () async -> Void)
}

/// Production scheduler: sleeps the remaining interval on a detached task.
public struct RealScheduler: TransitionScheduler {
    public init() {}

    public func schedule(at deadline: Date, _ op: @escaping @Sendable () async -> Void) {
        let delay = max(0, deadline.timeIntervalSinceNow)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await op()
        }
    }
}

/// Virtual-clock scheduler. Nothing runs until `advance(to:)` is called, so a
/// replay produces the same trace every time.
///
/// A lock-guarded class rather than an actor on purpose: `schedule` must enqueue
/// *synchronously*. As an actor it could only hop the work onto a `Task`, and a
/// caller that scheduled then immediately advanced would race the enqueue and
/// silently drop the transition.
public final class VirtualScheduler: TransitionScheduler, @unchecked Sendable {
    private struct Entry {
        let deadline: Date
        let seq: Int
        let op: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var seq = 0

    public init() {}

    public func schedule(at deadline: Date, _ op: @escaping @Sendable () async -> Void) {
        lock.lock()
        seq += 1
        entries.append(Entry(deadline: deadline, seq: seq, op: op))
        lock.unlock()
    }

    /// Fire everything due at or before `now`, in deadline order.
    public func advance(to now: Date) async {
        while let next = takeNext(dueBy: now) {
            await next()
        }
    }

    /// Fire every remaining entry regardless of deadline. Used to drain at the
    /// end of a replay so trailing fades appear in the trace.
    public func drain() async {
        while let next = takeNext(dueBy: nil) {
            await next()
        }
    }

    /// Pops the earliest entry (optionally only if due), releasing the lock
    /// before the caller awaits — an op may schedule further work.
    private func takeNext(dueBy now: Date?) -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let candidates = now.map { limit in entries.filter { $0.deadline <= limit } } ?? entries
        guard
            let next = candidates.min(by: { ($0.deadline, $0.seq) < ($1.deadline, $1.seq) })
        else { return nil }
        entries.removeAll { $0.seq == next.seq }
        return next.op
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
