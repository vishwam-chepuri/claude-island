import ClaudeIslandCore
import Darwin
import Foundation

/// The hook client binary sits next to this test runner in the build products
/// directory, so tests exercise the real thing rather than a reimplementation.
///
/// It is not a dependency of the test product, so `swift run ClaudeIslandTests`
/// will happily run these against a stale copy of it. Run `swift build` first
/// after touching the client, or a green result here means nothing.
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
    return writeFrame(payload, to: fd)
}

private func writeFrame(_ payload: Data, to fd: Int32) -> Bool {
    var frame = Data(Framing.encodePrefix(UInt32(payload.count)))
    frame.append(payload)
    return frame.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) == raw.count }
}

/// Sends a frame and leaves the connection open, the way a client waiting for a
/// decision does. Caller owns the returned descriptor.
private func openFrame(_ payload: Data, to path: String) -> Int32? {
    guard let fd = connectSocket(path) else { return nil }
    guard writeFrame(payload, to: fd) else {
        close(fd)
        return nil
    }
    return fd
}

/// Reads one length-prefixed frame back, or nil if none arrives in time.
private func readFrame(_ fd: Int32, timeout: TimeInterval = 6) -> Data? {
    var tv = timeval(
        tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var prefix = [UInt8](repeating: 0, count: Framing.prefixLength)
    guard read(fd, &prefix, Framing.prefixLength) == Framing.prefixLength,
        let length = Framing.decodePrefix(prefix), length > 0,
        length <= Framing.maxPayloadBytes
    else { return nil }

    var body = [UInt8](repeating: 0, count: Int(length))
    var offset = 0
    while offset < Int(length) {
        let n = body[offset...].withUnsafeMutableBytes { raw -> Int in
            read(fd, raw.baseAddress, Int(length) - offset)
        }
        guard n > 0 else { return nil }
        offset += n
    }
    return Data(body)
}

private func permissionPayload(_ session: String, command: String = "rm -rf ./build") -> Data {
    Data(
        """
        {"session_id":"\(session)","hook_event_name":"PermissionRequest","cwd":"/w",\
        "tool_name":"Bash","tool_input":{"command":"\(command)"}}
        """.utf8)
}

/// Drains a stream into a buffer on a background task so tests can wait for the
/// next envelope with a timeout instead of hanging forever when nothing lands.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [HookEnvelope] = []
    /// Every session id ever delivered, kept separately from `buffer` because
    /// `next()` consumes. A test that asks "what is next?" cannot also answer
    /// "did this ever arrive?" — looking for one payload throws away the others,
    /// which turns a late delivery into an indistinguishable phantom loss.
    private var everSeen = Set<String>()
    private var pump: Task<Void, Never>?

    init(_ stream: AsyncStream<HookEnvelope>) {
        // AsyncStream buffers unboundedly by default, so envelopes yielded
        // before this pump starts are still delivered.
        //
        // `weak self`, not `self`: a strong capture makes the task and the
        // collector own each other, so `deinit` never runs and every collector
        // the suite ever built keeps a live task for the rest of the process.
        pump = Task { [weak self] in
            for await envelope in stream { self?.append(envelope) }
        }
    }

    deinit { pump?.cancel() }

    // Non-async so NSLock stays legal; the async caller only ever awaits sleep.
    private func append(_ e: HookEnvelope) {
        lock.lock()
        buffer.append(e)
        everSeen.insert(e.sessionID)
        lock.unlock()
    }

    /// Whether this payload has ever arrived. Non-consuming.
    func hasSeen(_ sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return everSeen.contains(sessionID)
    }

    func waitToSee(_ sessionID: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasSeen(sessionID) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func take() -> HookEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty ? nil : buffer.removeFirst()
    }

    /// Generous by default, and deliberately more generous than it looks like it
    /// needs to be. These assert that a payload *arrives*, never how fast.
    ///
    /// The bound has now produced false failures twice at 6s. A reproducer that
    /// hammers the same paths — see the "Socket resilience" suite — cannot make
    /// the server drop a payload across 100 malformed frames or 40 lifecycles, so
    /// what this timeout was catching was a loaded machine, not a defect. Real
    /// wedges belong to that suite, which fails deterministically; a wall-clock
    /// bound here can only be a source of noise, so it is set well past anything
    /// a scheduler hiccup can produce.
    func next(timeout: TimeInterval = 20) async -> HookEnvelope? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let head = take() { return head }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}

