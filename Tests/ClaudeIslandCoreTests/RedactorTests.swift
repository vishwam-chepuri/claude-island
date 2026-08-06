import ClaudeIslandCore
import Foundation

func registerRedactorTests() {
    suite("Redaction and truncation") {

        test("Provider keys are stripped") {
            for secret in [
                "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
                "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
                "github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
                "xoxb-123456789012-abcdefghijklmnop",
                "AKIAIOSFODNN7EXAMPLE",
                "AIzaSyD-1234567890abcdefghijklmnopqrstuv",
            ] {
                let out = Redactor.redact("deploy --key \(secret) now")
                await expect(!out.contains(secret), "leaked \(secret) as: \(out)")
            }
        }

        test("JWTs are stripped") {
            let jwt =
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
            let out = Redactor.redact("Authorization: \(jwt)")
            await expect(out.contains("<jwt>"))
            await expect(!out.contains("dozjgNryP4J3"))
        }

        test("Bearer tokens and assignments keep the key, drop the value") {
            await expect(
                !Redactor.redact("curl -H 'Authorization: Bearer abcdef1234567890xyz'")
                    .contains("abcdef1234567890xyz"))
            await expect(!Redactor.redact("PGPASSWORD=hunter2sekrit psql").contains("hunter2sekrit"))
            await expect(
                !Redactor.redact("api_key: 9f8e7d6c5b4a39281706").contains("9f8e7d6c5b4a39281706"))
        }

        test("URL userinfo credentials are stripped") {
            let out = Redactor.redact("git clone https://alice:s3cr3tpw@github.com/org/repo.git")
            await expect(!out.contains("s3cr3tpw"))
            await expect(out.contains("github.com/org/repo.git"))
        }

        test("Long hex runs are stripped") {
            await expect(
                Redactor.redact("token 0123456789abcdef0123456789abcdef01234567 end")
                    .contains("<hex>"))
        }

        test("Ordinary commands survive untouched") {
            let cmd = "swift test --filter FetcherTests"
            await expectEqual(Redactor.redact(cmd), cmd)
            await expectEqual(Redactor.sanitize(cmd), cmd)
        }

        test("Nothing is rendered beyond 60 characters") {
            let out = Redactor.sanitize(String(repeating: "x", count: 500))
            await expectEqual(out?.count, Redactor.maxDisplayLength)
            await expectEqual(out?.hasSuffix("\u{2026}"), true)
        }

        test("Redaction runs before truncation so no half-secret survives") {
            // The secret sits inside the first 60 characters; truncating first
            // would leave its leading half on screen.
            let input =
                "export TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 && run the very long build"
            let out = Redactor.sanitize(input) ?? ""
            await expect(!out.contains("ghp_ABCDEFGH"), "half-secret survived: \(out)")
            await expect(out.count <= Redactor.maxDisplayLength)
        }

        test("Newlines collapse to single spaces") {
            await expectEqual(
                Redactor.sanitize("line one\nline two\n\tthree"), "line one line two three")
        }

        test("Empty and whitespace-only input yields nil") {
            await expectEqual(Redactor.sanitize(nil), nil)
            await expectEqual(Redactor.sanitize(""), nil)
            await expectEqual(Redactor.sanitize("   \n  "), nil)
        }

        test("Paths shorten from the head, keeping the filename") {
            let out = Redactor.shortenPath(
                "/Users/dev/code/very/deeply/nested/project/Sources/Module/Thing.swift")
            await expect(out.count <= Redactor.maxDisplayLength)
            await expect(out.hasSuffix("Thing.swift"), "lost the filename: \(out)")
        }

        test("Home directory collapses to a tilde") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            await expectEqual(Redactor.shortenPath("\(home)/notes.md"), "~/notes.md")
        }
    }

    suite("Tool target extraction") {

        test("Each tool surfaces its informative field") {
            await expectEqual(
                ToolActivity.extractTarget(
                    toolName: "Bash", input: .object(["command": .string("make build")])),
                "make build")
            await expectEqual(
                ToolActivity.extractTarget(
                    toolName: "Read", input: .object(["file_path": .string("/tmp/a.swift")])),
                "/tmp/a.swift")
            await expectEqual(
                ToolActivity.extractTarget(
                    toolName: "WebFetch", input: .object(["url": .string("https://example.com")])),
                "https://example.com")
            await expectEqual(
                ToolActivity.extractTarget(
                    toolName: "Task", input: .object(["description": .string("audit auth")])),
                "audit auth")
        }

        test("Grep shows pattern and path together") {
            await expectEqual(
                ToolActivity.extractTarget(
                    toolName: "Grep",
                    input: .object([
                        "pattern": .string("authenticate\\("), "path": .string("/src"),
                    ])),
                "authenticate\\(  in  /src")
        }

        test("An unmodelled tool still finds a target and renders") {
            await expectEqual(ToolKind(toolName: "BrandNewToolNobodyHasSeen"), .other)
            await expectEqual(
                ToolActivity.extractTarget(
                    toolName: "BrandNewToolNobodyHasSeen",
                    input: .object(["mystery": .string("x"), "command": .string("echo hi")])),
                "echo hi")
        }

        test("Missing or empty tool_input yields nil rather than throwing") {
            await expectEqual(ToolActivity.extractTarget(toolName: "Bash", input: nil), nil)
            await expectEqual(ToolActivity.extractTarget(toolName: "Bash", input: .object([:])), nil)
            await expectEqual(
                ToolActivity.extractTarget(toolName: "Read", input: .string("weird")), nil)
        }

        test("Secrets in a command never reach the activity target") {
            let activity = ToolActivity.from(
                HookEnvelope(
                    sessionID: "s", event: .preToolUse, toolName: "Bash",
                    toolInput: .object([
                        "command": .string("curl -H 'Authorization: Bearer abcdefghijklmnop123456'")
                    ])))
            await expectEqual(activity.target?.contains("abcdefghijklmnop"), false)
        }

        test("Every modelled tool has a glyph") {
            for kind in ToolKind.allCases {
                await expect(!kind.symbolName.isEmpty, "\(kind) has no symbol")
            }
        }
    }
}
