import Darwin
import Foundation

/// Holds the socket connections of hook clients that are blocked waiting for a
/// permission decision, and answers them when the HUD says so.
///
/// A held connection deliberately costs no thread. The hook client sends its
/// payload and then goes quiet, so there is nothing to read and nothing to wait
/// on — the descriptor just sits in a `DispatchSourceRead` until either the HUD
/// answers it or the client disappears. Parking a worker per prompt instead
/// would exhaust `SocketServer`'s connection pool after a handful of them and
/// stall every other session's payloads.
///
/// Ownership of each descriptor belongs to its dispatch source: the cancel
/// handler is the only place a held descriptor is closed, so resolution and
/// client death cannot race into a double close.
final class PendingDecisions: @unchecked Sendable {
    /// Called with the token of a prompt whose client vanished.
    ///
    /// Note what this does *not* cover. Measured against claude 2.1.226:
    /// answering in the terminal does **not** reap the waiting hook — it was
    /// still alive 10s later — so this fires on client exit, timeout or crash,
    /// but not promptly when the terminal settles a prompt. What covers that case
    /// is the state machine: the session's next event replaces
    /// `awaitingPermission` and the controls go with it. Until then the card can
    /// briefly offer an answer Claude Code has already superseded, which it
    /// discards; pressing it resolves to `false` and clears the offer.
    var onWithdraw: ((UInt64) -> Void)?

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "island.socket.pending", qos: .userInitiated)
    private var nextToken: UInt64 = 1
    private var sources: [UInt64: DispatchSourceRead] = [:]
    private var descriptors: [UInt64: Int32] = [:]
    /// Which session each held prompt belongs to, so concurrent prompts within
    /// one session can be counted. See `pendingCount(forSession:)`.
    private var owners: [UInt64: String] = [:]
    private let log: IslandLog

    init(log: IslandLog = .disabled) {
        self.log = log
    }

    /// Takes ownership of `fd` and returns the token that answers it.
    func register(_ fd: Int32, session: String) -> UInt64 {
        lock.lock()
        let token = nextToken
        nextToken += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        sources[token] = source
        descriptors[token] = fd
        owners[token] = session
        lock.unlock()

        // The client writes once and then waits, so readability here means it
        // hung up rather than that it had more to say.
        source.setEventHandler { [weak self] in self?.clientVanished(token, fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return token
    }

    /// Answers a waiting client. False if the prompt is no longer pending —
    /// already answered, or withdrawn because the terminal got there first.
    func resolve(_ token: UInt64, with decision: PermissionDecision) -> Bool {
        lock.lock()
        guard let fd = descriptors[token], let source = sources[token] else {
            lock.unlock()
            return false
        }
        descriptors[token] = nil
        sources[token] = nil
        owners[token] = nil
        lock.unlock()

        let written = write(frame(for: decision), to: fd)
        // Cancelling closes the descriptor, which is the client's cue that the
        // response is complete.
        source.cancel()
        if !written { log.debug("decision \(token) could not be delivered") }
        return written
    }

    /// Drops every pending prompt, closing the connections. Each client falls
    /// back to its own deadline and stays answerable in the terminal.
    func drain() {
        lock.lock()
        let all = sources
        sources.removeAll()
        descriptors.removeAll()
        owners.removeAll()
        lock.unlock()
        all.values.forEach { $0.cancel() }
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.count
    }

    /// How many prompts are live for one session.
    ///
    /// More than one means the card cannot tell which of them the terminal is
    /// currently asking about — see `PermissionAsk.siblingCount`.
    func pendingCount(forSession id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return owners.values.reduce(0) { $0 + ($1 == id ? 1 : 0) }
    }

    /// Whether this prompt can still be answered.
    ///
    /// Needed because `onWithdraw` can fire before the envelope it belongs to has
    /// even reached the store: a client that writes and exits immediately — an
    /// installed hook without `--await-decision`, say — is already gone by the
    /// time its payload is decoded. A withdrawal for a prompt the store has never
    /// heard of has nothing to clear, so the token would otherwise survive into a
    /// card offering a button that answers a closed socket.
    func isPending(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[token] != nil
    }

    // MARK: - Private

    private func clientVanished(_ token: UInt64, _ fd: Int32) {
        // A byte would mean the client said something unexpected; zero means
        // EOF. Either way the prompt is no longer ours to answer.
        var scratch: UInt8 = 0
        let n = read(fd, &scratch, 1)
        if n > 0 { log.debug("pending decision \(token) sent unexpected data") }

        lock.lock()
        guard let source = sources[token] else {
            lock.unlock()
            return  // Already resolved; its cancel handler owns the close.
        }
        descriptors[token] = nil
        sources[token] = nil
        owners[token] = nil
        lock.unlock()

        source.cancel()
        onWithdraw?(token)
    }

    private func frame(for decision: PermissionDecision) -> [UInt8] {
        let payload = Array(decision.hookResponseJSON.utf8)
        return Framing.encodePrefix(UInt32(payload.count)) + payload
    }

    private func write(_ bytes: [UInt8], to fd: Int32) -> Bool {
        // The payload is a couple of hundred bytes, so this cannot realistically
        // block — but the caller is the UI, and a send timeout means even a
        // pathological client cannot stall it.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress, bytes.count - offset)
            }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