/// Collects withdrawal callbacks so a test can wait for one with a timeout.
private final class Withdrawals: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens = Set<UInt64>()

    func record(_ token: UInt64) {
        lock.lock()
        tokens.insert(token)
        lock.unlock()
    }

    private func contains(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokens.contains(token)
    }

    func waitFor(_ token: UInt64, timeout: TimeInterval = 6) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if contains(token) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
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

    suite("Permission round trip") {

        test("A permission request arrives with a token to answer it by") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            let fd = try await require(openFrame(permissionPayload("tok-1"), to: path))
            defer { close(fd) }

            let collector = StreamCollector(stream)
            let envelope = try await require(await collector.next())
            await expect(envelope.decisionToken != nil, "no token to answer the prompt by")
        }

        test("An event that cannot be answered carries no token") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            await expect(
                sendFrame(
                    Data(#"{"session_id":"tok-2","hook_event_name":"PreToolUse"}"#.utf8), to: path))

            let collector = StreamCollector(stream)
            let envelope = try await require(await collector.next())
            await expectEqual(envelope.decisionToken, nil)
        }

        test("Resolving a token delivers the decision to the waiting client") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            let fd = try await require(openFrame(permissionPayload("tok-3"), to: path))
            defer { close(fd) }

            let collector = StreamCollector(stream)
            let envelope = try await require(await collector.next())
            let token = try await require(envelope.decisionToken)

            await expect(server.resolve(token, with: .allow), "resolve reported failure")

            let response = try await require(readFrame(fd), "client got no decision")
            let text = String(decoding: response, as: UTF8.self)
            await expectEqual(text, PermissionDecision.allow.hookResponseJSON)
        }

        test("A token can only be resolved once") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            let fd = try await require(openFrame(permissionPayload("tok-4"), to: path))
            defer { close(fd) }

            let collector = StreamCollector(stream)
            let token = try await require((await collector.next())?.decisionToken)

            await expect(server.resolve(token, with: .allow))
            await expect(
                !server.resolve(token, with: .deny(note: nil)),
                "a second answer to the same prompt was accepted")
        }

        test("Resolving an unknown token reports failure rather than trapping") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer {
                withExtendedLifetime(stream) {}
                server.stop()
            }
            await expect(!server.resolve(4_242, with: .allow))
        }

        // A client can go away at any point — it timed out, it was killed, the
        // session was interrupted. The island has to notice, or the card keeps
        // offering a button that answers a closed socket.
        //
        // This is deliberately not claimed as the terminal-answered path:
        // measured against claude 2.1.226, answering in the terminal leaves the
        // hook running. See `PendingDecisions.onWithdraw`.
        test("A client that hangs up is reported as withdrawn") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let withdrawn = Withdrawals()
            server.onWithdraw = { withdrawn.record($0) }
            let stream = try server.start()
            defer { server.stop() }

            let fd = try await require(openFrame(permissionPayload("tok-5"), to: path))
            let collector = StreamCollector(stream)
            let token = try await require((await collector.next())?.decisionToken)

            close(fd)  // The terminal answered; Claude Code reaped the hook.

            await expect(
                await withdrawn.waitFor(token), "withdrawal was never reported for \(token)")
            await expect(
                !server.resolve(token, with: .allow),
                "a withdrawn prompt still accepted an answer")
        }

        // Parallel tool calls in one session raise several prompts at once. The
        // registry is the only place that knows how many are live, so it is the
        // only honest place to count them.
        test("A second prompt in the same session is stamped as having a sibling") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }
            let collector = StreamCollector(stream)

            let first = try await require(openFrame(permissionPayload("twin"), to: path))
            defer { close(first) }
            let firstEnvelope = try await require(await collector.next())
            await expectEqual(firstEnvelope.siblingPromptCount, 0, "the first prompt is alone")

            let second = try await require(
                openFrame(permissionPayload("twin", command: "git push --force"), to: path))
            defer { close(second) }
            let secondEnvelope = try await require(await collector.next())
            await expectEqual(secondEnvelope.siblingPromptCount, 1)
        }

        test("A prompt in a different session is not counted as a sibling") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }
            let collector = StreamCollector(stream)

            let a = try await require(openFrame(permissionPayload("alone-a"), to: path))
            defer { close(a) }
            _ = await collector.next()
            let b = try await require(openFrame(permissionPayload("alone-b"), to: path))
            defer { close(b) }
            let envelope = try await require(await collector.next())
            await expectEqual(envelope.siblingPromptCount, 0)
        }

        // The withdrawal callback can land before the envelope it belongs to has
        // reached the store — a client that writes and exits is already gone by
        // the time its payload is decoded — so a push notification alone cannot
        // keep a dead prompt off the card. Whoever ingests the envelope has to be
        // able to ask whether the prompt is still live.
        test("A prompt whose client has gone is no longer pending") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            let fd = try await require(openFrame(permissionPayload("gone"), to: path))
            let collector = StreamCollector(stream)
            let token = try await require((await collector.next())?.decisionToken)
            await expect(server.isPendingDecision(token), "a live prompt reported as dead")

            close(fd)
            let deadline = Date().addingTimeInterval(6)
            while server.isPendingDecision(token), Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await expect(
                !server.isPendingDecision(token),
                "a prompt with no client behind it still reports as answerable")
        }

        // Every held prompt costs a descriptor and a dispatch source until it is
        // answered or withdrawn. A leak in either would not show up on one
        // prompt — it would show up as the HUD going deaf after a few hundred
        // permission requests, days into a session, which is the hardest kind of
        // bug to attribute. So: churn far more of them than a day would, and
        // insist the registry comes back to empty and the listener still serves.
        test("Hundreds of prompts opened and abandoned leave nothing behind") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }
            let collector = StreamCollector(stream)

            let churn = 300
            for i in 0..<churn {
                guard let fd = openFrame(permissionPayload("churn-\(i)"), to: path) else {
                    return await expect(false, "could not open prompt \(i) — descriptors leaked?")
                }
                close(fd)
            }

            // Drain so the withdrawals have all been processed before counting.
            var seen = 0
            while seen < churn, await collector.next(timeout: 10) != nil { seen += 1 }
            await expectEqual(seen, churn, "the listener stopped delivering partway through")

            let deadline = Date().addingTimeInterval(10)
            while server.pendingDecisionCount > 0, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            await expectEqual(
                server.pendingDecisionCount, 0,
                "held prompts were never reaped after their clients hung up")

            await expect(
                sendFrame(
                    Data(#"{"session_id":"after-churn","hook_event_name":"Stop"}"#.utf8), to: path))
            var arrived = false
            while !arrived, let envelope = await collector.next(timeout: 10) {
                arrived = envelope.sessionID == "after-churn"
            }
            await expect(arrived, "listener went deaf after \(churn) prompts")
        }

        // The connection pool is a small semaphore. Holding prompts open must
        // not consume a worker each, or a handful of pending prompts wedges the
        // listener for every other session.
        test("Prompts held open beyond the worker pool do not stall other payloads") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            var held: [Int32] = []
            defer { held.forEach { close($0) } }
            for i in 0..<20 {
                if let fd = openFrame(permissionPayload("held-\(i)"), to: path) { held.append(fd) }
            }
            await expectEqual(held.count, 20, "could not open the prompts")

            // Without this the test could pass vacuously: 20 connections that
            // were quietly closed rather than held would starve nothing.
            let collector = StreamCollector(stream)
            var tokens = Set<UInt64>()
            while tokens.count < 20, let envelope = await collector.next(timeout: 8) {
                if let token = envelope.decisionToken { tokens.insert(token) }
            }
            await expectEqual(tokens.count, 20, "prompts were not all held open")
            await expectEqual(server.pendingDecisionCount, 20)

            await expect(
                sendFrame(
                    Data(#"{"session_id":"still-serving","hook_event_name":"Stop"}"#.utf8),
                    to: path))

            var seen = Set<String>()
            while !seen.contains("still-serving"), let envelope = await collector.next(timeout: 8) {
                seen.insert(envelope.sessionID)
            }
            await expect(
                seen.contains("still-serving"),
                "listener stalled with 20 prompts pending; saw \(seen.count) payloads")
        }
    }

    suite("Awaiting client") {

        /// Launches the real hook client in await mode with the payload on stdin.
        func launchAwaiting(
            _ binary: URL, socket: String, timeoutMillis: Int, payload: Data
        ) throws -> (process: Process, stdout: Pipe) {
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "--socket", socket, "--await-decision",
                "--decision-timeout", String(timeoutMillis),
            ]
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            try process.run()
            stdin.fileHandleForWriting.write(payload)
            try stdin.fileHandleForWriting.close()
            return (process, stdout)
        }

        test("The client forwards a decision to stdout") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }

            let launched = try launchAwaiting(
                binary, socket: path, timeoutMillis: 20_000,
                payload: permissionPayload("await-1"))

            let collector = StreamCollector(stream)
            let envelope = try await require(await collector.next(timeout: 8))
            let token = try await require(envelope.decisionToken, "client was not held open")
            await expect(server.resolve(token, with: .deny(note: "from the island")))

            launched.process.waitUntilExit()
            let out = String(
                decoding: launched.stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            await expectEqual(launched.process.terminationStatus, 0)
            await expectEqual(
                out.trimmingCharacters(in: .whitespacesAndNewlines),
                PermissionDecision.deny(note: "from the island").hookResponseJSON)
        }

        // Silence is the fallback that keeps this safe: Claude Code goes on
        // showing its own dialog, so an unanswered prompt is simply a prompt.
        test("The client stays silent when no decision arrives before its deadline") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer {
                withExtendedLifetime(stream) {}
                server.stop()
            }

            let started = Date()
            let launched = try launchAwaiting(
                binary, socket: path, timeoutMillis: 800,
                payload: permissionPayload("await-2"))
            launched.process.waitUntilExit()
            let elapsed = Date().timeIntervalSince(started)

            let out = launched.stdout.fileHandleForReading.readDataToEndOfFile()
            await expectEqual(launched.process.terminationStatus, 0)
            await expect(out.isEmpty, "client volunteered \(out.count) bytes with no decision")
            // Both bounds matter: the upper one catches a client that never gives
            // up, the lower one catches a client that never waited at all and so
            // would never have been answerable.
            await expect(elapsed > 0.7, "client did not wait for its deadline (\(elapsed)s)")
            await expect(elapsed < 6, "client ignored its deadline (\(elapsed)s)")
        }

        test("The client gives up at once when nothing is listening") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let started = Date()
            let launched = try launchAwaiting(
                binary, socket: "/tmp/absent-\(UUID().uuidString).sock", timeoutMillis: 60_000,
                payload: permissionPayload("await-3"))
            launched.process.waitUntilExit()
            let elapsed = Date().timeIntervalSince(started)

            let out = launched.stdout.fileHandleForReading.readDataToEndOfFile()
            await expectEqual(launched.process.terminationStatus, 0)
            await expect(out.isEmpty)
            // A dead HUD must not add its deadline to every permission prompt.
            await expect(elapsed < 2, "waited \(elapsed)s for a socket that was not there")
        }
    }

    // Chases an intermittent full-suite failure — "A truncated frame does not
    // wedge the server", where the recovery payload never arrived at all, not
    // merely late. One round trip cannot tell a wedge from a slow machine, so
    // these reproduce the suite's actual shape: malformed frames in quick
    // succession, and the server lifecycle churned the way 180 tests churn it.
    suite("Socket resilience") {

        test("A hundred malformed frames in a row never cost a good one") {
            let path = temporarySocketPath()
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }
            let collector = StreamCollector(stream)

            let rounds = 100
            var sent = Set<String>()
            for i in 0..<rounds {
                // Promise 100 bytes, send 10, hang up — the exact shape of the
                // test that fails.
                if let fd = connectSocket(path) {
                    var frame = Framing.encodePrefix(100)
                    frame.append(contentsOf: Array("{\"a\":1234}".utf8))
                    _ = write(fd, &frame, frame.count)
                    close(fd)
                }
                // And an oversized claim, which takes the other rejection path.
                if let fd = connectSocket(path) {
                    var prefix = Framing.encodePrefix(1 << 30)
                    _ = write(fd, &prefix, 4)
                    close(fd)
                }
                // Counted, not assumed. Driving 3 connections per round outruns
                // the 64-deep listen backlog, and a refused connect is not a lost
                // payload — it is a client that never got to speak, which the real
                // hook client treats as "exit 0 and let the session continue".
                // Asserting on sends that never happened is how this test spent a
                // round accusing the server of dropping traffic it never received.
                if sendFrame(
                    Data(#"{"session_id":"good-\#(i)","hook_event_name":"Stop"}"#.utf8),
                    to: path)
                {
                    sent.insert("good-\(i)")
                }
            }

            var seen = Set<String>()
            while seen.count < sent.count, let envelope = await collector.next(timeout: 20) {
                if sent.contains(envelope.sessionID) { seen.insert(envelope.sessionID) }
            }
            await expect(sent.count > rounds / 2, "only \(sent.count)/\(rounds) sends landed")
            await expectEqual(
                seen.count, sent.count,
                "server accepted \(sent.count) payloads and delivered \(seen.count)")
        }

        // Diagnostic for the intermittent loss: is the payload gone, or merely
        // stranded in the listen backlog because the accept wakeup was missed?
        //
        // If a later connection flushes the earlier one out, the connection was
        // never accepted and the server simply stopped being told about it — which
        // is a missed-wakeup bug in the accept source, not a parsing or delivery
        // bug. That distinction decides the fix, so it is worth a test that says
        // which it is out loud.
        test("Every accepted payload is delivered, even if not promptly") {
            let path = temporarySocketPath()
            // Deliberately the shipping configuration, not a widened one: this is
            // the regression guard for payloads the server used to abandon after
            // accepting them, so it has to fail if that window is tightened again.
            let server = SocketServer(path: path)
            let stream = try server.start()
            defer { server.stop() }
            let collector = StreamCollector(stream)

            var sent: [String] = []
            for i in 0..<120 {
                // A malformed frame first: connect, half-write, hang up. The same
                // shape as the test that intermittently fails.
                if let fd = connectSocket(path) {
                    var frame = Framing.encodePrefix(100)
                    frame.append(contentsOf: Array("{\"a\":1234}".utf8))
                    _ = write(fd, &frame, frame.count)
                    close(fd)
                }
                let name = "probe-\(i)"
                if sendFrame(
                    Data("{\"session_id\":\"\(name)\",\"hook_event_name\":\"Stop\"}".utf8),
                    to: path)
                {
                    sent.append(name)
                }
            }

            // Slow arrivals are fine; absent ones are not. Give the whole batch a
            // generous window and then ask what never came.
            for name in sent where !collector.hasSeen(name) {
                _ = await collector.waitToSee(name, timeout: 20)
            }
            let missing = sent.filter { !collector.hasSeen($0) }
            await expect(
                missing.isEmpty,
                "accepted \(sent.count) payloads, never delivered \(missing.count): "
                    + missing.prefix(5).joined(separator: ", "))
        }

        test("Churning the server lifecycle leaves each new one serving") {
            for i in 0..<40 {
                let path = temporarySocketPath()
                let server = SocketServer(path: path)
                let stream = try server.start()
                let collector = StreamCollector(stream)

                // A held prompt, so every generation exercises the handoff and
                // then the drain that `stop()` performs on it.
                var expected = Set<String>()
                let held = openFrame(permissionPayload("churn-\(i)"), to: path)
                if held != nil { expected.insert("churn-\(i)") }
                if sendFrame(
                    Data(#"{"session_id":"live-\#(i)","hook_event_name":"Stop"}"#.utf8), to: path)
                {
                    expected.insert("live-\(i)")
                }

                var seen = Set<String>()
                while seen.count < expected.count,
                    let envelope = await collector.next(timeout: 20)
                {
                    if expected.contains(envelope.sessionID) { seen.insert(envelope.sessionID) }
                }
                await expectEqual(
                    seen.count, expected.count,
                    "generation \(i) accepted \(expected) but delivered \(seen)")

                server.stop()
                if let held { close(held) }
            }
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
