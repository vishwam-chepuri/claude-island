import Foundation

/// How long a permission prompt stays answerable from the HUD.
///
/// Generous on purpose. Claude Code leaves its own dialog up for the whole wait,
/// so a long deadline costs nothing — the human is never blocked on the HUD, and
/// answering in the terminal ends the wait immediately. The only thing a shorter
/// deadline would buy is fewer seconds in which the notch is useful.
public enum DecisionTimeout {
    /// The client's own deadline, in milliseconds. Mirrored as a literal in
    /// `claude-island-notify`, which cannot import this module: it is Darwin-only
    /// by design, so that the hook costs no dyld work on every tool call.
    public static let clientMillis: Int32 = 600_000

    /// The `timeout` written into settings.json for the permission hook, in
    /// seconds. Longer than `clientMillis` so the client always retires on its
    /// own terms rather than being killed mid-wait.
    public static let hookSeconds = 660
}

/// An answer to a pending permission prompt, in the form Claude Code honours.
///
/// The wire shape is not documented anywhere we can cite: it was established by
/// answering a real interactive prompt from a `PermissionRequest` hook against
/// claude 2.1.226 and reading the result back out of the transcript, which
/// records "Allowed by PermissionRequest hook" / "Denied by PermissionRequest
/// hook". Change it only against the same kind of evidence.
///
/// Deliberately not modelled yet: `decision.applyRule`, which would persist an
/// "always allow this" rule, and `decision.updatedInput`. Both appear in the
/// payload's own `permission_suggestions`, but neither has been verified the way
/// the two cases here have, and guessing at a shape that writes permission rules
/// to disk is the wrong kind of guess.
public enum PermissionDecision: Sendable, Equatable {
    case allow
    /// `note` is surfaced to Claude as context for why it was refused, so it can
    /// say something better than "the tool failed".
    case deny(note: String?)

    private var behavior: String {
        switch self {
        case .allow: "allow"
        case .deny: "deny"
        }
    }

    /// The stdout a `PermissionRequest` hook must emit to settle the prompt.
    ///
    /// One line: hook stdout is read as a single JSON document, and keeping it
    /// to one line means the client can forward it verbatim without framing.
    public var hookResponseJSON: String {
        var output: [String: Any] = [
            "hookEventName": HookEvent.permissionRequest.name,
            "decision": ["behavior": behavior],
        ]
        if case .deny(let note) = self, let note, !note.isEmpty {
            output["additionalContext"] = note
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["hookSpecificOutput": output], options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            // Unreachable for a dictionary of strings, and the fallback is the
            // safe one regardless: emitting nothing leaves the prompt exactly
            // where it was, still answerable in the terminal.
            return ""
        }
        return text
    }
}
