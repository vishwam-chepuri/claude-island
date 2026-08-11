import ClaudeIslandCore
import Foundation

/// Reads a value out of the encoded hook response by key path, so these tests
/// assert the contract Claude Code actually parses rather than a serialisation
/// order that carries no meaning.
private func value(_ json: String, _ path: String...) -> Any? {
    guard let data = json.data(using: .utf8),
        var node = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    for key in path {
        guard let object = node as? [String: Any], let next = object[key] else { return nil }
        node = next
    }
    return node
}

func registerPermissionDecisionTests() {
    suite("Permission decision wire format") {

        // The shape below is not from documentation: it was verified against
        // claude 2.1.226 by answering a real interactive prompt from a hook and
        // watching the transcript record "Allowed by PermissionRequest hook".
        test("An allow decision names the event and the allow behavior") {
            let json = PermissionDecision.allow.hookResponseJSON
            await expectEqual(
                value(json, "hookSpecificOutput", "hookEventName") as? String, "PermissionRequest")
            await expectEqual(
                value(json, "hookSpecificOutput", "decision", "behavior") as? String, "allow")
        }

        test("A deny decision carries the deny behavior") {
            let json = PermissionDecision.deny(note: nil).hookResponseJSON
            await expectEqual(
                value(json, "hookSpecificOutput", "decision", "behavior") as? String, "deny")
        }

        test("A deny note reaches Claude as additional context") {
            let json = PermissionDecision.deny(note: "Denied from the island.").hookResponseJSON
            await expectEqual(
                value(json, "hookSpecificOutput", "additionalContext") as? String,
                "Denied from the island.")
        }

        test("An allow decision carries no additional context") {
            let json = PermissionDecision.allow.hookResponseJSON
            await expect(
                value(json, "hookSpecificOutput", "additionalContext") == nil,
                "allow should not editorialise into the transcript")
        }

        test("A decision encodes as one line, because hook stdout is line-oriented") {
            for decision in [PermissionDecision.allow, .deny(note: "no")] {
                await expect(
                    !decision.hookResponseJSON.contains("\n"),
                    "\(decision) serialised across multiple lines")
            }
        }
    }
}
