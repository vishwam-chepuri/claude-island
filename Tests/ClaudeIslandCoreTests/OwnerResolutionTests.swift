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
