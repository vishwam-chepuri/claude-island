import Foundation

/// What the HUD renders: the session that most deserves attention, plus the
/// rest for the count badge and the expanded card's list.
public struct HUDSnapshot: Sendable, Equatable {
    public var primary: Session?
    public var others: [Session]
    /// The account's 5-hour usage window. Outside `primary`/`others` because it
    /// belongs to none of them and to all of them at once.
    public var rateLimit: RateLimitWindow?
    public var generatedAt: Date

    public init(
        primary: Session? = nil, others: [Session] = [], rateLimit: RateLimitWindow? = nil,
        generatedAt: Date = Date()
    ) {
        self.primary = primary
        self.others = others
        self.rateLimit = rateLimit
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
    /// Whether a pid still exists. Injected so the sweep can be driven from a
    /// test without spawning and killing real processes.
    private let isProcessAlive: @Sendable (Int32) -> Bool
    /// The line Claude Code's own classifier wrote for a background session.
    /// Injected so the tests need no job store on disk.
    private let jobState: @Sendable (String) -> JobState?

    private var continuations: [UUID: AsyncStream<HUDSnapshot>.Continuation] = [:]
    private var sweepTask: Task<Void, Never>?
    /// Bumped on every mutation; timed transitions abort if their session moved
    /// on while they were asleep.
    private var revisions: [String: Int] = [:]
    /// The (model, cwd) pair the context tier was last resolved for, per session.
    private var resolvedTiers: [String: String] = [:]
    /// Ids of sessions that ended, and when. Guards against a straggling hook
    /// reviving one: the reducer mints a session for any id it does not know, so
    /// without this a late nudge reappears as a blank row for another 30
    /// minutes. Only `SessionStart` may clear an entry — see `ingest`.
    private var tombstones: [String: Date] = [:]
    /// Account-wide, so it lives beside the session table rather than in it —
    /// and outlives any one session, which is the point of a shared budget.
    private var rateLimit: RateLimitWindow?

    public init(
        scheduler: TransitionScheduler = RealScheduler(),
        log: IslandLog = .disabled,
        now: @escaping @Sendable () -> Date = { Date() },
        longContextResolver: @escaping @Sendable (String?, String?) -> Bool = {
            ClaudeConfig.usesLongContext(model: $0, cwd: $1)
        },
        // EPERM means the process exists and simply is not ours to signal.
        // Reading that as dead would sweep a session running as another user.
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = { pid in
            kill(pid, 0) == 0 || errno == EPERM
        },
        jobState: @escaping @Sendable (String) -> JobState? = {
            JobStateReader.shared.state(forSessionID: $0)
        }
    ) {
        self.scheduler = scheduler
        self.log = log
        self.now = now
        self.longContextResolver = longContextResolver
        self.isProcessAlive = isProcessAlive
        self.jobState = jobState
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
            rateLimit: rateLimit,
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

        // A hook for a session that already ended has nothing left to describe,
        // and the reducer would mint a fresh session rather than drop it — a row
        // with no cwd, model or title, holding the HUD for another 30 minutes.
        // SessionStart is the one event allowed to raise the dead, because a
        // resumed or cleared session reuses its id and does announce itself.
        if sessions[envelope.sessionID] == nil,
            hasEnded(envelope.sessionID, at: envelope.receivedAt)
        {
            guard case .sessionStart = envelope.event else {
                log.debug(
                    "ignoring \(envelope.event.name) for ended session "
                        + "\(envelope.sessionID.prefix(8))")
                return
            }
            tombstones[envelope.sessionID] = nil
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

    /// Marks a permission prompt as no longer answerable from the HUD.
    ///
    /// Called when the hook client behind it disappears — it timed out, crashed
    /// or was killed. Not the terminal-answered path: that leaves the hook
    /// running, and is covered instead by the session's next event replacing this
    /// state. See `PendingDecisions.onWithdraw`. The prompt itself is left here:
    /// the state machine only leaves `awaitingPermission` on the next real event,
    /// and inventing one here would race whatever Claude Code does next.
    public func withdrawDecision(_ token: UInt64) {
        for (id, session) in sessions {
            guard case .awaitingPermission(var ask) = session.state,
                ask.decisionToken == token
            else { continue }
            ask.decisionToken = nil
            var updated = session
            updated.state = .awaitingPermission(ask)
            sessions[id] = updated
            publish()
            return
        }
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
        if let line = update.activity {
            s.activity = SessionActivity(text: line, source: .transcript, at: now())
        }
        applyJobState(&s)
        s.tokens = update.tokens
        sessions[update.sessionID] = s
        publish()
    }

    /// Let Claude Code's own classifier speak for a session that has one, while
    /// its reading is still current.
    ///
    /// Its prose is the better line — a model wrote it, and it is the exact
    /// string the agents view shows — but it is also the slower one: the store
    /// is rewritten on a 15-second debounce, and the model-written tier inside
    /// it refreshes at most once a minute, backing off to four. So a reading
    /// that has stopped keeping up gives way to the transcript line, which is
    /// never more than one file-system event behind.
    ///
    /// Read here, on the back of a transcript update, rather than from a timer
    /// of its own: a session whose classifier is moving is a session writing
    /// transcript lines, so this samples often enough while costing nothing on
    /// an idle machine.
    private func applyJobState(_ s: inout Session) {
        guard let job = jobState(s.id) else { return }
        guard now().timeIntervalSince(job.updatedAt) <= Self.jobStateFreshFor else { return }
        s.activity = SessionActivity(text: job.detail, source: .jobStore, at: job.updatedAt)
    }

    /// How stale the background store's line may be and still outrank the line
    /// derived here. Generous against its own cadence deliberately: that tier
    /// can sit four minutes between refreshes by design, and calling that stale
    /// would throw away the better line for most of a long turn.
    static let jobStateFreshFor: TimeInterval = 300

    /// Record the facts only a status-line render publishes: the exact context
    /// window, the lines this session has rewritten, and the account's 5-hour
    /// usage window.
    ///
    /// Decoration only, and silent when nothing moved: the status line
    /// re-renders continuously, and publishing every time would wake the HUD
    /// several times a second to redraw an identical frame.
    private func applyStatusline(_ envelope: HookEnvelope) {
        var changed = false

        // Recorded even for a session we do not track, because the window is
        // the account's: the reading is still the right one to show the moment
        // some session does appear.
        if let window = envelope.rateLimit, rateLimit != window {
            rateLimit = window
            changed = true
        }

        if var s = sessions[envelope.sessionID] {
            if let size = envelope.contextWindowSize, size > 0, s.contextLimit != size {
                s.contextLimit = size
                log.debug("statusline session=\(s.id.prefix(8)) context window \(size)")
                changed = true
            }
            if let added = envelope.linesAdded, s.linesAdded != added {
                s.linesAdded = added
                changed = true
            }
            if let removed = envelope.linesRemoved, s.linesRemoved != removed {
                s.linesRemoved = removed
                changed = true
            }
            sessions[s.id] = s
        }

        // Nothing is on screen to redraw when there are no sessions, and the
        // stored window is carried into the next real publish regardless.
        guard changed, !sessions.isEmpty else { return }
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
        guard var s = sessions[id] else { return }

        switch transition {
        // The two decay transitions are cosmetic and belong to the event that
        // scheduled them, so a newer event supersedes them.
        case .promptingToThinking:
            guard revisions[id] == revision, case .prompting = s.state else { return }
            s.state = .thinking

        case .errorToThinking:
            guard revisions[id] == revision, case .error = s.state else { return }
            s.state = .thinking

        // Removal is not cosmetic and deliberately ignores the revision. A
        // background subagent's SubagentStop can land minutes after its parent's
        // Stop; inside this fade it used to bump the revision, cancel the only
        // removal anyone had scheduled, and strand the row until the 30-minute
        // sweep. What actually decides it is whether the session is still ended,
        // and SessionStart clears `endedAt` — so a session resumed or cleared
        // under the same id still keeps its place.
        case .removeSession:
            guard s.endedAt != nil else { return }
            forget(id)
            tombstones[id] = now()
            stopSweepIfIdle()
            publish()
            return
        }

        sessions[id] = s
        publish()
    }

    /// Drop every trace of a session. Deliberately does not tombstone: only a
    /// real `SessionEnd` earns that, because an idle-swept session must stay
    /// re-adoptable.
    private func forget(_ id: String) {
        sessions[id] = nil
        revisions[id] = nil
        resolvedTiers[id] = nil
    }

    /// Whether this id belonged to a session that ended recently enough for a
    /// straggling hook to still be in flight. Expired entries are dropped as
    /// they are met, so a lookup is also the only cleanup this table needs.
    private func hasEnded(_ id: String, at when: Date) -> Bool {
        guard let ended = tombstones[id] else { return false }
        guard when.timeIntervalSince(ended) < Timings.endedSessionMemory else {
            tombstones[id] = nil
            return false
        }
        return true
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
        tombstones = tombstones.filter {
            cutoff.timeIntervalSince($0.value) < Timings.endedSessionMemory
        }

        let doomed = sessions.values.compactMap { s in
            staleReason(s, at: cutoff).map { (s.id, $0) }
        }
        guard !doomed.isEmpty else { return }
        for (id, reason) in doomed {
            log.debug("dropping session \(id.prefix(8)): \(reason)")
            forget(id)
        }
        stopSweepIfIdle()
        publish()
    }

    /// Why the sweep should drop this session, or nil to keep it.
    private func staleReason(_ s: Session, at now: Date) -> String? {
        if s.idleFor(now: now) > Timings.sessionExpiry { return "idle" }
        if ownerHasExited(s) { return "owner exited" }
        return nil
    }

    /// Whether the Claude process that owned this session is gone.
    ///
    /// Closing a terminal tab, killing the process or sleeping the machine ends a
    /// session without any `SessionEnd` reaching us, and waiting out the
    /// 30-minute idle expiry means half an hour of showing work that finished.
    /// The pid answers directly.
    ///
    /// Element zero is the session's own process: `ownerPIDs` is the hook
    /// client's ancestry, nearest first, and Claude Code spawns that client
    /// itself. Measured rather than assumed — a SessionStart hook on this
    /// machine reports its parent as `claude`, with the shell and terminal above
    /// it.
    ///
    /// An empty ancestry means nobody told us, which is not the same as dead:
    /// replayed traces and synthetic events both arrive that way and must never
    /// be swept. A recycled pid can only make a dead owner look alive, which
    /// costs one more sweep and never hides a live session.
    private func ownerHasExited(_ s: Session) -> Bool {
        guard let owner = s.ownerPIDs.first else { return false }
        return !isProcessAlive(owner)
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
