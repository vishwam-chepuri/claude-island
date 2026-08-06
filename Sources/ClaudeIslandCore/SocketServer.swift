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

    private let path: String
    private let log: IslandLog
    private let queue = DispatchQueue(label: "island.socket", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(
        label: "island.socket.conn", qos: .userInitiated, attributes: .concurrent)
    /// Caps connections handled at once. Each handler does a blocking read with
    /// a timeout, so an unbounded burst — several worktrees firing hooks in the
    /// same instant — would spawn a thread per connection and starve the pool.
    /// Payloads are tiny and short-lived; a small window is ample.
    private let connectionSlots = DispatchSemaphore(value: 8)

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var continuation: AsyncStream<HookEnvelope>.Continuation?

    public init(path: String = IslandPaths.socket.path, log: IslandLog = .disabled) {
        self.path = path
        self.log = log
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
            connectionSlots.wait()
            connectionQueue.async { [weak self] in
                defer { self?.connectionSlots.signal() }
                self?.handle(client)
            }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }

        // Don't let a client that connects and then stalls hold a worker.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let prefix = readExactly(fd, count: Framing.prefixLength),
            let length = Framing.decodePrefix(prefix)
        else { return }

        guard length > 0, length <= Framing.maxPayloadBytes else {
            log.debug("rejecting payload of \(length) bytes")
            return
        }

        guard let body = readExactly(fd, count: Int(length)) else { return }

        do {
            guard let envelope = try HookEnvelope.decode(Data(body)) else {
                log.debug("payload had no session_id; dropped")
                return
            }
            continuation?.yield(envelope)
        } catch {
            log.debug("payload decode failed: \(error)")
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
