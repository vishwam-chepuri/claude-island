# Reveal the session's terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the expanded card raise the terminal app that owns a session, and use the same knowledge to make the frontmost-mute heuristic exact.

**Architecture:** The hook client walks its own process ancestry with `sysctl` and splices the pid chain into the payload as `_island_pids` — a byte-level edit, never a JSON parse. Core carries the chain onto the session and owns a pure resolution walk; the App layer binds that walk to `NSRunningApplication` and raises the winner by spawning `/usr/bin/open -b`.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, Darwin `sysctl`. No third-party dependencies. Tests run via `swift run ClaudeIslandTests`, not `swift test`.

## Global Constraints

- **`claude-island-notify` imports `Darwin` and nothing else.** No Foundation, no `ClaudeIslandCore`. Foundation alone adds milliseconds of dyld work per invocation and this binary runs on every tool call.
- **`ClaudeIslandCore` imports no AppKit.** That is what lets the whole pipeline run headlessly under `--replay`.
- **The hook client must never fail or slow a Claude Code session.** Every failure path is a silent `exit(0)`. Budget: 2.49 ms median, 4.67 ms p95 with no listener.
- **The client must never corrupt a payload it did not understand.** Degrading to "no ancestry" is free; a mangled payload is not.
- **The expanded card is sized across *all* sessions, not the selected one.** Any per-session view that appears for one session and vanishes for another reflows the whole HUD on every switcher click. Two `--selftest` checks guard this.
- **Build before testing the client.** `claude-island-notify` is not a dependency of the test product, so `swift run ClaudeIslandTests` will happily run against a stale copy. Always `swift build` first.
- **Commit identity** is `Vishwam Chepuri <42149544+vishwam-chepuri@users.noreply.github.com>`, applied automatically. **No co-author trailer in commit messages.**
- **Never launch a worktree build beside the installed app** — a second instance steals the socket. `--selftest` is the safe path.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/claude-island-notify/main.swift` | Modify: ancestry walk + payload splice |
| `Sources/ClaudeIslandCore/HookEnvelope.swift` | Modify: decode `_island_pids` |
| `Sources/ClaudeIslandCore/Session.swift` | Modify: hold `ownerPIDs`; reducer captures it |
| `Sources/ClaudeIslandCore/OwnerResolution.swift` | Create: the pure resolution walk |
| `Sources/ClaudeIslandCore/TerminalApps.swift` | Modify: rewrite header comment for its new fallback-only role |
| `Sources/ClaudeIslandApp/SessionOwner.swift` | Create: AppKit binding + `open -b` raise |
| `Sources/ClaudeIslandApp/IslandViewModel.swift` | Modify: cached owner per session, reveal action |
| `Sources/ClaudeIslandApp/IslandContentViews.swift` | Modify: the `RevealRow` |
| `Sources/ClaudeIslandApp/AppController.swift` | Modify: `rings` takes the session's owner |
| `Sources/ClaudeIslandApp/SelfTest.swift` | Modify: reveal-state + mute checks |
| `Tests/ClaudeIslandCoreTests/OwnerResolutionTests.swift` | Create: walk + envelope + reducer tests |
| `Tests/ClaudeIslandCoreTests/SocketPipelineTests.swift` | Modify: client ancestry integration tests |
| `Tests/ClaudeIslandCoreTests/main.swift` | Modify: register the new suite |
| `Fixtures/ancestry.jsonl` | Create: replay fixture carrying `_island_pids` |
| `README.md` | Modify: record the activation finding |

---

### Task 1: Ancestry capture in the hook client

**Files:**
- Modify: `Sources/claude-island-notify/main.swift`
- Test: `Tests/ClaudeIslandCoreTests/SocketPipelineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: payloads on the wire carrying a top-level `"_island_pids": [Int32]` array, nearest ancestor first. Task 2 decodes it.

The ancestry tests live in `SocketPipelineTests.swift` rather than a new file because they need `notifyBinary()` and `temporarySocketPath()`, which are `private` to that file. Duplicating them would create two copies of the "is the client built?" logic that could disagree.

- [ ] **Step 1: Write the failing integration test**

Add to `Tests/ClaudeIslandCoreTests/SocketPipelineTests.swift`, inside the existing `suite("Socket pipeline")` block:

```swift
        // The client's parent IS this test runner, so the first entry is a
        // known value rather than merely "some number" — which is what makes
        // this a test of the walk and not of its plumbing.
        test("The hook client stamps its process ancestry into the payload") {
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
                Data(#"{"session_id":"anc","hook_event_name":"Stop"}"#.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            let collector = StreamCollector(stream)
            let envelope = try await require(await collector.next(timeout: 8))
            await expectEqual(envelope.sessionID, "anc")
            await expect(
                !envelope.ancestorPIDs.isEmpty, "the client recorded no ancestry at all")
            await expectEqual(
                envelope.ancestorPIDs.first, ProcessInfo.processInfo.processIdentifier,
                "the nearest ancestor should be this test runner")
        }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift build && swift run ClaudeIslandTests "ancestry"
```

Expected: compile error — `HookEnvelope` has no member `ancestorPIDs`. That is the correct first failure; Task 2 adds the field. To keep this task self-contained, add the field now as part of Step 3.

- [ ] **Step 3: Add the ancestry walk to the client**

Insert into `Sources/claude-island-notify/main.swift`, after `decisionTimeoutMillis()`:

