import Foundation

/// How full the context window is.
///
/// The limit is inferred, never asserted. Three witnesses, in order of trust:
/// a model id carrying `[1m]`, the tier read off Claude Code's own config for
/// this working directory, and — last — an observed count that has already
/// passed a tier, which is proof the tier below it was wrong. Reading
/// "603.2k / 200.0k" is worse than having no bar at all.
///
/// This only ever scales a bar. The token counts themselves are exact.
public enum ContextWindow {
    public static let tiers = [200_000, 1_000_000]

    public static func limit(for model: String?, observed: Int = 0, longContext: Bool = false)
        -> Int
    {
        let declared: Int = {
            if longContext { return tiers[1] }
            guard let model = model?.lowercased() else { return tiers[0] }
            return (model.contains("[1m]") || model.contains("-1m")) ? tiers[1] : tiers[0]
        }()
        // Usage above the declared tier means the declared tier was wrong.
        let implied = tiers.first { observed <= $0 } ?? tiers.last!
        return max(declared, implied)
    }

    public static func fraction(used: Int, model: String?, longContext: Bool = false) -> Double {
        let cap = limit(for: model, observed: used, longContext: longContext)
        guard cap > 0, used > 0 else { return 0 }
        return min(1, Double(used) / Double(cap))
    }

    /// The session already carries every witness; asking it directly keeps them
    /// from drifting apart across call sites.
    ///
    /// A status-line reading is the window Claude Code itself is enforcing, so
    /// it settles the question — but it is still floored by what has been
    /// observed, because a count that exceeds the stated window means one of
    /// the two is stale and the larger is the safer bar to draw.
    public static func limit(for session: Session) -> Int {
        if let stated = session.contextLimit, stated > 0 {
            return max(stated, session.tokens.contextTokens)
        }
        return limit(
            for: session.model, observed: session.tokens.contextTokens,
            longContext: session.usesLongContext)
    }

    public static func fraction(for session: Session) -> Double {
        let used = session.tokens.contextTokens
        let cap = limit(for: session)
        guard cap > 0, used > 0 else { return 0 }
        return min(1, Double(used) / Double(cap))
    }
}
