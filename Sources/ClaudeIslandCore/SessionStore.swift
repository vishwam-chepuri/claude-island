import Foundation

/// What the HUD renders: the session that most deserves attention, plus the
/// rest for the count badge and the expanded card's list.
public struct HUDSnapshot: Sendable, Equatable {
    public var primary: Session?
    public var others: [Session]
    public var generatedAt: Date

    public init(primary: Session? = nil, others: [Session] = [], generatedAt: Date = Date()) {
        self.primary = primary
        self.others = others
        self.generatedAt = generatedAt
    }

    public var sessionCount: Int { (primary == nil ? 0 : 1) + others.count }

    /// True when something on screen needs a continuous animation. When false
    /// the HUD must schedule no redraws at all — this is the idle-CPU contract.
    ///
    /// Asking every session is equivalent to asking `primary` alone *today*,
    /// because `isActive` and `wantsAnimation` happen to cover the same cases
    /// and `priority` sorts active sessions first. That equivalence is a
    /// coincidence of two switch statements agreeing, not a property anyone
    /// declared — and if they ever diverge, the primary-only form silently
    /// freezes the elapsed labels of a session that is still running.
    public var wantsAnimation: Bool {
        if primary?.state.wantsAnimation == true { return true }
        return others.contains { $0.state.wantsAnimation }
    }

    public var isDormant: Bool { primary == nil }
}