```swift
/// How far up the process tree to look.
///
/// The observed chain is notify → claude → shell → helper → app, which is four;
/// eight leaves room for a wrapper or two without ever walking a pathological
/// tree to init.
private let maxAncestorHops = 8

/// Parent pid of `pid`, or 0 when it cannot be read.
private func parentPID(of pid: Int32) -> Int32 {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
    return info.kp_eproc.e_ppid
}

/// The chain of ancestor pids, nearest first, stopping at init.
///
/// Costs at most eight sysctls of a few microseconds each — negligible against
/// the 2.49 ms median this binary is held to.
private func ancestorPIDs() -> [Int32] {
    var chain = [Int32]()
    var pid = getppid()
    while pid > 1, chain.count < maxAncestorHops {
        chain.append(pid)
        pid = parentPID(of: pid)
    }
    return chain
}

/// Append a non-negative integer as decimal ASCII. Foundation-free itoa.
private func appendDecimal(_ out: inout [UInt8], _ value: Int32) {
    if value <= 0 {
        out.append(UInt8(ascii: "0"))
        return
    }
    var v = value
    var digits = [UInt8]()
    while v > 0 {
        digits.append(UInt8(ascii: "0") + UInt8(v % 10))
        v /= 10
    }
    out.append(contentsOf: digits.reversed())
}

private func isJSONSpace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
}

/// Inject the ancestry into the payload without parsing it.
///
/// This binary's most valuable property is that it forwards the hook payload
/// byte for byte. Becoming a JSON parser would cost the Foundation-free budget
/// and add a way to corrupt something we did not understand — so this finds the
/// opening brace and writes immediately after it, leaving every other byte
/// exactly where it was.
///
/// Anything that is not an object is returned unchanged. No ancestry is free;
/// a mangled payload is not.
private func splicingAncestry(into payload: [UInt8], _ pids: [Int32]) -> [UInt8] {
    guard !pids.isEmpty else { return payload }

    var open = 0
    while open < payload.count, isJSONSpace(payload[open]) { open += 1 }
    guard open < payload.count, payload[open] == UInt8(ascii: "{") else { return payload }

    // An empty object must not gain a trailing comma: `{"_island_pids":[1],}`
    // is not valid JSON, and the server would drop the payload outright.
    var next = open + 1
    while next < payload.count, isJSONSpace(payload[next]) { next += 1 }
    let isEmptyObject = next >= payload.count || payload[next] == UInt8(ascii: "}")

    var out = [UInt8]()
    out.reserveCapacity(payload.count + 20 + pids.count * 8)
    out.append(contentsOf: payload[0...open])
    out.append(contentsOf: Array(#""_island_pids":["#.utf8))
    for (i, pid) in pids.enumerated() {
        if i > 0 { out.append(UInt8(ascii: ",")) }
        appendDecimal(&out, pid)
    }
    out.append(UInt8(ascii: "]"))
    if !isEmptyObject { out.append(UInt8(ascii: ",")) }
    if open + 1 < payload.count {
        out.append(contentsOf: payload[(open + 1)...])
    }
    return out
}
```

Then replace the payload read at the bottom of the file. Change:

```swift
let payload = readStdin()
guard !payload.isEmpty, payload.count <= maxPayloadBytes else { exit(0) }
```

to:

```swift
let raw = readStdin()
guard !raw.isEmpty, raw.count <= maxPayloadBytes else { exit(0) }
let payload = splicingAncestry(into: raw, ancestorPIDs())
```

- [ ] **Step 4: Add the envelope field so the test compiles**

In `Sources/ClaudeIslandCore/HookEnvelope.swift`, add the stored property beside `receivedAt`:

```swift
    /// Ancestor pids of the hook client, nearest first, as stamped by
    /// `claude-island-notify`. Empty for replayed traces, synthetic events and
    /// status-line payloads — never a reason to clear an ancestry already held.
    public let ancestorPIDs: [Int32]
```

Add the parameter to `init`, defaulted so every existing construction site keeps compiling:

```swift
        ancestorPIDs: [Int32] = [],
```

and assign `self.ancestorPIDs = ancestorPIDs` in the body.

Add to the `Key` enum: `case islandPIDs = "_island_pids"`.

Add to `RawPayload`: `let ancestorPIDs: [Int32]?`, decoded inside its `init(from:)` as

```swift
        // `try?` rather than `try`: a malformed `_island_pids` must cost the
        // jump button, not the whole payload.
        ancestorPIDs = (try? c.decodeIfPresent([Int32].self, forKey: .islandPIDs)) ?? nil
```

and pass it through in `HookEnvelope.decode`:

```swift
            ancestorPIDs: raw.ancestorPIDs ?? [],
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
swift build && swift run ClaudeIslandTests "ancestry"
```

Expected: PASS.

- [ ] **Step 6: Add a raw-capture helper and the splice edge tests**

The empty-object trap cannot be observed through `SocketServer`, which decodes: a payload of `{}` has no session id and is dropped before anything can be asserted. These tests read the bytes off the wire directly.

Add to `Tests/ClaudeIslandCoreTests/SocketPipelineTests.swift`, beside the other private helpers at the top:

```swift
/// Accepts exactly one connection and returns the payload bytes verbatim, so a
/// test can assert on what the client actually wrote rather than on what the
/// decoder made of it. `SocketServer` cannot serve here: it drops anything
/// without a session id, which is precisely the case the splice can corrupt.
private func captureRawPayload(from binary: URL, stdin bytes: Data) throws -> Data? {
    let path = temporarySocketPath()
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { return nil }
    defer {
        close(listener)
        unlink(path)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < 104 else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(listener, 1) == 0 else { return nil }

    let process = Process()
    process.executableURL = binary
    process.arguments = ["--socket", path]
    let pipe = Pipe()
    process.standardInput = pipe
    try process.run()
    pipe.fileHandleForWriting.write(bytes)
    try pipe.fileHandleForWriting.close()

    let conn = accept(listener, nil, nil)
    guard conn >= 0 else { return nil }
    defer { close(conn) }

    var prefix = [UInt8](repeating: 0, count: 4)
    guard read(conn, &prefix, 4) == 4, let length = Framing.decodePrefix(prefix),
        length <= Framing.maxPayloadBytes
    else { return nil }

    var body = [UInt8](repeating: 0, count: Int(length))
    var got = 0
    while got < Int(length) {
        let n = body[got...].withUnsafeMutableBytes {
            read(conn, $0.baseAddress, Int(length) - got)
        }
        if n <= 0 { break }
        got += n
    }
    process.waitUntilExit()
    return got == Int(length) ? Data(body) : nil
}
```

