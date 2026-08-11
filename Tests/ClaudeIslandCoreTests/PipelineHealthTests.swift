import ClaudeIslandCore
import Foundation

private let home = "/Users/someone"
private let socketPath = "\(home)/.claude-island/island.sock"

private func listening(lastEventAt: Date? = nil, sessions: Int = 0, statusline: Bool = false)
    -> PipelineHealth
{
    PipelineHealth(
        socket: .listening(path: socketPath), lastEventAt: lastEventAt, sessionCount: sessions,
        statuslineForwarding: statusline)
}

func registerPipelineHealthTests() {
    suite("Pipeline health") {

        // The whole reason the strip exists. Both of these draw an empty island,
        // and only one of them will ever stop being empty.
        test("A dead socket and a quiet one are not the same state") {
            let dead = PipelineHealth(
                socket: .failed(path: socketPath, reason: "bind() failed: Address already in use"))
            let quiet = listening()

            await expect(dead.level == .degraded, "a socket that never bound is degraded")
            await expect(quiet.level == .idle, "a bound socket with no traffic is merely idle")
            await expect(dead.headline != quiet.headline, "and they do not read the same")
        }

        test("A failed socket says why, and where") {
            let health = PipelineHealth(
                socket: .failed(path: socketPath, reason: "bind() failed: Address already in use"))
            let label = health.socketLabel(home: home)
            await expect(
                label.contains("Address already in use"),
                "the reason survives into the label: \(label)")
            await expect(
                label.contains("~/.claude-island/island.sock"), "as does the path: \(label)")
            await expect(health.explanation != nil, "a degraded pipeline explains itself")
        }

        // An idle pipeline reported as broken is this feature's own bug, pointed
        // the other way: it would send someone off to reinstall hooks that work.
        test("An idle pipeline is never described as an error") {
            let quiet = listening()
            await expectEqual(quiet.lastEventLabel(now: Date()), "never since launch")
            await expect(quiet.level != .degraded, "not degraded")
            await expect(
                quiet.socketLabel(home: home) == "Listening at ~/.claude-island/island.sock",
                "the socket row states plainly that it is up: \(quiet.socketLabel(home: home))")
        }

        test("The first envelope moves it from idle to healthy") {
            let now = Date()
            let live = listening(lastEventAt: now.addingTimeInterval(-3), sessions: 1)
            await expect(live.level == .healthy, "one arrival proves the whole path works")
            await expectEqual(live.lastEventLabel(now: now), "3s ago")
            await expect(live.explanation == nil, "and there is nothing left to explain")
        }

        // Silence after a real event is a quiet afternoon, not a fault. A strip
        // that went amber over lunch would be a worse liar than the empty island.
        test("A long silence after a real event stays healthy") {
            let now = Date()
            let health = listening(lastEventAt: now.addingTimeInterval(-4 * 3600))
            await expect(health.level == .healthy, "still healthy four hours on")
            await expectEqual(health.lastEventLabel(now: now), "4h 0m ago")
        }

        test("Elapsed labels coarsen the way a glance reads them") {
            await expectEqual(PipelineHealth.elapsedLabel(0), "just now")
            await expectEqual(PipelineHealth.elapsedLabel(0.9), "just now")
            await expectEqual(PipelineHealth.elapsedLabel(3), "3s ago")
            await expectEqual(PipelineHealth.elapsedLabel(59), "59s ago")
            await expectEqual(PipelineHealth.elapsedLabel(60), "1m ago")
            await expectEqual(PipelineHealth.elapsedLabel(3_599), "59m ago")
            await expectEqual(PipelineHealth.elapsedLabel(3_600), "1h 0m ago")
            await expectEqual(PipelineHealth.elapsedLabel(7_380), "2h 3m ago")
            // A sleep or an NTP correction can put the last event in the future.
            await expectEqual(PipelineHealth.elapsedLabel(-5), "just now")
        }

        // The one component here that is genuinely optional. Flagging it would
        // send people to fix the only thing on the strip that is not broken.
        test("A missing status line never degrades the pipeline") {
            let now = Date()
            let without = listening(lastEventAt: now, statusline: false)
            let with = listening(lastEventAt: now, statusline: true)
            await expect(without.level == .healthy, "healthy without the forward line")
            await expectEqual(without.level, with.level, "installing it changes no verdict")

            let dead = PipelineHealth(
                socket: .failed(path: socketPath, reason: "bind() failed"),
                statuslineForwarding: true)
            await expect(dead.level == .degraded, "and having it does not rescue a dead socket")
        }

        test("The socket path is shown as the user would type it") {
            await expectEqual(
                PipelineHealth.displayPath(socketPath, home: home),
                "~/.claude-island/island.sock")
            await expectEqual(
                PipelineHealth.displayPath("/tmp/island.sock", home: home), "/tmp/island.sock",
                "a path outside home is left alone")
            await expectEqual(
                PipelineHealth.displayPath(socketPath, home: ""), socketPath,
                "and an empty home abbreviates nothing rather than everything")
        }

        // Reached only if the window could be opened between `buildSettings()`
        // and `startPipeline()`. It cannot be — but the value has to claim
        // nothing rather than default to a lie in either direction.
        test("Before the socket starts, nothing is claimed either way") {
            let fresh = PipelineHealth()
            await expect(fresh.level == .idle, "not degraded, and not yet healthy")
            await expectEqual(fresh.socketLabel(home: home), "Starting…")
        }
    }
}