/// Owns every tracked session. The single writer for session state.
public actor SessionStore {
    private var sessions: [String: Session] = [:]
    private let scheduler: TransitionScheduler
    private let now: @Sendable () -> Date
    private let log: IslandLog
    /// Answers, for a (model, cwd) pair, whether the session runs the
    /// million-token variant. Injected so the tier is decided in one place and
    /// the tests need no config file on disk.
    private let longContextResolver: @Sendable (String?, String?) -> Bool

    private var continuations: [UUID: AsyncStream<HUDSnapshot>.Continuation] = [:]
    private var sweepTask: Task<Void, Never>?
    /// Bumped on every mutation; timed transitions abort if their session moved
    /// on while they were asleep.
    private var revisions: [String: Int] = [:]
    /// The (model, cwd) pair the context tier was last resolved for, per session.
    private var resolvedTiers: [String: String] = [:]

    public init(
        scheduler: TransitionScheduler = RealScheduler(),
        log: IslandLog = .disabled,
        now: @escaping @Sendable () -> Date = { Date() },
        longContextResolver: @escaping @Sendable (String?, String?) -> Bool = {
            ClaudeConfig.usesLongContext(model: $0, cwd: $1)
        }
    ) {
        self.scheduler = scheduler
        self.log = log
        self.now = now
        self.longContextResolver = longContextResolver
    }

    // MARK: - Observation

    public func snapshots() -> AsyncStream<HUDSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    public func currentSnapshot() -> HUDSnapshot {
        let ranked = sessions.values.sorted(by: Self.priority)
        return HUDSnapshot(
            primary: ranked.first,
            others: Array(ranked.dropFirst()),
            generatedAt: now())
    }

    /// Ordering for which session the HUD shows.
    ///
    /// A pending permission outranks recency. Otherwise a permission prompt in
    /// one worktree vanishes the instant another worktree runs a Read — exactly
    /// when it most needs to be visible.
    public static func priority(_ a: Session, _ b: Session) -> Bool {
        if a.state.isAlert != b.state.isAlert { return a.state.isAlert }
        if a.state.isActive != b.state.isActive { return a.state.isActive }
        return a.lastEventAt > b.lastEventAt
    }

    private func publish() {
        let snap = currentSnapshot()
        for c in continuations.values { c.yield(snap) }
    }

    // MARK: - Ingest

    public func ingest(_ envelope: HookEnvelope) {
        // A status-line payload is a periodic state dump, not something that
        // happened. Through the reducer it would stamp `lastEventAt` on every
        // render — pinning every session at the top of `priority` and holding
        // the idle sweep off forever.
        if case .statusline = envelope.event {
            applyStatusline(envelope)
            return
        }

        let outcome = SessionReducer.apply(envelope, to: sessions[envelope.sessionID])
        var session = outcome.session
        // The cwd arrives here and the model from the transcript, in whichever
        // order; the tier needs both, so both paths ask.
        resolveContextTier(&session)
        sessions[session.id] = session

        let revision = (revisions[session.id] ?? 0) + 1
        revisions[session.id] = revision

        log.debug(
            "\(envelope.event.name) session=\(session.id.prefix(8)) -> \(session.state.traceName)")

        for transition in outcome.pending {
            schedule(transition, for: session.id, revision: revision, at: envelope.receivedAt)
        }

        startSweepIfNeeded()
        publish()
    }

    /// Merge transcript-derived facts. Kept separate from `ingest` because it
    /// must never alter the state machine — only decorate.
    public func applyTranscript(_ update: TranscriptUpdate) {
        guard var s = sessions[update.sessionID] else { return }
        if let model = update.model { s.model = model }
        resolveContextTier(&s)
        if let branch = update.gitBranch { s.gitBranch = branch }
        if let effort = update.effort { s.effort = effort }
        if let title = update.customTitle { s.customTitle = title }
        if let title = update.aiTitle { s.aiTitle = title }
        if !update.tasks.isEmpty { s.tasks = update.tasks }
        s.tokens = update.tokens
        sessions[update.sessionID] = s
        publish()
    }

    /// Record the exact context window a status-line render reported.
    ///
    /// Decoration only, and silent when nothing moved: the status line
    /// re-renders continuously, and publishing every time would wake the HUD
    /// several times a second to redraw an identical frame.
    private func applyStatusline(_ envelope: HookEnvelope) {
        guard let size = envelope.contextWindowSize, size > 0,
            var s = sessions[envelope.sessionID], s.contextLimit != size
        else { return }
        s.contextLimit = size
        sessions[envelope.sessionID] = s
        log.debug("statusline session=\(s.id.prefix(8)) context window \(size)")
        publish()
    }

    /// Decide the session's context tier, at most once per (model, cwd) pair.
    ///
    /// Both callers run on every event, and the resolver stats a file, so the
    /// pair it last answered for is remembered rather than asked again.
    private func resolveContextTier(_ s: inout Session) {
        guard let model = s.model, let cwd = s.cwd else { return }
        let key = "\(model)\u{0}\(cwd)"
        guard resolvedTiers[s.id] != key else { return }
        resolvedTiers[s.id] = key
        s.usesLongContext = longContextResolver(model, cwd)
    }

    // MARK: - Timed transitions

    private func schedule(
        _ transition: PendingTransition, for id: String, revision: Int, at eventTime: Date
    ) {
        let deadline: Date
        switch transition {
        case .promptingToThinking(let d), .errorToThinking(let d), .removeSession(let d):
            deadline = eventTime.addingTimeInterval(d)
        }
        scheduler.schedule(at: deadline) { [weak self] in
            await self?.fire(transition, id: id, revision: revision)
        }
    }

    private func fire(_ transition: PendingTransition, id: String, revision: Int) {
        // A newer event superseded this transition while it was pending.
        guard revisions[id] == revision, var s = sessions[id] else { return }

        switch transition {
        case .promptingToThinking:
            guard case .prompting = s.state else { return }
            s.state = .thinking
        case .errorToThinking:
            guard case .error = s.state else { return }
            s.state = .thinking
        case .removeSession:
            sessions[id] = nil
            revisions[id] = nil
            resolvedTiers[id] = nil
            stopSweepIfIdle()
            publish()
            return
        }

        sessions[id] = s
        publish()
    }

    // MARK: - Expiry

    /// The sweep exists only while sessions do. A permanently-armed timer would
    /// blow the idle CPU budget on its own.
    private func startSweepIfNeeded() {
        guard sweepTask == nil, !sessions.isEmpty else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Timings.expirySweepInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.expireStale()
            }
        }
    }

    private func stopSweepIfIdle() {
        guard sessions.isEmpty else { return }
        sweepTask?.cancel()
        sweepTask = nil
    }

    public func expireStale() {
        let cutoff = now()
        let stale = sessions.values.filter { $0.idleFor(now: cutoff) > Timings.sessionExpiry }
        guard !stale.isEmpty else { return }
        for s in stale {
            log.debug("expiring idle session \(s.id.prefix(8))")
            sessions[s.id] = nil
            revisions[s.id] = nil
            resolvedTiers[s.id] = nil
        }
        stopSweepIfIdle()
        publish()
    }

    // MARK: - Introspection (tests, replay)

    public func session(_ id: String) -> Session? { sessions[id] }
    public func allSessions() -> [Session] { sessions.values.sorted(by: Self.priority) }
    public func shutdown() {
        sweepTask?.cancel()
        sweepTask = nil
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}
