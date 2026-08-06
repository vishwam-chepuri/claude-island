import Foundation

/// Strips secrets and clamps length before anything reaches the UI.
///
/// This runs at the `SessionStore` boundary rather than in a view, so the
/// redacted string is the only string the UI ever holds. A view cannot leak what
/// it was never given, and the rules stay unit-testable without a window.
public enum Redactor {
    public static let maxDisplayLength = 60

    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // Provider keys, longest/most specific first.
            (#"sk-ant-[A-Za-z0-9._-]{8,}"#, "sk-ant-<redacted>"),
            (#"sk-[A-Za-z0-9._-]{16,}"#, "sk-<redacted>"),
            (#"gh[pousr]_[A-Za-z0-9]{16,}"#, "gh_<redacted>"),
            (#"github_pat_[A-Za-z0-9_]{20,}"#, "github_pat_<redacted>"),
            (#"xox[baprs]-[A-Za-z0-9-]{10,}"#, "xox-<redacted>"),
            (#"AKIA[0-9A-Z]{16}"#, "AKIA<redacted>"),
            (#"ASIA[0-9A-Z]{16}"#, "ASIA<redacted>"),
            (#"AIza[0-9A-Za-z._-]{30,}"#, "AIza<redacted>"),
            // JWTs.
            (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"#, "<jwt>"),
            // Header / assignment forms. Keep the key name, drop the value.
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#, "Bearer <redacted>"),
            // The leading `[A-Za-z_]*` catches prefixed forms like PGPASSWORD,
            // where a bare \b would not match at the start of "PASSWORD".
            (
                #"(?i)\b([A-Za-z_]*(?:pass(?:word)?|passwd|secret|token|api[_-]?key))\s*[=:]\s*\S+"#,
                "$1=<redacted>"
            ),
            (#"(?i)\b(-{1,2}pass(word)?|-{1,2}token|-{1,2}secret)[= ]\S+"#, "$1 <redacted>"),
            // URL userinfo: https://user:pw@host
            (#"://[^/\s:@]+:[^/\s@]+@"#, "://<redacted>@"),
            // PEM blocks.
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "<private-key>"),
            // Generic high-entropy runs. Last so named forms win first.
            (#"\b[0-9a-fA-F]{40,}\b"#, "<hex>"),
        ]
        return specs.compactMap { pattern, replacement in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (re, replacement)
        }
    }()

    /// Redact secrets without changing length semantics.
    public static func redact(_ input: String) -> String {
        var s = input
        for (re, replacement) in patterns {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(
                in: s, options: [], range: range, withTemplate: replacement)
        }
        return s
    }

    /// Collapse whitespace, redact, then clamp to `limit` with an ellipsis.
    ///
    /// Redaction runs before truncation deliberately: truncating first could cut
    /// a secret in half and leave the leading half visible.
    public static func sanitize(_ input: String?, limit: Int = maxDisplayLength) -> String? {
        guard let input else { return nil }
        let collapsed = input
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        let redacted = redact(collapsed)
        return truncate(redacted, limit: limit)
    }

    public static func truncate(_ s: String, limit: Int = maxDisplayLength) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(max(0, limit - 1))) + "\u{2026}"
    }

    /// Shorten a path for display: `~` for home, and keep only the last two
    /// components when it is still long.
    public static func shortenPath(_ path: String, limit: Int = maxDisplayLength) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        guard p.count > limit else { return p }
        let parts = p.split(separator: "/")
        if parts.count > 2 {
            let tail = parts.suffix(2).joined(separator: "/")
            let candidate = "\u{2026}/" + tail
            if candidate.count <= limit { return candidate }
        }
        // Keep the tail rather than the head — the filename is the informative end.
        return "\u{2026}" + String(p.suffix(limit - 1))
    }
}
