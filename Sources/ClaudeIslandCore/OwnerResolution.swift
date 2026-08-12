import Foundation

/// Which app a session belongs to, resolved from the process ancestry the hook
/// client stamps on its payloads.
///
/// Pure, and handed both of its probes, for the same reason
/// `AppController.rings(_:under:frontmost:)` is handed the frontmost bundle id:
/// Core imports no AppKit, and a walk that asked the workspace anything itself
/// could not be exercised without a window server.
public enum OwnerResolution {

    /// What the app layer knows about one pid.
    public struct AppInfo: Sendable, Equatable {
        public let pid: Int32
        public let bundleID: String?
        public let name: String
        /// True for an app with a Dock presence — the bundle root rather than
        /// one of its helper processes. Measured: VS Code's `Code Helper` does
        /// not appear in `NSWorkspace.runningApplications` as a regular app,
        /// which is what lets the walk step over it.
        public let isRegular: Bool

        public init(pid: Int32, bundleID: String?, name: String, isRegular: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.isRegular = isRegular
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// An ancestor is a running, raisable app.
        case owner(AppInfo)
        /// Ancestors are alive but none is an app: a daemon-hosted background
        /// job, a tmux server, or a session on the far end of an SSH link.
        case noOwningApp
        /// Nothing in the chain is still running — whatever ran this has quit.
        case gone
        /// No ancestry was ever recorded: replay traces and synthetic events.
        case unknown
    }

    /// The first ancestor that is a raisable app, or why there isn't one.
    ///
    /// Two probes rather than one, because they answer different questions.
    /// `lookup` answers nil for a live `zsh` just as readily as for a dead pid,
    /// so it cannot tell "this session has no app" from "this session's app has
    /// quit" — and those want different words on screen.
    public static func resolve(
        _ ancestors: [Int32],
        isRunning: (Int32) -> Bool,
        lookup: (Int32) -> AppInfo?
    ) -> Outcome {
        guard !ancestors.isEmpty else { return .unknown }
        var sawLiving = false
        for pid in ancestors {
            if isRunning(pid) { sawLiving = true }
            if let info = lookup(pid), info.isRegular, info.bundleID != nil {
                return .owner(info)
            }
        }
        return sawLiving ? .noOwningApp : .gone
    }
}
