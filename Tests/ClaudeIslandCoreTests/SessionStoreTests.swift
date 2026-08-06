import ClaudeIslandCore
import Foundation

private func makeStore(_ clock: ClockBox) -> (SessionStore, VirtualScheduler) {
    let scheduler = VirtualScheduler()
    return (SessionStore(scheduler: scheduler, now: { clock.value }), scheduler)
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

        test("A transcript update for an unknown session is ignored") {
            let clock = ClockBox(now: base)
            let (store, _) = makeStore(clock)
            await store.applyTranscript(
                TranscriptUpdate(sessionID: "ghost", model: "m", tokens: TokenStats()))
            await expect(await store.allSessions().isEmpty)
        }
    }
}