Then the tests, in the same suite:

```swift
        // `{"_island_pids":[…],}` is not valid JSON. Spliced naively onto an
        // empty object that is exactly what comes out, and the payload is then
        // dropped in full rather than merely losing its ancestry.
        test("Splicing an empty object still produces valid JSON") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let raw = try await require(captureRawPayload(from: binary, stdin: Data("{}".utf8)))
            let parsed = try? JSONSerialization.jsonObject(with: raw)
            let object = try await require(parsed as? [String: Any], "not a JSON object: \(String(decoding: raw, as: UTF8.self))")
            await expect(object["_island_pids"] is [Any], "ancestry missing from spliced empty object")
        }

        test("A payload that is not an object is forwarded byte for byte") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let input = Data("[1,2,3]".utf8)
            let raw = try await require(captureRawPayload(from: binary, stdin: input))
            await expectEqual(raw, input, "the client rewrote a payload it did not understand")
        }

        test("Splicing preserves every original key") {
            let binary = try await require(notifyBinary(), "claude-island-notify is not built")
            let raw = try await require(
                captureRawPayload(
                    from: binary,
                    stdin: Data(#"  {"session_id":"keep","hook_event_name":"Stop","cwd":"/tmp"}"#.utf8)))
            let object = try await require(
                (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])
            await expectEqual(object["session_id"] as? String, "keep")
            await expectEqual(object["hook_event_name"] as? String, "Stop")
            await expectEqual(object["cwd"] as? String, "/tmp")
            await expect(object["_island_pids"] is [Any], "ancestry missing")
        }
```

- [ ] **Step 7: Run the full suite**

```bash
swift build && swift run ClaudeIslandTests
```

Expected: all tests pass, count up by 4 from 252.

- [ ] **Step 8: Verify the client is still fast**

```bash
swift build -c release
for i in $(seq 1 20); do
  /usr/bin/time -p .build/release/claude-island-notify --socket /tmp/nope.sock \
    <<< '{"session_id":"perf","hook_event_name":"Stop"}' 2>&1 | grep real
done
```

Expected: `real` under 0.02 on every line. The existing "exits 0 and fast when nothing is listening" test also guards this with a 1.0s ceiling.

- [ ] **Step 9: Commit**

```bash
git add Sources/claude-island-notify/main.swift Sources/ClaudeIslandCore/HookEnvelope.swift Tests/ClaudeIslandCoreTests/SocketPipelineTests.swift
git commit -m "Stamp the hook client's process ancestry onto every payload"
```

---

### Task 2: Carry the ancestry onto the session

**Files:**
- Modify: `Sources/ClaudeIslandCore/Session.swift`
- Create: `Tests/ClaudeIslandCoreTests/OwnerResolutionTests.swift`
- Modify: `Tests/ClaudeIslandCoreTests/main.swift`

**Interfaces:**
- Consumes: `HookEnvelope.ancestorPIDs: [Int32]` from Task 1.
- Produces: `Session.ownerPIDs: [Int32]`, read by Tasks 4–6.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeIslandCoreTests/OwnerResolutionTests.swift`:

```swift
import ClaudeIslandCore
import Foundation

