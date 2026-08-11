// claude-island-notify — the Claude Code hook client.
//
// Hooks block Claude Code, so this binary is fire-and-forget by construction:
// read stdin, connect with a 50 ms budget, write, exit 0. Every failure path is
// a silent exit 0. A dead HUD must never break or slow a Claude session.
//
// `--await-decision` is the one exception, used only for PermissionRequest. There
// the hook is *supposed* to block: Claude Code paints its permission dialog and
// waits on the hook at the same time, so waiting here buys the HUD a window to
// answer in without taking the prompt away from the terminal. Exiting silently
// remains the fallback for every failure — the dialog is still on screen, so a
// prompt this binary never answers is just an ordinary prompt.
//
// Deliberately imports Darwin and nothing else — no Foundation, no
// ClaudeIslandCore. Foundation alone adds milliseconds of dyld work per
// invocation, and this runs on every tool call.

import Darwin

private let connectTimeoutMillis: Int32 = 50
private let maxPayloadBytes = 16 << 20
/// Matches the hook timeout the installer writes. Waiting longer than Claude
/// Code will wait buys nothing; waiting less throws away answerable time.
private let defaultDecisionTimeoutMillis: Int32 = 600_000

/// Read all of stdin. Bounded by the pipe Claude Code hands us.
private func readStdin() -> [UInt8] {
    var buffer = [UInt8]()
    buffer.reserveCapacity(16 << 10)
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while true {
        let n = chunk.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
        if n > 0 {
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxPayloadBytes { return [] }
        } else if n == 0 {
            return buffer
        } else if errno == EINTR {
            continue
        } else {
            return []
        }
    }
}

private func flagValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func socketPath() -> [UInt8]? {
    // --socket <path> exists so tests can point at a temp socket.
    if let override = flagValue("--socket") { return Array(override.utf8) }
    guard let home = getenv("HOME") else { return nil }
    var path = Array(String(cString: home).utf8)
    path.append(contentsOf: Array("/.claude-island/island.sock".utf8))
    return path
}

private func decisionTimeoutMillis() -> Int32 {
    guard let raw = flagValue("--decision-timeout"), let parsed = Int32(raw), parsed > 0 else {
        return defaultDecisionTimeoutMillis
    }
    return parsed
}

/// Reads exactly `count` bytes, or nil if the connection ends or stalls first.
private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
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
            return nil
        }
    }
    return buffer
}

/// Waits for the HUD to answer, and forwards its answer to stdout verbatim —
/// which is where Claude Code reads a hook's decision from.
///
/// Every giving-up path writes nothing at all, because partial or malformed
/// stdout would be worse than silence: silence leaves the dialog exactly as it
/// is, still answerable by hand.
private func awaitDecision(_ fd: Int32, timeoutMillis: Int32) {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&pfd, 1, timeoutMillis) > 0, pfd.revents & Int16(POLLIN) != 0 else { return }

    // Readable now means the answer is arriving (or the HUD hung up). Whichever
    // it is, it resolves in microseconds, so a short backstop is enough to stop
    // a half-written frame from parking us until Claude Code's own timeout.
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    guard let prefix = readExactly(fd, 4) else { return }
    let length =
        UInt32(prefix[0]) | UInt32(prefix[1]) << 8 | UInt32(prefix[2]) << 16
        | UInt32(prefix[3]) << 24
    guard length > 0, Int(length) <= maxPayloadBytes else { return }
    guard let body = readExactly(fd, Int(length)) else { return }
    _ = writeAll(1, body)
}

/// Connect with a hard millisecond budget. Non-blocking connect plus poll, so a
/// hung listener costs us 50 ms rather than the kernel's default timeout.
private func connectWithTimeout(_ pathBytes: [UInt8]) -> Int32? {
    guard pathBytes.count < 104 else { return nil }  // sockaddr_un.sun_path

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result != 0 {
        guard errno == EINPROGRESS else {
            close(fd)
            return nil
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, connectTimeoutMillis)
        guard ready > 0, pfd.revents & Int16(POLLOUT) != 0 else {
            close(fd)
            return nil
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard soError == 0 else {
            close(fd)
            return nil
        }
    }

    _ = fcntl(fd, F_SETFL, flags)  // Back to blocking for the write.
    var tv = timeval(tv_sec: 0, tv_usec: Int32(connectTimeoutMillis) * 1000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress, bytes.count - offset)
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

// SIGPIPE would kill us if the HUD closes mid-write. Ignoring it turns that
// into an EPIPE we already treat as "give up quietly".
signal(SIGPIPE, SIG_IGN)

let payload = readStdin()
guard !payload.isEmpty, payload.count <= maxPayloadBytes else { exit(0) }
guard let path = socketPath(), let fd = connectWithTimeout(path) else { exit(0) }

let length = UInt32(payload.count)
var frame = [UInt8]()
frame.reserveCapacity(payload.count + 4)
frame.append(UInt8(truncatingIfNeeded: length))
frame.append(UInt8(truncatingIfNeeded: length >> 8))
frame.append(UInt8(truncatingIfNeeded: length >> 16))
frame.append(UInt8(truncatingIfNeeded: length >> 24))
frame.append(contentsOf: payload)

if writeAll(fd, frame), CommandLine.arguments.contains("--await-decision") {
    awaitDecision(fd, timeoutMillis: decisionTimeoutMillis())
}
close(fd)
exit(0)
