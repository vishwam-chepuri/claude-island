import ClaudeIslandCore
import Foundation

/// Fixtures live at the package root as plain files, not in a resource bundle,
/// so they stay readable and hand-editable.
private func fixtureURL(_ name: String) -> URL? {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("Fixtures/\(name)")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

private let allFixtures = [
    "basic-session.jsonl", "permission-and-error.jsonl", "multi-session.jsonl",
    "subagent.jsonl", "hostile.jsonl",
]

func registerReplayTests() {
    suite("Replay pipeline") {

        test("A basic session walks the full state sequence") {
            let url = try await require(fixtureURL("basic-session.jsonl"))
            let output = try await ReplayDriver().run(fileURL: url)

            await expectEqual(output.skippedCount, 0)
            await expectEqual(output.decodedCount, 10)
            await expectEqual(
                output.trace.map(\.state),
                [
                    "idle", "prompting", "thinking",
                    "running(Read)", "thinking",
                    "running(Edit)", "thinking",
                    "running(Bash)", "thinking",
                    "done", "removed",
                ])
            await expect(output.finalSessions.isEmpty, "session survived the fade")
        }

        test("Replay is deterministic across runs") {
            let url = try await require(fixtureURL("basic-session.jsonl"))
            let a = try await ReplayDriver().run(fileURL: url)
            let b = try await ReplayDriver().run(fileURL: url)
            await expectEqual(a.text, b.text)
        }

        test("Permission, failure and compaction all surface") {
            let url = try await require(fixtureURL("permission-and-error.jsonl"))
            let output = try await ReplayDriver().run(fileURL: url)
            let states = output.trace.map(\.state)

            for expected in [
                "awaitingPermission(Bash)", "error", "idle(waiting)", "compacting", "done",
            ] {
                await expect(states.contains(expected), "missing \(expected) in \(states)")
            }

            let alert = try await require(
                output.trace.first { $0.state.hasPrefix("awaitingPermission") })
            await expectEqual(alert.detail, "rm -rf ./build && make release")

            // The error decayed rather than pinning the HUD red.
            let errorIndex = try await require(states.firstIndex(of: "error"))
            await expect(states[(errorIndex + 1)...].contains("thinking"), "error never decayed")
        }

        test("Two sessions stay independent and the alert holds the slot") {
            let url = try await require(fixtureURL("multi-session.jsonl"))
            let output = try await ReplayDriver().run(fileURL: url)
            await expectEqual(Set(output.trace.map(\.sessionID)).count, 2)

            // Cut the log while session 2 still holds a permission prompt and
            // session 1 has since been more recently active.
            let data = try Data(contentsOf: url)
            let truncated =
                Data(data.split(separator: 0x0A).prefix(5).joined(separator: [0x0A]))
                + Data("\n".utf8)
            let midway = try await ReplayDriver().run(data: truncated)

            let primary = try await require(midway.finalSessions.first)
            await expect(primary.id.hasPrefix("22222222"), "alert lost the slot to recency")
            await expect(primary.state.isAlert)
        }

        test("A subagent shows its inner tool and pops cleanly") {
            let url = try await require(fixtureURL("subagent.jsonl"))
            let output = try await ReplayDriver().run(fileURL: url)
            let states = output.trace.map(\.state)

            await expect(states.contains("running(Task)"))
            await expect(states.contains("running(Grep)"), "the subagent's inner tool never showed")

            let taskLine = try await require(output.trace.first { $0.state == "running(Task)" })
            await expectEqual(taskLine.detail, "audit auth module")
        }

        test("Malformed lines, unknown events and secrets are all handled") {
            let url = try await require(fixtureURL("hostile.jsonl"))
            let output = try await ReplayDriver().run(fileURL: url)

            // Two bad lines: unparseable text, and a payload with no session_id.
            await expectEqual(output.skippedCount, 2)
            await expectEqual(output.decodedCount, 7)

            let rendered = output.trace.compactMap(\.detail).joined(separator: " ")
            await expect(!rendered.contains("sk-ant-api03"), "leaked an API key: \(rendered)")
            await expect(!rendered.contains("ghp_ABCDEFGH"), "leaked a PAT: \(rendered)")

            await expect(
                output.trace.contains { $0.state == "running(BrandNewToolNobodyHasSeen)" },
                "an unmodelled tool failed to render")
            await expect(
                output.trace.contains { $0.state.hasPrefix("awaitingPermission") },
                "a permission-shaped Notification did not raise the alert")
        }

        test("Every rendered detail respects the 60-char clamp") {
            for name in allFixtures {
                let url = try await require(fixtureURL(name))
                let output = try await ReplayDriver().run(fileURL: url)
                for line in output.trace {
                    await expect(
                        (line.detail?.count ?? 0) <= Redactor.maxDisplayLength,
                        "\(name): overlong detail \(line.detail ?? "")")
                }
            }
        }

        test("An empty log produces an empty trace rather than failing") {
            let output = try await ReplayDriver().run(data: Data())
            await expect(output.trace.isEmpty)
            await expectEqual(output.decodedCount, 0)
        }
    }
}
