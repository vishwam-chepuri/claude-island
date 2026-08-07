import ClaudeIslandCore
import Foundation

let base = Date(timeIntervalSince1970: 1_700_000_000)

func env(
    _ event: HookEvent,
    session: String = "s1",
    tool: String? = nil,
    input: JSONValue? = nil,
    message: String? = nil,
    cwd: String? = "/Users/dev/code/widgets",
    at offset: TimeInterval = 0
) -> HookEnvelope {
    HookEnvelope(
        sessionID: session, event: event, cwd: cwd, toolName: tool, toolInput: input,
        message: message, receivedAt: base.addingTimeInterval(offset))
}

func registerStateMachineTests() {
    suite("Session state machine") {

        test("SessionStart resets derived state but keeps identity") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Bash"), to: nil).session
            await expect(!s.recentTools.isEmpty)
            s = SessionReducer.apply(env(.sessionStart, at: 1), to: s).session
            await expectEqual(s.state, .idle)
            await expect(s.recentTools.isEmpty)
            await expectEqual(s.subagentDepth, 0)
            await expectEqual(s.cwd, "/Users/dev/code/widgets")
        }

        test("UserPromptSubmit flashes prompting and asks for a follow-up timer") {
            let out = SessionReducer.apply(env(.userPromptSubmit), to: nil)
            await expectEqual(out.session.state, .prompting)
            await expectEqual(out.pending, [.promptingToThinking(after: Timings.promptingFlash)])
        }

        test("PreToolUse enters running and records the tool") {
            let out = SessionReducer.apply(
                env(.preToolUse, tool: "Bash", input: .object(["command": .string("ls -la")])),
                to: nil)
            guard case .running(let activity) = out.session.state else {
                await fail("expected running, got \(out.session.state)")
                return
            }
            await expectEqual(activity.kind, .bash)
            await expectEqual(activity.target, "ls -la")
            await expectEqual(out.session.recentTools.count, 1)
        }

        test("PostToolUse closes the tool and returns to thinking") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Read"), to: nil).session
            s = SessionReducer.apply(env(.postToolUse, tool: "Read", at: 2), to: s).session
            await expectEqual(s.state, .thinking)
            await expectEqual(s.recentTools.first?.endedAt, base.addingTimeInterval(2))
            await expectEqual(s.recentTools.first?.failed, false)
        }

        test("PostToolUseFailure marks error and decays back to thinking") {
            let s = SessionReducer.apply(env(.preToolUse, tool: "Bash"), to: nil).session
            let out = SessionReducer.apply(env(.postToolUseFailure, tool: "Bash", at: 1), to: s)
            await expectEqual(out.session.state, .error("Bash failed"))
            await expectEqual(out.session.recentTools.first?.failed, true)
            await expectEqual(out.pending, [.errorToThinking(after: Timings.errorDecay)])
        }

        test("PermissionRequest carries the tool and a sanitized target") {
            let out = SessionReducer.apply(
                env(
                    .permissionRequest, tool: "Bash",
                    input: .object(["command": .string("rm -rf ./build")])), to: nil)
            guard case .awaitingPermission(let ask) = out.session.state else {
                await fail("expected awaitingPermission, got \(out.session.state)")
                return
            }
            await expectEqual(ask.toolName, "Bash")
            await expectEqual(ask.target, "rm -rf ./build")
            await expect(out.session.state.isAlert)
        }

        test("A permission clears on the next event, whatever it is") {
            var s = SessionReducer.apply(env(.permissionRequest, tool: "Bash"), to: nil).session
            await expect(s.state.isAlert)
            // Approve path.
            s = SessionReducer.apply(env(.preToolUse, tool: "Bash", at: 1), to: s).session
            await expect(!s.state.isAlert)

            // Deny path: the user types something instead.
            s = SessionReducer.apply(env(.permissionRequest, tool: "Bash", at: 2), to: s).session
            await expect(s.state.isAlert)
            s = SessionReducer.apply(env(.userPromptSubmit, at: 3), to: s).session
            await expect(!s.state.isAlert)
        }

        test("Notification prose is classified conservatively") {
            await expectEqual(
                NotificationKind(message: "Claude needs your permission to use Bash"), .permission)
            await expectEqual(
                NotificationKind(message: "Claude is waiting for your input"), .idleNudge)
            await expectEqual(NotificationKind(message: "Some unrelated future message"), .other)
            await expectEqual(NotificationKind(message: nil), .other)
        }

        test("An unrecognized notification does not disturb a good state") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Bash"), to: nil).session
            let before = s.state
            s = SessionReducer.apply(env(.notification, message: "brand new prose", at: 1), to: s)
                .session
            await expectEqual(s.state, before)
        }

        test("An unknown future event never destroys state") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Bash"), to: nil).session
            let before = s.state
            s = SessionReducer.apply(env(.unknown("SomethingNew"), at: 1), to: s).session
            await expectEqual(s.state, before)
            await expectEqual(s.lastEventAt, base.addingTimeInterval(1))
        }

        test("Task pushes a subagent frame and SubagentStop pops it") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Task"), to: nil).session
            await expectEqual(s.subagentDepth, 1)
            await expect(s.isInSubagent)

            // The subagent's own tool events interleave into the parent stream.
            s = SessionReducer.apply(env(.preToolUse, tool: "Grep", at: 1), to: s).session
            await expectEqual(s.subagentDepth, 1)
            guard case .running(let t) = s.state else {
                await fail("expected running")
                return
            }
            await expectEqual(t.kind, .grep)

            s = SessionReducer.apply(env(.subagentStop, at: 2), to: s).session
            await expectEqual(s.subagentDepth, 0)
        }

        test("SubagentStop never drives depth negative") {
            let s = SessionReducer.apply(env(.subagentStop), to: nil).session
            await expectEqual(s.subagentDepth, 0)
        }

        test("SessionEnd schedules removal after the fade") {
            let out = SessionReducer.apply(env(.sessionEnd), to: nil)
            await expectEqual(out.session.state, .done)
            await expectEqual(out.session.endedAt, base)
            await expectEqual(out.pending, [.removeSession(after: Timings.sessionEndFade)])
        }

        test("recentTools is capped") {
            var s: Session?
            // Comfortably past the cap, so this keeps testing the cap rather
            // than the loop bound if the limit is ever raised again.
            for i in 0..<(Session.recentToolLimit + 5) {
                s = SessionReducer.apply(
                    env(.preToolUse, tool: "Read", at: TimeInterval(i)), to: s
                ).session
            }
            await expectEqual(s?.recentTools.count, Session.recentToolLimit)
            await expectEqual(
                s?.recentTools.first?.startedAt,
                base.addingTimeInterval(TimeInterval(Session.recentToolLimit + 4)),
                "the cap dropped the newest call instead of the oldest")
        }

        test("Only idle and terminal states stop animating") {
            await expectEqual(SessionState.idle.wantsAnimation, false)
            await expectEqual(SessionState.done.wantsAnimation, false)
            await expectEqual(SessionState.error("x").wantsAnimation, false)
            await expect(SessionState.thinking.wantsAnimation)
            await expect(SessionState.compacting.wantsAnimation)
        }

        test("displayName prefers session name, then cwd basename, then id") {
            var s = Session(id: "abcdef123456", startedAt: base)
            await expectEqual(s.displayName, "abcdef12")
            s.cwd = "/Users/dev/worktrees/feature-a"
            await expectEqual(s.displayName, "feature-a")
            s.sessionName = "retry work"
            await expectEqual(s.displayName, "retry work")
        }

        test("A payload with no session_id decodes to nil rather than throwing") {
            let data = Data(#"{"hook_event_name":"Stop","cwd":"/tmp"}"#.utf8)
            await expectEqual(try HookEnvelope.decode(data) == nil, true)
        }

        test("Unknown keys in a payload are ignored") {
            let data = Data(
                #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","brand_new_key":{"a":[1,2]}}"#
                    .utf8)
            let envelope = try await require(try HookEnvelope.decode(data))
            await expectEqual(envelope.event, .preToolUse)
            await expectEqual(envelope.toolName, "Bash")
        }
    }
}