func registerOwnerResolutionTests() {
    suite("Session ownership") {

        test("A hook event records the ancestry it carries") {
            let env = HookEnvelope(
                sessionID: "s1", event: .preToolUse, receivedAt: Date(),
                ancestorPIDs: [42, 17, 3])
            let out = SessionReducer.apply(env, to: nil)
            await expectEqual(out.session.ownerPIDs, [42, 17, 3])
        }

        // Status-line payloads interleave with hook events several times a
        // second and carry no pids. Treating absent as empty would wipe a good
        // ancestry continuously, and the button would flicker between states.
        test("An envelope without ancestry does not clear the ancestry held") {
            let first = HookEnvelope(
                sessionID: "s1", event: .preToolUse, receivedAt: Date(),
                ancestorPIDs: [42, 17])
            let seeded = SessionReducer.apply(first, to: nil).session
            let second = HookEnvelope(sessionID: "s1", event: .postToolUse, receivedAt: Date())
            let after = SessionReducer.apply(second, to: seeded).session
            await expectEqual(after.ownerPIDs, [42, 17])
        }

        test("A resumed session keeps its ancestry across SessionStart") {
            let first = HookEnvelope(
                sessionID: "s1", event: .preToolUse, receivedAt: Date(),
                ancestorPIDs: [42])
            let seeded = SessionReducer.apply(first, to: nil).session
            let restart = HookEnvelope(
                sessionID: "s1", event: .sessionStart, receivedAt: Date(),
                ancestorPIDs: [99, 7])
            let after = SessionReducer.apply(restart, to: seeded).session
            await expectEqual(
                after.ownerPIDs, [99, 7], "a resume should adopt the new terminal, not the old")
        }

        test("Ancestry decodes off the wire") {
            let json = Data(
                #"{"session_id":"w","hook_event_name":"Stop","_island_pids":[5,6,7]}"#.utf8)
            let env = try await require(try HookEnvelope.decode(json))
            await expectEqual(env.ancestorPIDs, [5, 6, 7])
        }

        // A bad `_island_pids` must cost the jump button, never the payload:
        // dropping the event would lose a state transition the HUD needs.
        test("Malformed ancestry costs the field, not the payload") {
            let json = Data(
                #"{"session_id":"w","hook_event_name":"Stop","_island_pids":"nope"}"#.utf8)
            let env = try await require(try HookEnvelope.decode(json))
            await expectEqual(env.sessionID, "w")
            await expectEqual(env.ancestorPIDs, [])
        }
    }
}
```

Register it in `Tests/ClaudeIslandCoreTests/main.swift`, after `registerSessionStoreTests()`:

```swift
registerOwnerResolutionTests()
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift build && swift run ClaudeIslandTests "Session ownership"
```

Expected: compile error — `Session` has no member `ownerPIDs`.

- [ ] **Step 3: Add the field and the reducer capture**

In `Sources/ClaudeIslandCore/Session.swift`, add to `Session` beside `transcriptPath`:

```swift
    /// Ancestor pids of the process that ran this session, nearest first, as
    /// stamped by the hook client.
    ///
    /// Held raw and resolved late. Pids go stale the moment a terminal quits,
    /// so resolving at click time rather than at capture time means a dead pid
    /// simply fails to resolve — no invalidation to get wrong. Re-stamped on
    /// every hook event, so a resumed session heals itself.
    public var ownerPIDs: [Int32] = []
```

In `SessionReducer.apply`, beside the other identity fields at line 158:

```swift
        // Only when the envelope actually carries them. Status-line payloads
        // carry none and arrive continuously; absent must mean "no news".
        if !envelope.ancestorPIDs.isEmpty { s.ownerPIDs = envelope.ancestorPIDs }
```

This sits *above* the `switch`, so the `.sessionStart` branch — which resets derived state — does not clear it, and a resume adopts the newly-stamped chain.

- [ ] **Step 4: Run to verify it passes**

```bash
swift build && swift run ClaudeIslandTests "Session ownership"
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeIslandCore/Session.swift Tests/ClaudeIslandCoreTests/OwnerResolutionTests.swift Tests/ClaudeIslandCoreTests/main.swift
git commit -m "Carry a session's process ancestry through the reducer"
```

---

### Task 3: The pure resolution walk

**Files:**
- Create: `Sources/ClaudeIslandCore/OwnerResolution.swift`
- Modify: `Tests/ClaudeIslandCoreTests/OwnerResolutionTests.swift`

**Interfaces:**
- Consumes: `Session.ownerPIDs` from Task 2.
- Produces:
  - `OwnerResolution.AppInfo(pid: Int32, bundleID: String?, name: String, isRegular: Bool)`
  - `OwnerResolution.Outcome` — `.owner(AppInfo)`, `.noOwningApp`, `.gone`, `.unknown`
  - `OwnerResolution.resolve(_ ancestors: [Int32], isRunning: (Int32) -> Bool, lookup: (Int32) -> AppInfo?) -> Outcome`

Two probes rather than one, and that distinction is the whole reason the four states are separable: `NSRunningApplication(processIdentifier:)` answers nil for a *live* non-app process such as `zsh`, so it cannot double as a liveness check.

- [ ] **Step 1: Write the failing tests**

Append inside the `suite("Session ownership")` block:

```swift
        // Mirrors the measured chain: claude → zsh → Code Helper → Code. Only
        // the last is a regular app; the helper is deliberately not, which is
        // what makes "first regular ancestor" land on the bundle root without
        // recognising the app by name.
        let chain: [Int32] = [4368, 72309, 1927, 1797]
        func fakeLookup(_ pid: Int32) -> OwnerResolution.AppInfo? {
            switch pid {
            case 1927:
                return .init(pid: 1927, bundleID: "com.microsoft.VSCode.helper",
                             name: "Code Helper", isRegular: false)
            case 1797:
                return .init(pid: 1797, bundleID: "com.microsoft.VSCode",
                             name: "Visual Studio Code", isRegular: true)
            default:
                return nil
            }
        }

        test("The walk skips helpers and lands on the app bundle") {
            let outcome = OwnerResolution.resolve(
                chain, isRunning: { _ in true }, lookup: fakeLookup)
            guard case .owner(let app) = outcome else {
                await fail("expected an owner, got \(outcome)")
                return
            }
            await expectEqual(app.pid, 1797)
            await expectEqual(app.bundleID, "com.microsoft.VSCode")
            await expectEqual(app.name, "Visual Studio Code")
        }

        // A daemon-hosted background job: processes alive, none of them an app.
        test("A chain with no app at all reports no owning app") {
            let outcome = OwnerResolution.resolve(
                [7518, 19655], isRunning: { _ in true }, lookup: { _ in nil })
            await expectEqual(outcome, .noOwningApp)
        }

        test("A chain of dead pids reports gone") {
            let outcome = OwnerResolution.resolve(
                [4368, 72309], isRunning: { _ in false }, lookup: { _ in nil })
            await expectEqual(outcome, .gone)
        }

        test("No ancestry at all is unknown, not gone") {
            let outcome = OwnerResolution.resolve(
                [], isRunning: { _ in false }, lookup: { _ in nil })
            await expectEqual(outcome, .unknown)
        }

        // `open -b` needs a bundle id. An app without one cannot be raised, so
        // it must not be offered as though it could.
        test("An app with no bundle id is not offered as an owner") {
            let outcome = OwnerResolution.resolve(
                [500], isRunning: { _ in true },
                lookup: { _ in .init(pid: 500, bundleID: nil, name: "Unbundled", isRegular: true) })
            await expectEqual(outcome, .noOwningApp)
        }
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift build && swift run ClaudeIslandTests "Session ownership"
```

Expected: compile error — cannot find `OwnerResolution` in scope.

- [ ] **Step 3: Write the implementation**

Create `Sources/ClaudeIslandCore/OwnerResolution.swift`:

```swift
import Foundation

/// Which app a session belongs to, resolved from the process ancestry the hook
/// client stamps on its payloads.
///
/// Pure, and handed both of its probes, for the same reason
/// `AppController.rings(_:under:frontmost:)` is handed the frontmost bundle id:
/// Core imports no AppKit, and a walk that asked the workspace anything itself
/// could not be exercised without a window server.
public enum OwnerResolution {

    /// What the app layer knows about one pid.
    public struct AppInfo: Sendable, Equatable {
        public let pid: Int32
        public let bundleID: String?
        public let name: String
        /// True for an app with a Dock presence — the bundle root rather than
        /// one of its helper processes. Measured: VS Code's `Code Helper` does
        /// not appear in `NSWorkspace.runningApplications` as a regular app,
        /// which is what lets the walk step over it.
        public let isRegular: Bool

        public init(pid: Int32, bundleID: String?, name: String, isRegular: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.isRegular = isRegular
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// An ancestor is a running, raisable app.
        case owner(AppInfo)
        /// Ancestors are alive but none is an app: a daemon-hosted background
        /// job, a tmux server, or a session on the far end of an SSH link.
        case noOwningApp
        /// Nothing in the chain is still running — whatever ran this has quit.
        case gone
        /// No ancestry was ever recorded: replay traces and synthetic events.
        case unknown
    }

    /// The first ancestor that is a raisable app, or why there isn't one.
    ///
    /// Two probes rather than one, because they answer different questions.
    /// `lookup` answers nil for a live `zsh` just as readily as for a dead pid,
    /// so it cannot tell "this session has no app" from "this session's app has
    /// quit" — and those want different words on screen.
    public static func resolve(
        _ ancestors: [Int32],
        isRunning: (Int32) -> Bool,
        lookup: (Int32) -> AppInfo?
    ) -> Outcome {
        guard !ancestors.isEmpty else { return .unknown }
        var sawLiving = false
        for pid in ancestors {
            if isRunning(pid) { sawLiving = true }
            if let info = lookup(pid), info.isRegular, info.bundleID != nil {
                return .owner(info)
            }
        }
        return sawLiving ? .noOwningApp : .gone
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
swift build && swift run ClaudeIslandTests "Session ownership"
```

Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeIslandCore/OwnerResolution.swift Tests/ClaudeIslandCoreTests/OwnerResolutionTests.swift
git commit -m "Resolve which app owns a session from its process ancestry"
```

---

### Task 4: The AppKit binding and the raise

**Files:**
- Create: `Sources/ClaudeIslandApp/SessionOwner.swift`

**Interfaces:**
- Consumes: `OwnerResolution` from Task 3.
- Produces:
  - `SessionOwner.resolve(_ ancestors: [Int32]) -> OwnerResolution.Outcome`
  - `SessionOwner.reveal(_ ancestors: [Int32]) -> Bool`

No unit test: this file is the AppKit binding, and everything in it that *can* be tested without a window server already was in Task 3. Its behaviour is covered by `--selftest` in Task 5 and by manual verification in Task 7.

- [ ] **Step 1: Write the implementation**

Create `Sources/ClaudeIslandApp/SessionOwner.swift`:

```swift
import AppKit
import ClaudeIslandCore

/// Binds `OwnerResolution` to the running system, and raises the winner.
enum SessionOwner {

    /// Resolve against the live process table and application list.
    static func resolve(_ ancestors: [Int32]) -> OwnerResolution.Outcome {
        OwnerResolution.resolve(
            ancestors,
            // EPERM means the process exists and simply is not ours to signal.
            // Reading that as "dead" would report a terminal running as another
            // user as having quit.
            isRunning: { pid in kill(pid, 0) == 0 || errno == EPERM },
            lookup: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
                return OwnerResolution.AppInfo(
                    pid: pid,
                    bundleID: app.bundleIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "the terminal",
                    isRegular: app.activationPolicy == .regular)
            })
    }

    /// Bring the session's app to the front. Returns whether anything was tried.
    ///
    /// Re-resolves rather than trusting a cached answer, and that is not
    /// belt-and-braces: `open -b` on an app that has *quit* launches a fresh
    /// copy. Raising a terminal that closed while the card was open would be a
    /// surprising new window rather than the session you asked for.
    ///
    /// `/usr/bin/open`, not `NSRunningApplication.activate()`. Measured from a
    /// background accessory app that is not itself frontmost:
    ///
    /// | call | result |
    /// |---|---|
    /// | `activate()` | returns `true`, frontmost unchanged |
    /// | `activate(from:options:)` | frontmost unchanged |
    /// | `NSWorkspace.openApplication(activates: true)` | no error, frontmost unchanged |
    /// | `/usr/bin/open -b` | activates |
    ///
    /// macOS 14's cooperative activation rules stop a non-active app raising
    /// another in-process, and every one of those APIs reports success anyway.
    /// Spawning `open` — a trusted LaunchServices helper — is honoured, and
    /// needs no Automation or Accessibility permission, which is what keeps
    /// this app requiring none at all.
    @discardableResult
    static func reveal(_ ancestors: [Int32]) -> Bool {
        guard case .owner(let app) = resolve(ancestors), let bundleID = app.bundleID else {
            return false
        }
        // Off the main thread: spawning a process is milliseconds, and this
        // runs from a click on a panel that must not stutter.
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // argv, never a shell. The bundle id comes from LaunchServices
            // rather than any payload, and this keeps that true regardless.
            process.arguments = ["-b", bundleID]
            try? process.run()
        }
        return true
    }
}
```

- [ ] **Step 2: Verify it builds**

```bash
swift build
```

Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeIslandApp/SessionOwner.swift
git commit -m "Raise a session's terminal with open, the one call that works"
```

---

### Task 5: The reveal row

**Files:**
- Modify: `Sources/ClaudeIslandApp/IslandViewModel.swift`
- Modify: `Sources/ClaudeIslandApp/IslandContentViews.swift`
- Modify: `Sources/ClaudeIslandApp/SelfTest.swift`

**Interfaces:**
- Consumes: `SessionOwner.resolve/reveal` from Task 4, `Session.ownerPIDs` from Task 2.
- Produces: `IslandViewModel.owner(for:) -> OwnerResolution.Outcome`, `IslandViewModel.revealOwner(of:)`, and `RevealRow`.

- [ ] **Step 1: Add the cached resolution to the view model**

In `Sources/ClaudeIslandApp/IslandViewModel.swift`, add:

```swift
    /// Resolved owners, keyed by session id.
    ///
    /// Cached because the row's *label* names the app, so resolution has to
    /// happen to draw rather than only to click, and `body` re-runs far too
    /// often to ask the process table each time.
    ///
    /// Refreshed only while the expanded card is open. Idle CPU is 0.000% with
    /// no sessions and this must not be what changes that — nothing is on
    /// screen to label when the card is shut.
    private var ownerCache: [String: OwnerResolution.Outcome] = [:]

    func owner(for session: Session) -> OwnerResolution.Outcome {
        ownerCache[session.id] ?? .unknown
    }

    /// Recompute owners for every tracked session. Call on snapshot change and
    /// on tick, both gated on the card being open.
    func refreshOwners() {
        guard mode == .expanded else { return }
        var next: [String: OwnerResolution.Outcome] = [:]
        for session in allSessions {
            next[session.id] = SessionOwner.resolve(session.ownerPIDs)
        }
        ownerCache = next
    }

    /// Raise the session's terminal and dismiss the card.
    ///
    /// Dismissing is the point rather than a courtesy: a card left floating
    /// over the app you just jumped to sits on top of the thing you went there
    /// to read.
    func revealOwner(of session: Session) {
        SessionOwner.reveal(session.ownerPIDs)
        unpin()
    }
```

`unpin()` (line 718) is the existing dismissal — `mode` is computed and reads
`isPinnedOpen`, so there is no mode to assign.

Call `refreshOwners()` from exactly three places:

1. At the end of `apply(_ snapshot: HUDSnapshot)` (line 731), after the
   selection-pruning block — a new snapshot can add or drop sessions.
2. In `togglePinned()` (line 713), after `syncTicker()` — this is the click that
   opens the card, and the guard inside `refreshOwners` makes the closing click
   a no-op.
3. In the tick timer closure (line 819), beside `self?.tick = Date()`, so a
   terminal quitting while the card is open is noticed within a second.

- [ ] **Step 2: Add the row view**

In `Sources/ClaudeIslandApp/IslandContentViews.swift`, add beside `AnswerButton`:

```swift
/// The one control on this card that takes you somewhere else.
///
/// Always rendered, in every state, and never hidden. The card is sized across
/// *all* sessions so that browsing the switcher never resizes it — a row that
/// appeared for one session and vanished for another would reflow the whole HUD
/// on every click, which is the bug two --selftest checks exist to catch. Hence
/// a fourth label rather than an absent row.
struct RevealRow: View {
    let session: Session
    @Bindable var model: IslandViewModel

    var body: some View {
        Group {
            switch model.owner(for: session) {
            case .owner(let app):
                Button {
                    model.revealOwner(of: session)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 8, weight: .bold))
                        // Names the destination rather than saying "Reveal":
                        // at app-level granularity that name is the whole
                        // promise being made.
                        Text("Reveal in \(app.name)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(IslandPalette.running))
                }
                .buttonStyle(.plain)

            case .noOwningApp:
                unavailable("background job — no terminal")
            case .gone:
                unavailable("terminal has quit")
            case .unknown:
                unavailable("terminal unknown")
            }
        }
        .frame(height: IslandViewModel.revealRowHeight, alignment: .leading)
    }

    /// Disabled with a reason rather than hidden, matching how this card
    /// already refuses to answer two simultaneous prompts and says why. A
    /// hidden control and a broken one look identical; a labelled one does not.
    private func unavailable(_ reason: String) -> some View {
        Text(reason)
            .font(.system(size: 8.5))
            .foregroundStyle(IslandPalette.tertiary)
            .lineLimit(1)
    }
}
```

- [ ] **Step 3: Reserve the height and place the row**

In `IslandViewModel`, beside the other body-height constants (around line 185):

```swift
    /// Fixed, because the reveal row has four states of differing natural
    /// height and the card must not resize as the selection moves between them.
    static let revealRowHeight: CGFloat = 20
```

Add `revealRowHeight` to `expandedChromeHeight` so the card grows by exactly one row.

Place the row in `ExpandedContent`, directly after `MetaLine(session: session, tick: model.tick)`:

```swift
                RevealRow(session: session, model: model)
                    .padding(.top, 5)
```

Add the same 5pt to `expandedChromeHeight` alongside `revealRowHeight`.

- [ ] **Step 4: Add self-test checks**

In `Sources/ClaudeIslandApp/SelfTest.swift`, beside `frontmostMuteChecks`, add:

```swift
    /// The four reveal states, driven through `OwnerResolution` rather than the
    /// live process table so the result does not depend on what is running
    /// while the harness does.
    ///
    /// Deliberately does not fire a real activation: `open` yanks the frontmost
    /// app, and the focus checks running beside this one would fail as a direct
    /// result.
    private static func revealStateChecks(_ checks: inout [Check]) {
        let app = OwnerResolution.AppInfo(
            pid: 1797, bundleID: "com.microsoft.VSCode", name: "Visual Studio Code",
            isRegular: true)
        let helper = OwnerResolution.AppInfo(
            pid: 1927, bundleID: "com.microsoft.VSCode.helper", name: "Code Helper",
            isRegular: false)

        let owner = OwnerResolution.resolve(
            [4368, 1927, 1797], isRunning: { _ in true },
            lookup: { $0 == 1797 ? app : ($0 == 1927 ? helper : nil) })
        checks.append(
            Check(
                name: "reveal resolves past helpers to the app",
                passed: owner == .owner(app),
                detail: "\(owner)"))

        let background = OwnerResolution.resolve(
            [7518], isRunning: { _ in true }, lookup: { _ in nil })
        checks.append(
            Check(
                name: "a background job reports no owning app",
                passed: background == .noOwningApp, detail: "\(background)"))

        let gone = OwnerResolution.resolve(
            [4368], isRunning: { _ in false }, lookup: { _ in nil })
        checks.append(
            Check(name: "a dead chain reports gone", passed: gone == .gone, detail: "\(gone)"))

        let unknown = OwnerResolution.resolve(
            [], isRunning: { _ in false }, lookup: { _ in nil })
        checks.append(
            Check(
                name: "no ancestry reports unknown", passed: unknown == .unknown,
                detail: "\(unknown)"))
    }
```

Call it beside the existing `frontmostMuteChecks(&checks)` at line 570.

- [ ] **Step 5: Build and run the self-test**

Clear any forced mode first — a leftover dev pin fails around a dozen mode checks and reads exactly like a regression:

```bash
swift build -c release && ./Scripts/bundle.sh
./dist/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --selftest
```

Expected: previously-passing checks still pass, plus 4 new ones. Run with the screen unlocked — a lock screen puts a full-screen `loginwindow` layer above everything and three focus checks report as skipped.

- [ ] **Step 6: Look at it**

The open tiers cannot be synthesised without Accessibility permission, so pin the tier to see the row:

```bash
./dist/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --force-mode expanded
```

Confirm the row renders, the label names a real app, and switching between sessions in the list does not change the card's height. **Then clear the pin** — leaving it set fails most of `--selftest`'s mode checks.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeIslandApp/IslandViewModel.swift Sources/ClaudeIslandApp/IslandContentViews.swift Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "Offer the session's terminal from the expanded card"
```

---

### Task 6: Make the frontmost mute exact

**Files:**
- Modify: `Sources/ClaudeIslandApp/AppController.swift:337-362`
- Modify: `Sources/ClaudeIslandCore/TerminalApps.swift:1-26`
- Modify: `Sources/ClaudeIslandApp/SelfTest.swift:1047`

**Interfaces:**
- Consumes: `SessionOwner.resolve` from Task 4.
- Produces: `AppController.rings(_:under:frontmost:owner:)` — the `owner` parameter defaults to `nil`, so all eight existing call sites keep compiling and keep testing the fallback.

- [ ] **Step 1: Widen the decision**

Replace `AppController.rings(_:under:frontmost:)`:

```swift
    /// Whether a cue is allowed to ring right now.
    ///
    /// `owner` is this session's own app, when the process ancestry resolved to
    /// one. Given it, the frontmost check stops being a guess: mute exactly
    /// when you are looking at *this* session's terminal, rather than whenever
    /// any terminal happens to be in front. Without it — a background job, a
    /// tmux server, an SSH session — it falls back to the old heuristic, which
    /// is the best available answer for a session that has no app at all.
    static func rings(
        _ cue: SoundCue, under settings: IslandSettings, frontmost bundleID: String?,
        owner ownerBundleID: String? = nil
    ) -> Bool {
        guard !settings.doNotDisturb, settings[cue].enabled else { return false }
        guard settings.muteWhileTerminalFrontmost else { return true }
        if let owner = ownerBundleID { return bundleID != owner }
        return !TerminalApps.matches(bundleID: bundleID)
    }
```

- [ ] **Step 2: Pass the session's owner at the call site**

Change the private helper at line 337 to take the session:

```swift
    private func rings(_ cue: SoundCue, for session: Session) -> Bool {
        let owner: String? =
            if case .owner(let app) = SessionOwner.resolve(session.ownerPIDs) {
                app.bundleID
            } else {
                nil
            }
        return Self.rings(
            cue, under: settings.current,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            owner: owner)
    }
```

and its caller at line 320, which already has `session` in scope:

```swift
                rings(cue, for: session)
```

Resolving here rather than reading the view model's cache is deliberate: this runs a handful of times a minute at worst, on the edge into a state, and a cached answer is one more thing that can be stale at the exact moment it decides whether you hear something — the same reasoning the existing comment gives for asking the workspace live.

- [ ] **Step 3: Extend the self-test mute checks**

Append to `frontmostMuteChecks` (SelfTest.swift:1047). It already declares
`var on = IslandSettings()` with `on.muteWhileTerminalFrontmost = true` — reuse
that binding rather than shadowing it, and note `IslandSettings` has no
memberwise initialiser for this flag:

```swift
        // The upgrade: a session whose own terminal is in front goes quiet,
        // while a session running in a *different* terminal still rings. The
        // old heuristic could not tell those apart and silenced both.
        checks.append(
            Check(
                name: "an owned session mutes only for its own terminal",
                passed: !AppController.rings(
                    .done, under: on, frontmost: "com.microsoft.VSCode",
                    owner: "com.microsoft.VSCode")
                    && AppController.rings(
                        .done, under: on, frontmost: "com.apple.Terminal",
                        owner: "com.microsoft.VSCode"),
                detail: "own-terminal mute vs other-terminal ring"))
```

- [ ] **Step 4: Rewrite the TerminalApps header**

Replace the paragraph in `Sources/ClaudeIslandCore/TerminalApps.swift` beginning "**This is a heuristic, and it is worth being blunt about what it cannot do.**" with:

```
/// **This is the fallback, and only the fallback.** A session whose process
/// ancestry resolved to an app is matched against *that* app exactly — see
/// `OwnerResolution` and `AppController.rings(_:under:frontmost:owner:)`. This
/// list is what remains for sessions that have no owning app to resolve: a
/// daemon-hosted background job, a tmux server, a session on the far end of an
/// SSH link.
///
/// For those it is still a guess, and the guess is still lopsided: a session in
/// a tmux client that is not frontmost goes on ringing, and an unrelated
/// terminal in front silences one it has nothing to do with. Both errors fall
/// in the harmless direction — a missing chime, never a missing alert — and the
/// setting is off by default.
```

Also update the sentence in the type's opening paragraph that claims "nothing says which app a given session belongs to", since that is now only true of the sessions this list still serves.

- [ ] **Step 5: Build, test, self-test**

```bash
swift build && swift run ClaudeIslandTests
swift build -c release && ./Scripts/bundle.sh
./dist/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --selftest
```

Expected: all tests pass; self-test count up by 5 from Task 5's total.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeIslandApp/AppController.swift Sources/ClaudeIslandCore/TerminalApps.swift Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "Mute for the session's own terminal, not for any terminal"
```

---

### Task 7: Fixture, docs, and end-to-end verification

**Files:**
- Create: `Fixtures/ancestry.jsonl`
- Modify: `README.md`

**Interfaces:** none produced; this task closes the loop.

- [ ] **Step 1: Add the replay fixture**

Create `Fixtures/ancestry.jsonl` — pids chosen to be implausible as live processes so a replay never resolves to a real app:

```
{"session_id":"anc-1","hook_event_name":"SessionStart","cwd":"/Users/you/project","_island_pids":[999001,999002,999003]}
{"session_id":"anc-1","hook_event_name":"UserPromptSubmit","_delayMs":200}
{"session_id":"anc-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"swift build"},"_delayMs":400,"_island_pids":[999001,999002,999003]}
{"session_id":"anc-1","hook_event_name":"PostToolUse","tool_name":"Bash","_delayMs":900}
{"session_id":"anc-1","hook_event_name":"Stop","_delayMs":300}
```

The second, fourth and fifth lines deliberately omit the field, so a replay proves the ancestry survives envelopes that do not carry it.

- [ ] **Step 2: Run the replay**

```bash
swift build -c release && ./Scripts/bundle.sh
./dist/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --replay Fixtures/ancestry.jsonl
```

Expected: completes with no error and no dropped payloads.

- [ ] **Step 3: Document the activation finding**

Add to `README.md` under "Things worth knowing":

```markdown
**Three activation APIs return success and do nothing.** Clicking *Reveal in …*
raises the session's terminal by spawning `/usr/bin/open -b`, which looks like a
detour until you try the direct routes. Measured from the HUD's own position —
an accessory app that is not itself frontmost:

| call | result |
|---|---|
| `NSRunningApplication.activate()` | returns `true`, frontmost unchanged |
| `NSRunningApplication.activate(from:options:)` | frontmost unchanged |
| `NSWorkspace.openApplication(activates: true)` | completes with no error, frontmost unchanged |
| `/usr/bin/open -b <bundleID>` | **activates** |

macOS 14's cooperative activation rules stop a background app raising another
in-process, and every one of those calls reports success anyway. `open` is a
trusted LaunchServices helper and is honoured. It also needs no Automation or
Accessibility permission, which is what keeps this app requiring none at all —
and it is why the jump stops at the app rather than the tab: tab selection means
AppleScript per terminal and a TCC prompt, for something VS Code's integrated
terminal could not offer anyway.

Which app a session belongs to comes from process ancestry, not from the hook
payload: the client walks `getppid()` up to eight hops with `sysctl` and splices
the chain into the payload as `_island_pids` — a byte-level edit over the
leading `{`, never a parse, because forwarding the payload verbatim is what
keeps that binary Foundation-free. The HUD takes the first ancestor that is a
*regular* application, which steps over helper processes such as VS Code's
`Code Helper` without needing to know any app by name.

Not every session has a terminal. A `claude daemon run` host has parent pid 1
and no tty, and so do tmux servers and the far end of an SSH link; those resolve
to no owning app and the card says so rather than jumping somewhere wrong.
```

Also update the "Interaction" section's **Expanded** paragraph to mention the row, and the measured-behaviour table's test and self-test counts.

- [ ] **Step 4: Verify against a real session, end to end**

```bash
./dist/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --selftest
```

Then, with the installed app running and hooks installed, start a Claude Code session in a terminal, click the island to expand, and click *Reveal in …*. Expected: that terminal comes forward, the card dismisses, and no new window is created.

Do **not** run the worktree build alongside the installed app — the second instance steals the socket. Either test with the installed app after installing this build, or quit the installed one first.

- [ ] **Step 5: Commit**

```bash
git add Fixtures/ancestry.jsonl README.md
git commit -m "Record how a session finds its way back to its terminal"
```

---

## Self-Review

**Spec coverage.** Ancestry capture → Task 1. Splice edges (`{}`, non-object, key preservation) → Task 1 Step 6. Envelope decode incl. malformed → Task 1/2. Ancestry not cleared by an omitting envelope → Task 2. Pure walk + four outcomes → Task 3. `open -b` and the measured API table → Task 4. Always-rendered constant-height row with four labels → Task 5. Re-resolve at click time so a quit app is not relaunched → Task 4 `reveal`. Mute upgrade with fallback → Task 6. Fixture, README, manual check → Task 7. Non-goals (tab selection, unbundled apps) are enforced in Task 3's bundle-id test and Task 4's guard.

**Type consistency.** `ancestorPIDs` is the envelope field throughout; `ownerPIDs` is the session field throughout; `OwnerResolution.resolve(_:isRunning:lookup:)` and `SessionOwner.resolve(_:)`/`reveal(_:)` are used with those exact signatures in Tasks 5 and 6. `AppInfo` carries `pid`/`bundleID`/`name`/`isRegular` everywhere it appears.

**Line references verified against the tree at plan time:** `IslandViewModel.togglePinned()` 713, `unpin()` 718, `apply(_:)` 731, tick timer 819, `expandedChromeHeight` 244; `AppController.rings` 337–362 with its caller at 320; `SelfTest.frontmostMuteChecks` 1047, called at 570. Re-grep if earlier tasks have shifted them.

**One thing the plan cannot settle in advance.** `expandedChromeHeight` (IslandViewModel:244) is a composed constant; Task 5 Step 3 adds `revealRowHeight + 5` to it, but the exact expression there was not read while planning. Open it, add the two terms to whatever sum is present, and confirm with the `--force-mode expanded` check in Step 6 that the card grew by exactly one row and does not resize as the selection changes.
