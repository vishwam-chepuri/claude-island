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

        // The ancestry is the one field that arrives over the socket rather than
        // being measured here, so it is the one that can carry a pid no process
        // ever had. `kill(0, 0)` and `kill(-1, 0)` are process-group signals,
        // not liveness probes — both would report an ancestor that is alive.
        test("Non-positive pids are dropped at the wire") {
            let json = Data(
                #"{"session_id":"w","hook_event_name":"Stop","_island_pids":[0,-1,1797]}"#.utf8)
            let env = try await require(try HookEnvelope.decode(json))
            await expectEqual(env.ancestorPIDs, [1797])
        }

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
    }
}
