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

/// The cues a run of events would actually ring, deduplicated on the edge the
/// way `AppController.playSoundCues` does it: a cue rings when it differs from
/// the one the session was last observed in, so staying in a cue is silent and
/// leaving and re-entering it is not.
///
/// Every sequence here starts from a cue-less event, matching the app's other
/// rule — a session's first appearance seeds the tracking silently rather than
/// ringing for state it was already in.
func rungCues(_ events: [HookEnvelope]) -> [SoundCue] {
    var session: Session?
    var last: SoundCue?
    var rung: [SoundCue] = []
    for event in events {
        session = SessionReducer.apply(event, to: session).session
        let cue = session?.state.soundCue
        if let cue, cue != last { rung.append(cue) }
        last = cue
    }
    return rung
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

        // A background subagent can outlive the parent's turn by minutes. The
        // SubagentStop that lands afterwards must not resurrect the session:
        // nothing further arrives to clear it, so the HUD would read "thinking"
        // until the 30-minute expiry. Observed in the wild — Stop at 21:58:52,
        // SubagentStop at 22:02:15, still "thinking" when the log ended.
        test("A SubagentStop after Stop does not resurrect a finished session") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Task"), to: nil).session
            s = SessionReducer.apply(env(.stop, at: 1), to: s).session
            await expectEqual(s.state, .done)

            s = SessionReducer.apply(env(.subagentStop, at: 200), to: s).session
            await expectEqual(s.state, .done, "a late subagent flipped a done session to thinking")
        }

        test("A SubagentStop does not clear an idle nudge") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Task"), to: nil).session
            s = SessionReducer.apply(
                env(.notification, message: "Claude is waiting for your input", at: 1), to: s
            ).session
            await expectEqual(s.state, .idle(waitingOnUser: true))

            s = SessionReducer.apply(env(.subagentStop, at: 200), to: s).session
            await expectEqual(s.state, .idle(waitingOnUser: true))
        }

        test("A SubagentStop does not clear a live permission prompt") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Task"), to: nil).session
            s = SessionReducer.apply(env(.permissionRequest, tool: "Bash", at: 1), to: s).session
            await expect(s.state.isAlert)

            s = SessionReducer.apply(env(.subagentStop, at: 2), to: s).session
            await expect(s.state.isAlert, "a late subagent dismissed a pending permission")
        }

        test("An idle nudge does not downgrade a live permission prompt or question") {
            var s = SessionReducer.apply(env(.permissionRequest, tool: "Bash"), to: nil).session
            s = SessionReducer.apply(
                env(.notification, message: "Claude is waiting for your input", at: 1), to: s
            ).session
            await expect(s.state.isAlert, "an idle nudge downgraded a live permission prompt")

            s = SessionReducer.apply(env(.preToolUse, tool: "AskUserQuestion", at: 2), to: s).session
            s = SessionReducer.apply(
                env(.notification, message: "Claude is waiting for your input", at: 3), to: s
            ).session
            guard case .running(let activity) = s.state else {
                await fail("an idle nudge downgraded a live question, got \(s.state)")
                return
            }
            await expectEqual(activity.kind, .question)
        }

        test("An idle nudge still applies once nothing is pending") {
            var s = SessionReducer.apply(env(.preToolUse, tool: "Task"), to: nil).session
            s = SessionReducer.apply(
                env(.notification, message: "Claude is waiting for your input", at: 1), to: s
            ).session
            await expectEqual(s.state, .idle(waitingOnUser: true))
        }

        // A turn is one Stop, however many tools it took to get there: the done
        // cue is set by Stop and SessionEnd alone, and a tool starting or
        // finishing lands on `running`/`thinking`, which carry no cue at all.
        test("Tool calls ring nothing; the turn they belong to rings once") {
            var turn = [env(.userPromptSubmit)]
            for i in 0..<20 {
                let at = TimeInterval(i * 2 + 1)
                turn.append(env(.preToolUse, tool: "Read", at: at))
                turn.append(env(.postToolUse, tool: "Read", at: at + 1))
            }
            await expectEqual(rungCues(turn), [], "a tool call rang on its own")

            turn.append(env(.stop, at: 100))
            await expectEqual(rungCues(turn), [.done])
        }

        // The nudge fires about a minute after a turn ends and says the session
        // is waiting for input — which `done` already said, from a real event
        // rather than matched prose. Left to overwrite it, every finished turn
        // the user did not answer straight away rang twice under two labels:
        // the finish, then a second chime a minute later carrying no new fact.
        test("The idle nudge after a finished turn does not ring a second time") {
            let turn = [
                env(.userPromptSubmit),
                env(.preToolUse, tool: "Read", at: 1),
                env(.postToolUse, tool: "Read", at: 2),
                env(.stop, at: 3),
                env(.notification, message: "Claude is waiting for your input", at: 63),
            ]
            await expectEqual(rungCues(turn), [.done], "the idle nudge re-rang a finished turn")

            let s = SessionReducer.apply(turn[4], to: SessionReducer.apply(turn[3], to: nil).session)
                .session
            await expectEqual(
                s.state, .done, "a nudge downgraded a finished turn to a generic idle reading")
        }

        // An interrupted turn fires no Stop at all, so the nudge is the only
        // thing that will ever settle the session — the case the waiting cue
        // exists for, and the one the guard above must not take away.
        test("The idle nudge still rings for a turn that never reported finishing") {
            let interrupted = [
                env(.userPromptSubmit),
                env(.preToolUse, tool: "Bash", at: 1),
                env(.notification, message: "Claude is waiting for your input", at: 61),
            ]
            await expectEqual(rungCues(interrupted), [.waiting])
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

        test("soundCue fires only for done, permission, and the idle nudge") {
            await expectEqual(SessionState.done.soundCue, .done)
            await expectEqual(SessionState.idle(waitingOnUser: true).soundCue, .waiting)
            await expectEqual(SessionState.idle(waitingOnUser: false).soundCue, nil)
            await expectEqual(SessionState.thinking.soundCue, nil)
            await expectEqual(SessionState.compacting.soundCue, nil)
            await expectEqual(SessionState.error("x").soundCue, nil)

            let ask = PermissionAsk(toolName: "Bash", kind: .bash, target: nil, since: base)
            await expectEqual(SessionState.awaitingPermission(ask).soundCue, .inputRequired)
        }

        test("A permission request carries the handle that answers it") {
            let store = SessionStore()
            await store.ingest(
                HookEnvelope(
                    sessionID: "answerable", event: .permissionRequest, toolName: "Bash",
                    receivedAt: base, decisionToken: 77))

            let session = try await require(await store.session("answerable"))
            guard case .awaitingPermission(let ask) = session.state else {
                return await expect(false, "expected awaitingPermission, got \(session.state)")
            }
            await expectEqual(ask.decisionToken, 77)
        }

        // Claude Code runs tool calls in parallel and fires a PermissionRequest
        // hook for each, but shows one dialog at a time. With two prompts live in
        // one session the card cannot know which one the terminal is showing, so
        // a press would risk approving the prompt the human is not looking at.
        // Refusing to answer either is the only safe reading.
        test("A prompt with a sibling waiting in the same session is not answerable") {
            let ask = PermissionAsk(
                toolName: "Bash", kind: .bash, target: "rm -rf /tmp/x", since: base,
                decisionToken: 12, siblingCount: 1)
            await expect(!ask.isAnswerable, "answered one of two indistinguishable prompts")
            await expectEqual(
                ask.decisionToken, 12, "the handle is still worth keeping for diagnostics")
        }

        test("A lone prompt is answerable") {
            let ask = PermissionAsk(
                toolName: "Bash", kind: .bash, target: "ls", since: base,
                decisionToken: 12, siblingCount: 0)
            await expect(ask.isAnswerable)
        }

        // `target` is clamped to 60 characters for the resting pill. Approving on
        // the strength of a truncated command is worse than walking to the
        // terminal, so an answerable prompt has to carry the whole thing.
        test("An answerable prompt keeps the whole command, not the pill summary") {
            let command =
                "docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "
                + "ghcr.io/example/deploy:latest --env production --confirm"
            let store = SessionStore()
            await store.ingest(
                HookEnvelope(
                    sessionID: "long", event: .permissionRequest, toolName: "Bash",
                    toolInput: .object(["command": .string(command)]),
                    receivedAt: base, decisionToken: 1))

            let session = try await require(await store.session("long"))
            guard case .awaitingPermission(let ask) = session.state else {
                return await expect(false, "expected awaitingPermission, got \(session.state)")
            }
            await expectEqual(ask.detail, command)
            await expect(
                (ask.target?.count ?? 0) < command.count, "the pill summary was not clamped")
        }

        // A prompt inferred from notification prose has no connection behind it,
        // so it must not offer an answer it cannot deliver.
        test("A permission prompt inferred from a notification is not answerable") {
            let store = SessionStore()
            await store.ingest(
                HookEnvelope(
                    sessionID: "prose", event: .notification,
                    message: "Claude needs your permission to use Bash", receivedAt: base))

            let session = try await require(await store.session("prose"))
            guard case .awaitingPermission(let ask) = session.state else {
                return await expect(false, "expected awaitingPermission, got \(session.state)")
            }
            await expectEqual(ask.decisionToken, nil)
        }

        // The terminal got there first: the prompt is settled, but no hook event
        // announces that, so the card has to stop offering to answer it.
        test("A withdrawn prompt stops being answerable but stays on screen") {
            let store = SessionStore()
            await store.ingest(
                HookEnvelope(
                    sessionID: "withdrawn", event: .permissionRequest, toolName: "Bash",
                    receivedAt: base, decisionToken: 99))
            await store.withdrawDecision(99)

            let session = try await require(await store.session("withdrawn"))
            guard case .awaitingPermission(let ask) = session.state else {
                return await expect(false, "expected awaitingPermission, got \(session.state)")
            }
            await expectEqual(ask.decisionToken, nil, "still offering to answer a settled prompt")
        }

        test("Withdrawing an unrelated token leaves a live prompt answerable") {
            let store = SessionStore()
            await store.ingest(
                HookEnvelope(
                    sessionID: "live", event: .permissionRequest, toolName: "Bash",
                    receivedAt: base, decisionToken: 5))
            await store.withdrawDecision(6)

            let session = try await require(await store.session("live"))
            guard case .awaitingPermission(let ask) = session.state else {
                return await expect(false, "expected awaitingPermission, got \(session.state)")
            }
            await expectEqual(ask.decisionToken, 5)
        }

        test("AskUserQuestion and ExitPlanMode sound like a permission prompt") {
            await expectEqual(ToolKind(toolName: "AskUserQuestion"), .question)
            await expectEqual(ToolKind(toolName: "ExitPlanMode"), .question)

            let question = ToolActivity(
                kind: .question, toolName: "AskUserQuestion", target: nil, startedAt: base)
            await expectEqual(SessionState.running(question).soundCue, .inputRequired)

            let bash = ToolActivity(kind: .bash, toolName: "Bash", target: nil, startedAt: base)
            await expectEqual(SessionState.running(bash).soundCue, nil, "an ordinary tool call rang")
        }

        test("Only idle and terminal states stop animating") {
            await expectEqual(SessionState.idle.wantsAnimation, false)
            await expectEqual(SessionState.done.wantsAnimation, false)
            await expectEqual(SessionState.error("x").wantsAnimation, false)
            await expect(SessionState.thinking.wantsAnimation)
            await expect(SessionState.compacting.wantsAnimation)
        }

        // An idle nudge is not an interruption. It fires once a session has sat
        // without input for a while and then stays set until you come back, so
        // treating it as "needs you" made the attention badge a tally of
        // sessions you had walked away from — drowning out the one state that
        // has an answer which unblocks work.
        test("Only a permission prompt counts as needing the user") {
            var s = SessionReducer.apply(
                env(.notification, message: "Claude is waiting for your input"), to: nil
            ).session
            await expectEqual(s.state, .idle(waitingOnUser: true))
            await expect(!s.state.needsUser, "an idle nudge was counted as needing the user")

            s = SessionReducer.apply(env(.permissionRequest, tool: "Bash", at: 1), to: s).session
            await expect(
                s.state.needsUser, "a permission prompt was not counted as needing the user")
        }

        test("displayName follows the terminal title: rename, ai title, folder, id") {
            var s = Session(id: "abcdef123456", startedAt: base)
            await expectEqual(s.displayName, "abcdef12")
            s.cwd = "/Users/dev/worktrees/feature-a"
            await expectEqual(s.displayName, "feature-a")
            s.aiTitle = "Do not truncate the branch name"
            await expectEqual(s.displayName, "Do not truncate the branch name")
            s.customTitle = "retry work"
            await expectEqual(s.displayName, "retry work")
        }

        test("An empty title falls through instead of blanking the label") {
            var s = Session(id: "abcdef123456", startedAt: base)
            s.cwd = "/Users/dev/worktrees/feature-a"
            s.customTitle = ""
            s.aiTitle = ""
            await expectEqual(s.displayName, "feature-a")
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
