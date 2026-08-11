import Darwin
import Foundation

/// Unix domain socket listener. One connection per hook invocation.
///
/// Accept and per-connection reads run on a GCD queue rather than the actor, so
/// a slow or wedged client can never delay the store or the UI. The socket file
/// is unlinked and recreated on launch (a stale one from a crash would make
/// bind fail) and chmod 0600.
public final class SocketServer: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let p): "socket path too long for sockaddr_un: \(p)"
            case .socketFailed(let e): "socket() failed: \(String(cString: strerror(e)))"
            case .bindFailed(let e): "bind() failed: \(String(cString: strerror(e)))"
            case .listenFailed(let e): "listen() failed: \(String(cString: strerror(e)))"
            }
        }
    }

    /// Where it listens. Public so the settings window's health strip can report
    /// the path this server actually took rather than re-deriving the default —
    /// two answers to "where is the socket" is how a diagnostic starts lying.
    public let path: String
    private let log: IslandLog
    private let queue = DispatchQueue(label: "island.socket", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(
        label: "island.socket.conn", qos: .userInitiated, attributes: .concurrent)
    /// Caps connections handled at once. Each handler does a blocking read with
    /// a timeout, so an unbounded burst — several worktrees firing hooks in the
    /// same instant — would spawn a thread per connection and starve the pool.
    /// Payloads are tiny and short-lived; a small window is ample.
    private let connectionSlots = DispatchSemaphore(value: 8)

    private var acceptSource: DispatchSourceRead?
    private let pending: PendingDecisions

    /// `listenFD` and `continuation` are written by whoever calls `start()` and
    /// `stop()`, and read from the accept queue and from every connection worker.
    /// Unsynchronised, that is a data race with a silent failure mode: a worker
    /// that cannot yet see the continuation drops its payload on the floor, and a
    /// dropped hook event looks like the HUD simply missing something rather than
    /// like a bug. Found by the "Socket resilience" suite, which loses roughly one
    /// payload per few hundred connections without this.
    private let stateLock = NSLock()
    private var unsafeListenFD: Int32 = -1
    private var unsafeContinuation: AsyncStream<HookEnvelope>.Continuation?

    private var listenFD: Int32 {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return unsafeListenFD
        }
        set {
            stateLock.lock()
            unsafeListenFD = newValue
            stateLock.unlock()
        }
    }

    private var continuation: AsyncStream<HookEnvelope>.Continuation? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return unsafeContinuation
        }
        set {
            stateLock.lock()
            unsafeContinuation = newValue
            stateLock.unlock()
        }
    }

    /// Called with the token of a prompt that can no longer be answered here,
    /// because its client went away — see `PendingDecisions.onWithdraw`. Set it
    /// before `start()`.
    public var onWithdraw: ((UInt64) -> Void)? {
        get { pending.onWithdraw }
        set { pending.onWithdraw = newValue }
    }

    /// How long a worker will wait for an accepted client to finish its frame.
    ///
    /// It is the only place the server abandons a connection it has already
    /// accepted, and a client that has connected but not yet been scheduled to
    /// write looks exactly like a client that has stalled. Measured on a loaded
    /// machine: 1–2 payloads per 120 were dropped even though the client's
    /// `connect` and `write` both reported success.
    ///
    /// A correction, because the earlier note here recorded a wrong conclusion:
    /// this value had **no effect at all** until `handle` began clearing
    /// `O_NONBLOCK` on the accepted descriptor. `accept()` inherits that flag from
    /// the listening socket on Darwin, and `SO_RCVTIMEO` is ignored on a
    /// non-blocking descriptor — so every read returned EAGAIN in microseconds and
    /// widening the window from 2s to 30s only perturbed timing. See `handle`.
    ///
    /// Ten seconds keeps the original guarantee — a wedged client cannot hold a
    /// worker forever — while being far outside anything scheduler starvation
    /// produces. The cost is paid only when a client really is stuck: in the
    /// normal case the frame is already in the socket buffer and the read returns
    /// at once. Dropping a hook event is much worse than briefly holding one of
    /// eight slots, because the loss is invisible: the client exits 0 believing it
    /// delivered, and the HUD just quietly misses a state change.
    ///
    /// Injectable so the regression test can prove the drop is gone at the value
    /// that actually ships.
    private let readTimeout: TimeInterval

    public init(
        path: String = IslandPaths.socket.path, log: IslandLog = .disabled,
        readTimeout: TimeInterval = 10
    ) {
        self.path = path
        self.log = log
        self.readTimeout = readTimeout
        self.pending = PendingDecisions(log: log)
    }

    /// Answers a waiting permission prompt. False if it is no longer pending,
    /// which is the normal outcome when the terminal was answered first.
    @discardableResult
    public func resolve(_ token: UInt64, with decision: PermissionDecision) -> Bool {
        pending.resolve(token, with: decision)
    }

    /// Why a payload that was accepted never reached the stream.
    ///
    /// Every one of these is a silent loss: the client wrote its frame, exited 0,
    /// and believes the HUD was told. Counting them by reason is the difference
    /// between "the island missed something" and a diagnosis — chasing one of
    /// these without it cost several wrong theories.
    public enum DropReason: String, Sendable, CaseIterable {
        /// The length prefix never completed within the read window.
        case shortPrefix
        /// A prefix claiming nothing, or more than the cap.
        case badLength
        /// The body never completed within the read window.
        case shortBody
        /// Malformed JSON, or no session id to key a session on.
        case undecodable
        /// Accepted, then the server was torn down before the worker ran.
        case serverGone
        /// The stream had already finished, so a yield had nowhere to go.
        case streamClosed
    }

    /// Counts of dropped payloads by reason, for diagnostics and tests.
    public func drops() -> [DropReason: Int] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return dropCounts
    }

    private var dropCounts: [DropReason: Int] = [:]

    private func recordDrop(_ reason: DropReason) {
        stateLock.lock()
        dropCounts[reason, default: 0] += 1
        stateLock.unlock()
        log.debug("dropped a payload: \(reason.rawValue)")
    }

    /// How many prompts are currently held open. Diagnostics only.
    public var pendingDecisionCount: Int { pending.pendingCount }

    /// Whether a prompt can still be answered here. See `PendingDecisions`.
    public func isPendingDecision(_ token: UInt64) -> Bool { pending.isPending(token) }

    /// How many prompts are live for one session. See `PermissionAsk.siblingCount`.
    public func pendingDecisions(forSession id: String) -> Int {
        pending.pendingCount(forSession: id)
    }

    /// Bind, listen, and return a stream of decoded payloads.
    public func start() throws -> AsyncStream<HookEnvelope> {
        IslandPaths.ensureRoot()

        // sockaddr_un.sun_path is 104 bytes on Darwin, including the NUL.
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else { throw StartError.pathTooLong(path) }

        unlink(path)  // A stale socket file from a crash would fail bind().

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw StartError.bindFailed(e)
        }

        // Owner-only. The payloads carry prompts and file paths.
        chmod(path, 0o600)

        // The accept handler drains in a loop until EAGAIN, which only
        // terminates on a non-blocking socket. Left blocking, the loop would
        // park inside accept() and hold the socket queue until the next
        // connection happened to arrive.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        guard listen(fd, 64) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw StartError.listenFailed(e)
        }

        listenFD = fd
        log.debug("socket listening at \(self.path)")

        return AsyncStream { continuation in
            self.continuation = continuation
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(fd) }
            self.acceptSource = source
            source.resume()

            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(path)
        pending.drain()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // EAGAIN/EWOULDBLOCK: drained.
            }
            // The semaphore is captured directly rather than reached through
            // `self`. Balancing a `wait()` through a weak reference only works
            // while the server outlives its own work: if it is released before
            // this block runs, `self?.signal()` is skipped, the semaphore is
            // deallocated with an outstanding wait, and libdispatch traps —
            // `_dispatch_semaphore_dispose`, SIGTRAP, no message. The descriptor
            // leaked in that case too, so closing it is part of the same fix.
            let slots = connectionSlots
            connectionSlots.wait()
            connectionQueue.async { [weak self] in
                defer { slots.signal() }
                guard let self else {
                    close(client)
                    return  // Counted inside `handle` is impossible here; see serverGone.
                }
                self.handle(client)
            }
        }
    }

    private func handle(_ fd: Int32) {
        // A prompt the HUD can answer outlives this worker: ownership of the
        // descriptor moves to `pending`, whose dispatch source closes it.
        var handedOff = false
        defer { if !handedOff { close(fd) } }

        // Clear O_NONBLOCK before setting the timeout, or the timeout does nothing.
        //
        // `start()` marks the listening socket non-blocking so the accept loop can
        // drain to EAGAIN, and on Darwin accept() copies that flag onto every
        // descriptor it returns. SO_RCVTIMEO does not apply to a non-blocking
        // descriptor: the read returns EAGAIN immediately instead of waiting. Every
        // client whose bytes had not already landed by the time its worker was
        // scheduled was therefore dropped as `shortPrefix`, however large the
        // configured window was.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }

        // Don't let a client that connects and then stalls hold a worker.
        var tv = timeval(
            tv_sec: Int(readTimeout),
            tv_usec: Int32((readTimeout - Double(Int(readTimeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let prefix = readExactly(fd, count: Framing.prefixLength),
            let length = Framing.decodePrefix(prefix)
        else {
            recordDrop(.shortPrefix)
            return
        }

        guard length > 0, length <= Framing.maxPayloadBytes else {
            log.debug("rejecting payload of \(length) bytes")
            recordDrop(.badLength)
            return
        }

        guard let body = readExactly(fd, count: Int(length)) else {
            recordDrop(.shortBody)
            return
        }

        do {
            guard var envelope = try HookEnvelope.decode(Data(body)) else {
                recordDrop(.undecodable)
                return
            }
            if envelope.event.awaitsDecision {
                // Held open whether or not this particular client is waiting for
                // an answer. A fire-and-forget one has already exited, so its
                // end reads as EOF immediately and the prompt is withdrawn
                // before the HUD can offer it — no version handshake needed.
                envelope.decisionToken = pending.register(fd, session: envelope.sessionID)
                // Counted after registering, so this prompt is included and the
                // figure is "how many others".
                envelope.siblingPromptCount =
                    max(0, pending.pendingCount(forSession: envelope.sessionID) - 1)
                handedOff = true
            }
            guard let continuation else {
                recordDrop(.streamClosed)
                return
            }
            continuation.yield(envelope)
        } catch {
            log.debug("payload decode failed: \(error)")
            recordDrop(.undecodable)
        }
    }

    private func readExactly(_ fd: Int32, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer[offset...].withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, count - offset)
            }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil  // EOF or error before the frame completed.
            }
        }
        return buffer
    }
}
