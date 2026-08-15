import ClaudeIslandCore
import Foundation

/// Owners are reported alive unless a test says otherwise, so no case here
/// depends on which pids happen to exist on the machine running it.
///
/// The job store is stubbed empty for the same reason: the shipped default
/// reads `~/.claude/jobs`, and letting it through would make these cases depend
/// on which background sessions the machine running them happens to have.
private func makeStore(
    _ clock: ClockBox,
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = { _ in true },
    jobState: @escaping @Sendable (String) -> JobState? = { _ in nil }
) -> (SessionStore, VirtualScheduler) {
    let scheduler = VirtualScheduler()
    return (
        SessionStore(
            scheduler: scheduler, now: { clock.value }, isProcessAlive: isProcessAlive,
            jobState: jobState),
        scheduler
    )
}

func registerSessionStoreTests() {
    suite("SessionStore") {

        test("Concurrent sessions are tracked independently") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)

            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, cwd: "/w/a", toolName: "Read",
                    receivedAt: base))
            await store.ingest(
                HookEnvelope(
                    sessionID: "b", event: .preToolUse, cwd: "/w/b", toolName: "Bash",
                    receivedAt: base.addingTimeInterval(1)))

            await expectEqual(await store.allSessions().count, 2)
            await expectEqual(await store.session("a")?.cwd, "/w/a")
            await expectEqual(await store.session("b")?.cwd, "/w/b")
        }

        test("The most recently active session is primary") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base))
            await store.ingest(
                HookEnvelope(
                    sessionID: "b", event: .preToolUse, toolName: "Bash",
                    receivedAt: base.addingTimeInterval(5)))

            let snap = await store.currentSnapshot()
            await expectEqual(snap.primary?.id, "b")
            await expectEqual(snap.others.map(\.id), ["a"])
            await expectEqual(snap.sessionCount, 2)
        }

        test("A permission prompt outranks a more recent session") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)

            await store.ingest(
                HookEnvelope(
                    sessionID: "b", event: .permissionRequest, toolName: "Write", receivedAt: base))
            // Session A then does something newer. B must stay on screen.
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read",
                    receivedAt: base.addingTimeInterval(30)))

            let snap = await store.currentSnapshot()
            await expectEqual(snap.primary?.id, "b")
            await expectEqual(snap.primary?.state.isAlert, true)
        }

        // The mirror of the check above. A permission prompt is the one thing
        // allowed to jump the queue; an idle nudge must not, because it fires
        // after a session has simply sat unattended and then stays set until you
        // come back. Ranking it up would pin the HUD to a session doing nothing
        // while another was still working.
        test("An idle nudge never outranks a working session") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)

            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base))
            // The nudge is newer, and still must not take the slot.
            await store.ingest(
                HookEnvelope(
                    sessionID: "b", event: .notification,
                    message: "Claude is waiting for your input",
                    receivedAt: base.addingTimeInterval(30)))

            let snap = await store.currentSnapshot()
            await expectEqual(snap.primary?.id, "a")
            await expectEqual(snap.others.first?.state, .idle(waitingOnUser: true))
        }

        test("prompting advances to thinking only when nothing superseded it") {
            let clock = ClockBox(now: base)
            let (store, scheduler) = makeStore(clock)

            await store.ingest(
                HookEnvelope(sessionID: "a", event: .userPromptSubmit, receivedAt: base))
            await expectEqual(await store.session("a")?.state, .prompting)

            clock.value = base.addingTimeInterval(Timings.promptingFlash)
            await scheduler.advance(to: clock.value)
            await expectEqual(await store.session("a")?.state, .thinking)
        }

        test("A superseding event cancels a pending timed transition") {
            let clock = ClockBox(now: base)
            let (store, scheduler) = makeStore(clock)

            await store.ingest(
                HookEnvelope(sessionID: "a", event: .userPromptSubmit, receivedAt: base))
            // A tool starts before the flash expires.
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Bash",
                    receivedAt: base.addingTimeInterval(0.2)))

            clock.value = base.addingTimeInterval(5)
            await scheduler.advance(to: clock.value)

            guard case .running = await store.session("a")?.state else {
                await fail("a stale timer clobbered a newer state")
                return
            }
        }

        test("Error decays back to thinking") {
            let clock = ClockBox(now: base)
            let (store, scheduler) = makeStore(clock)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .postToolUseFailure, toolName: "Bash", receivedAt: base))
            await expectEqual(await store.session("a")?.state, .error("Bash failed"))

            clock.value = base.addingTimeInterval(Timings.errorDecay)
            await scheduler.advance(to: clock.value)
            await expectEqual(await store.session("a")?.state, .thinking)
        }

        test("SessionEnd removes the session after the fade") {
            let clock = ClockBox(now: base)
            let (store, scheduler) = makeStore(clock)
            await store.ingest(HookEnvelope(sessionID: "a", event: .sessionEnd, receivedAt: base))
            await expect(await store.session("a") != nil)

            clock.value = base.addingTimeInterval(Timings.sessionEndFade)
            await scheduler.advance(to: clock.value)
            await expect(await store.session("a") == nil)
            await expect(await store.currentSnapshot().isDormant)
        }

        test("Sessions expire after 30 minutes of silence") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base))
            await store.ingest(
                HookEnvelope(
                    sessionID: "fresh", event: .preToolUse, toolName: "Read",
                    receivedAt: base.addingTimeInterval(Timings.sessionExpiry)))

            clock.value = base.addingTimeInterval(Timings.sessionExpiry + 1)
            await store.expireStale()

            await expect(await store.session("a") == nil, "stale session survived")
            await expect(await store.session("fresh") != nil, "fresh session was expired")
        }

        test("Snapshots are published on every change") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            let stream = await store.snapshots()

            let collected = Task { () -> [Int] in
                var counts: [Int] = []
                for await snap in stream {
                    counts.append(snap.sessionCount)
                    if counts.count == 3 { break }
                }
                return counts
            }

            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base))
            await store.ingest(
                HookEnvelope(
                    sessionID: "b", event: .preToolUse, toolName: "Read",
                    receivedAt: base.addingTimeInterval(1)))

            // Initial snapshot, then one per ingest.
            await expectEqual(await collected.value, [0, 1, 2])
            await store.shutdown()
        }

        test("A dormant snapshot wants no animation") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await expectEqual(await store.currentSnapshot().wantsAnimation, false)

            await store.ingest(HookEnvelope(sessionID: "a", event: .stop, receivedAt: base))
            await expectEqual(
                await store.currentSnapshot().wantsAnimation, false,
                "a finished session must not keep the HUD animating")

            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Bash",
                    receivedAt: base.addingTimeInterval(1)))
            await expect(await store.currentSnapshot().wantsAnimation)
        }

        test("Transcript updates decorate without touching state") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Bash", receivedAt: base))
            let before = await store.session("a")?.state

            var tokens = TokenStats()
            tokens.contextTokens = 51_333
            tokens.cumulativeOutput = 722
            await store.applyTranscript(
                TranscriptUpdate(sessionID: "a", model: "claude-opus-5", tokens: tokens))

            await expectEqual(await store.session("a")?.state, before)
            await expectEqual(await store.session("a")?.model, "claude-opus-5")
            await expectEqual(await store.session("a")?.tokens.contextTokens, 51_333)
        }

        test("A title from the transcript becomes the session's label") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .sessionStart, cwd: "/Users/dev/code/widgets",
                    receivedAt: base))
            // Until the first turn generates one, the folder is the label.
            await expectEqual(await store.session("a")?.displayName, "widgets")

            await store.applyTranscript(
                TranscriptUpdate(
                    sessionID: "a", model: nil, tokens: TokenStats(),
                    aiTitle: "Fix scroll functionality issue"))
            await expectEqual(
                await store.session("a")?.displayName, "Fix scroll functionality issue")

            // A later update carrying no title must not clear the one we have —
            // most transcript reads are token-only and would blank the label.
            await store.applyTranscript(
                TranscriptUpdate(sessionID: "a", model: nil, tokens: TokenStats()))
            await expectEqual(
                await store.session("a")?.displayName, "Fix scroll functionality issue")
        }

        test("A transcript update for an unknown session is ignored") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await store.applyTranscript(
                TranscriptUpdate(sessionID: "ghost", model: "m", tokens: TokenStats()))
            await expect(await store.allSessions().isEmpty)
        }

        // A background subagent outliving its parent is ordinary here — the
        // reducer's own notes record one finishing 3m23s after the parent's
        // Stop. Landing inside the five-second fade must not strand the
        // session on the HUD until the 30-minute sweep.
        test("A late event during the fade still removes the ended session") {
            let clock = ClockBox(now: base)
            let (store, scheduler) = makeStore(clock)
            await store.ingest(HookEnvelope(sessionID: "a", event: .sessionEnd, receivedAt: base))

            clock.value = base.addingTimeInterval(1)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .subagentStop, receivedAt: clock.value))

            clock.value = base.addingTimeInterval(Timings.sessionEndFade + 1)
            await scheduler.advance(to: clock.value)
            await expect(
                await store.session("a") == nil,
                "ended session survived the fade because a late event bumped the revision")
        }

        // Once SessionEnd has been honoured the session is over. A stray hook
        // arriving afterwards has no session to decorate, and the reducer's
        // `input ?? Session(...)` mints a fresh one — a zombie with no cwd,
        // model or title that then holds the HUD for a further 30 minutes.
        test("A stray event after removal does not resurrect the session") {
            let clock = ClockBox(now: base)
            let (store, scheduler) = makeStore(clock)
            await store.ingest(HookEnvelope(sessionID: "a", event: .sessionEnd, receivedAt: base))

            clock.value = base.addingTimeInterval(Timings.sessionEndFade)
            await scheduler.advance(to: clock.value)
            await expect(await store.session("a") == nil, "fade did not remove the session")

            clock.value = base.addingTimeInterval(90)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .notification,
                    message: "Claude is waiting for your input", receivedAt: clock.value))

            await expect(
                await store.session("a") == nil,
                "a stray post-end event resurrected the session as a brand-new one")
        }

        // The other half of the fade guard: reuse of the id is exactly what
        // /clear and --resume do, and that must still cancel the removal.
        test("A session restarted during the fade keeps its place") {
            let clock = ClockBox(now: base)
            let (store, scheduler) = makeStore(clock)
            await store.ingest(HookEnvelope(sessionID: "a", event: .sessionEnd, receivedAt: base))

            clock.value = base.addingTimeInterval(1)
            await store.ingest(
                HookEnvelope(sessionID: "a", event: .sessionStart, receivedAt: clock.value))

            clock.value = base.addingTimeInterval(Timings.sessionEndFade + 1)
            await scheduler.advance(to: clock.value)
            await expect(await store.session("a") != nil, "a restarted session was removed anyway")
        }

        test("A session whose owner has exited is swept without the idle wait") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock, isProcessAlive: { _ in false })
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base,
                    ancestorPIDs: [4242]))

            clock.value = base.addingTimeInterval(Timings.expirySweepInterval)
            await store.expireStale()
            await expect(await store.session("a") == nil, "a dead owner's session survived")
        }

        test("A session whose owner is still running is left alone") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock, isProcessAlive: { _ in true })
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base,
                    ancestorPIDs: [4242]))

            clock.value = base.addingTimeInterval(Timings.expirySweepInterval)
            await store.expireStale()
            await expect(await store.session("a") != nil, "a live session was swept")
        }

        // Replayed traces and synthetic events carry no ancestry. Unknown must
        // not be read as dead, or --replay sweeps its own fixtures.
        test("A session with no known owner is never swept for liveness") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock, isProcessAlive: { _ in false })
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base))

            clock.value = base.addingTimeInterval(Timings.expirySweepInterval)
            await store.expireStale()
            await expect(
                await store.session("a") != nil, "a session with no ancestry was swept as dead")
        }

        // Idle expiry is not an ending. The next hook for a swept session means
        // the user came back to a terminal that was open all along, so it has to
        // be re-adopted rather than refused as a ghost.
        test("An idle-swept session is re-adopted when it speaks again") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .preToolUse, toolName: "Read", receivedAt: base))

            clock.value = base.addingTimeInterval(Timings.sessionExpiry + 1)
            await store.expireStale()
            await expect(await store.session("a") == nil, "the idle session was not swept")

            await store.ingest(
                HookEnvelope(
                    sessionID: "a", event: .userPromptSubmit, receivedAt: clock.value))
            await expect(
                await store.session("a") != nil, "a returning user's session was refused")
        }
    }
}
