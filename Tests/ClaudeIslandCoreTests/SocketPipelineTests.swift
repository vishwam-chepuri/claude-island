import ClaudeIslandCore
import Darwin
import Foundation

/// The hook client binary sits next to this test runner in the build products
/// directory, so tests exercise the real thing rather than a reimplementation.
private func notifyBinary() -> URL? {
    let runner = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let candidate = runner.deletingLastPathComponent()
        .appendingPathComponent("claude-island-notify")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

/// Kept under /tmp on purpose: sockaddr_un.sun_path is 104 bytes and the
/// default temp directory is long enough to overflow it.
private func temporarySocketPath() -> String {
    "/tmp/ci-test-\(UInt32.random(in: 0...UInt32.max)).sock"
}

private func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    guard bytes.count < 104 else {
        close(fd)
        return nil
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let ok = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Minimal in-process client mirroring the wire format the real binary writes.
private func sendFrame(_ payload: Data, to path: String) -> Bool {
    guard let fd = connectSocket(path) else { return false }
    defer { close(fd) }
    var frame = Data(Framing.encodePrefix(UInt32(payload.count)))
    frame.append(payload)
    return frame.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) == raw.count }
}

/// Drains a stream into a buffer on a background task so tests can wait for the
/// next envelope with a timeout instead of hanging forever when nothing lands.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [HookEnvelope] = []
    private var pump: Task<Void, Never>?

    init(_ stream: AsyncStream<HookEnvelope>) {
        // AsyncStream buffers unboundedly by default, so envelopes yielded
        // before this pump starts are still delivered.
        pump = Task { [self] in
            for await envelope in stream { append(envelope) }
        }
    }

    deinit { pump?.cancel() }

    // Non-async so NSLock stays legal; the async caller only ever awaits sleep.
    private func append(_ e: HookEnvelope) {
        lock.lock()
        buffer.append(e)
        lock.unlock()
    }

    private func take() -> HookEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty ? nil : buffer.removeFirst()
    }

    /// Generous by default. These assert that a payload arrives, not how fast,
    /// and a tight bound made the suite flake on a loaded machine.
    func next(timeout: TimeInterval = 6) async -> HookEnvelope? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let head = take() { return head }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}

func registerSocketPipelineTests() {
    suite("Socket pipeline") {

        test("A framed payload arrives as a decoded envelope") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            await expect(
                sendFrame(
                    Data(
                        #"{"session_id":"sock-1","hook_event_name":"PreToolUse","cwd":"/w","tool_name":"Bash","tool_input":{"command":"echo hi"}}"#
                            .utf8), to: path))

            let collector = StreamCollector(stream)
            let envelope = try await require(await collector.next(), "nothing arrived")
            await expectEqual(envelope.sessionID, "sock-1")
            await expectEqual(envelope.event, .preToolUse)
            await expectEqual(envelope.toolName, "Bash")
            await expectEqual(envelope.toolInput?["command"]?.stringValue, "echo hi")
        }

        test("A stale socket file does not prevent binding") {
            let path = temporarySocketPath()
            FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
            defer { unlink(path) }

            let server = SocketServer(path: path)
            _ = try server.start()  // Must not throw despite the leftover file.
            server.stop()
        }

        test("The socket is owner-only") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            // The stream must stay alive: dropping it terminates the server and
            // unlinks the socket file before it can be inspected.
            let stream = try server.start()
            defer {
                withExtendedLifetime(stream) {}
                server.stop()
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            await expect(
                perms & 0o077 == 0,
                "socket is group/world accessible: \(String(perms, radix: 8))")
        }

        test("An oversized length prefix is rejected and the server keeps serving") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            // Claim 1 GiB, then send nothing and hang up.
            if let fd = connectSocket(path) {
                var prefix = Framing.encodePrefix(1 << 30)
                _ = write(fd, &prefix, 4)
                close(fd)
            }

            await expect(
                sendFrame(
                    Data(#"{"session_id":"after","hook_event_name":"Stop"}"#.utf8), to: path))
            let collector = StreamCollector(stream)
            let envelope = try await require(
                await collector.next(), "server stopped serving after a bad frame")
            await expectEqual(envelope.sessionID, "after")
        }

        test("A truncated frame does not wedge the server") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            // Promise 100 bytes, send 10, hang up.
            if let fd = connectSocket(path) {
                var frame = Framing.encodePrefix(100)
                frame.append(contentsOf: Array("{\"a\":1234}".utf8))
                _ = write(fd, &frame, frame.count)
                close(fd)
            }

            await expect(
                sendFrame(
                    Data(#"{"session_id":"survivor","hook_event_name":"Stop"}"#.utf8), to: path))
            let collector = StreamCollector(stream)
            let envelope = try await require(await collector.next())
            await expectEqual(envelope.sessionID, "survivor")
        }

        test("Concurrent hook invocations all land") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            let count = 25
            DispatchQueue.concurrentPerform(iterations: count) { i in
                _ = sendFrame(
                    Data(
                        #"{"session_id":"s\#(i)","hook_event_name":"PreToolUse","tool_name":"Read"}"#
                            .utf8), to: path)
            }

            let collector = StreamCollector(stream)
            var seen = Set<String>()
            while seen.count < count, let envelope = await collector.next() {
                seen.insert(envelope.sessionID)
            }
            await expectEqual(seen.count, count)
        }

        test("The real hook client delivers a payload") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            let process = Process()
            process.executableURL = binary
            process.arguments = ["--socket", path]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(
                Data(
                    #"{"session_id":"real-client","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}"#
                        .utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            await expectEqual(process.terminationStatus, 0)

            let collector = StreamCollector(stream)
            // Spawning a process costs more than an in-process send, and this
            // runs after a 25-connection burst; allow for the tail.
            let envelope = try await require(await collector.next(timeout: 8))
            await expectEqual(envelope.sessionID, "real-client")
            await expectEqual(envelope.event, .permissionRequest)
            await expectEqual(envelope.toolInput?["command"]?.stringValue, "rm -rf /tmp/x")
        }

        test("The hook client exits 0 and fast when nothing is listening") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--socket", "/tmp/not-here-\(UUID().uuidString).sock"]
            let stdin = Pipe()
            process.standardInput = stdin

            let started = Date()
            try process.run()
            stdin.fileHandleForWriting.write(
                Data(#"{"session_id":"x","hook_event_name":"Stop"}"#.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            let elapsed = Date().timeIntervalSince(started)

            await expectEqual(process.terminationStatus, 0, "a dead HUD must never fail a hook")
            // Generous versus the 50 ms connect budget: a regression guard
            // against a blocking connect, not a benchmark.
            await expect(elapsed < 1.0, "took \(elapsed)s — client is not fire-and-forget")
        }

        test("The hook client tolerates empty stdin") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            _ = try server.start()
            defer { server.stop() }

            let process = Process()
            process.executableURL = binary
            process.arguments = ["--socket", path]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            await expectEqual(process.terminationStatus, 0)
        }
    }

    suite("Wire framing") {

        test("Length prefix round-trips little-endian") {
            for value: UInt32 in [0, 1, 255, 256, 65_535, 1 << 20, Framing.maxPayloadBytes] {
                await expectEqual(Framing.decodePrefix(Framing.encodePrefix(value)), value)
            }
        }

        test("A short prefix decodes to nil") {
            await expectEqual(Framing.decodePrefix([1, 2, 3]), nil)
        }
    }
}
