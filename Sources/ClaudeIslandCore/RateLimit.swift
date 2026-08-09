import Foundation

/// One of the account's usage windows, as Claude Code reports it.
///
/// The only figure the HUD draws that is not about a session. A context bar
/// says how much room *this conversation* has left; this says how much room
/// *you* have left, and every session on the card is spending from it.
///
/// Published solely by the status-line payload, so it is absent — never zero —
/// for anyone without the forwarder installed. Zero would be a lie that reads
/// as good news.
public struct RateLimitWindow: Sendable, Equatable {
    /// 0...1. Clamped on the way in: the payload states a percentage, and one
    /// past 100 would draw a bar longer than its own track.
    public var usedFraction: Double
    /// When the window rolls over, if the server said. Nil is common enough
    /// that the bar has to read without it.
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date? = nil) {
        self.usedFraction = min(1, max(0, usedPercentage / 100))
        self.resetsAt = resetsAt
    }

    /// Parses the `resets_at` Claude Code emits: an ISO 8601 instant, with
    /// fractional seconds when it has round-tripped through a JS `Date` and
    /// without when it came straight off the server. Both are tried, because
    /// which one arrives depends on a path we do not control.
    ///
    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the latter
    /// is a non-Sendable class, so the parsers could not be held as constants
    /// and would have to be built on every payload — and the status line
    /// re-renders several times a second.
    public static func parseResetTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        for parser in [Self.isoWithFraction, Self.iso] {
            if let date = try? Date(raw, strategy: parser) { return date }
        }
        return nil
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso = Date.ISO8601FormatStyle()
}
