import Foundation

/// What the event pipeline is doing, as one value the settings window can draw.
///
/// The HUD's failure mode is silence. An island with nothing on it is also its
/// resting state, so "no session is running", "the hooks were never installed"
/// and "another copy of the app owns the socket" all look identical from the
/// outside — and the last two are unrecoverable without being told. Everything
/// here exists to separate them from the first.
///
/// Plain Swift, in Core, because the two things worth getting right are pure:
/// the classification and the elapsed label. Reporting a healthy-but-quiet
/// pipeline as broken is the same bug this feature was written to fix, pointed
/// the other way, so it is checked headlessly rather than by eye.
public struct PipelineHealth: Sendable, Equatable {
    /// The listening socket. The one component whose failure is terminal:
    /// nothing downstream of it ever gets a chance to run.
    public enum Socket: Sendable, Equatable {
        /// Before `AppController.startPipeline()` has had its turn. The settings
        /// window is built first — `buildSettings()` precedes `startPipeline()`,
        /// because applying a stored `hudEnabled: false` needs a panel and a
        /// store before anything binds — so the holder needs an initial value
        /// that claims nothing rather than a default that would lie in one
        /// direction or the other. In practice the window cannot be opened early
        /// enough to see it.
        case starting
        case listening(path: String)
        case failed(path: String, reason: String)
    }

    public var socket: Socket
    /// When the most recent envelope arrived. Nil means none has since launch,
    /// which is an ordinary state and must never be drawn as an error.
    public var lastEventAt: Date?
    public var sessionCount: Int
    /// Whether the status-line forward is installed. Genuinely optional: without
    /// it the context window is inferred and every other figure is unaffected,
    /// so this is reported and never flagged.
    public var statuslineForwarding: Bool

    public init(
        socket: Socket = .starting,
        lastEventAt: Date? = nil,
        sessionCount: Int = 0,
        statuslineForwarding: Bool = false
    ) {
        self.socket = socket
        self.lastEventAt = lastEventAt
        self.sessionCount = sessionCount
        self.statuslineForwarding = statuslineForwarding
    }

    /// The distinction the strip exists to make.
    public enum Level: Sendable, Equatable {
        /// The socket is not listening, so no hook event can ever arrive. The
        /// HUD will stay empty however many sessions run.
        case degraded
        /// Everything is up and nothing has come through yet. Indistinguishable
        /// from `degraded` on the island itself — which is precisely why it has
        /// to be distinguishable here.
        case idle
        /// At least one envelope has landed, so the whole path from a hook to
        /// this process is known to work.
        case healthy
    }

    /// Deliberately not time-based past the first event: a pipeline that
    /// received something an hour ago and nothing since is a quiet afternoon,
    /// not a fault, and a strip that turned amber over lunch would be a worse
    /// liar than the empty island it replaces.
    public var level: Level {
        if case .failed = socket { return .degraded }
        return lastEventAt == nil ? .idle : .healthy
    }

    public var headline: String {
        switch level {
        case .degraded: "No hook events can arrive"
        case .idle: "Listening — no hook events yet"
        case .healthy: "Receiving hook events"
        }
    }

    /// What the headline means, when there is something worth adding.
    ///
    /// The idle sentence is the one that earns this feature. It has to say the
    /// pipeline is *fine* at the exact moment the HUD is empty, or a user
    /// reading it while nothing shows up concludes the failure it exists to
    /// rule out.
    public var explanation: String? {
        switch level {
        case .degraded:
            "Nothing will reach the island until this is fixed. Another copy of "
                + "ClaudeIsland already holding the socket is the usual cause."
        case .idle:
            "The socket is open and waiting. Events arrive as soon as a Claude Code "
                + "session runs — if one has run since ClaudeIsland started and nothing "
                + "landed, its hooks are the thing to check."
        case .healthy:
            nil
        }
    }

    /// One line for the socket row: state, where, and why not.
    public func socketLabel(home: String = FileManager.default.homeDirectoryForCurrentUser.path)
        -> String
    {
        switch socket {
        case .starting:
            return "Starting…"
        case .listening(let path):
            return "Listening at \(Self.displayPath(path, home: home))"
        case .failed(let path, let reason):
            // The reason is the actionable half — `bind() failed: Address already
            // in use` names the problem outright — but the path has to ride along
            // or "already in use" is unverifiable.
            return "Failed at \(Self.displayPath(path, home: home)) — \(reason)"
        }
    }

    /// "3s ago", or "never since launch".
    ///
    /// Deliberately relative rather than a clock time: the question this answers
    /// is "is anything still coming through", and 14:52:07 does not answer it
    /// without arithmetic.
    public func lastEventLabel(now: Date) -> String {
        guard let lastEventAt else { return "never since launch" }
        return Self.elapsedLabel(now.timeIntervalSince(lastEventAt))
    }

    /// Coarsens as it grows, because that is how the answer is read: seconds
    /// matter while you are watching a hook fire, and past a minute only the
    /// order of magnitude does.
    ///
    /// A negative interval means the clock moved under us — a sleep, an NTP
    /// correction — and reads as "just now" rather than as a time in the future.
    public static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 1 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h \((s % 3600) / 60)m ago"
    }

    /// Shortens `$HOME` back to `~`, so the socket row reads as the path the
    /// user would type rather than as a column of their own username.
    public static func displayPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
