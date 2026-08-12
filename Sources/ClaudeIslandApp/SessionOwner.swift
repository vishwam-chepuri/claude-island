import AppKit
import ClaudeIslandCore

/// Binds `OwnerResolution` to the running system, and raises the winner.
enum SessionOwner {
    private static let log = IslandLog.fromEnvironment()

    /// Resolve against the live process table and application list.
    static func resolve(_ ancestors: [Int32]) -> OwnerResolution.Outcome {
        OwnerResolution.resolve(
            ancestors,
            // EPERM means the process exists and simply is not ours to signal.
            // Reading that as "dead" would report a terminal running as another
            // user as having quit.
            isRunning: { pid in kill(pid, 0) == 0 || errno == EPERM },
            lookup: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
                return OwnerResolution.AppInfo(
                    pid: pid,
                    bundleID: app.bundleIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "the terminal",
                    isRegular: app.activationPolicy == .regular)
            })
    }

    /// Bring the session's app to the front. Returns whether anything was tried.
    ///
    /// Re-resolves rather than trusting a cached answer, and that is not
    /// belt-and-braces: `open -b` on an app that has *quit* launches a fresh
    /// copy. Raising a terminal that closed while the card was open would be a
    /// surprising new window rather than the session you asked for.
    ///
    /// `/usr/bin/open`, not `NSRunningApplication.activate()`. Measured from a
    /// background accessory app that is not itself frontmost:
    ///
    /// | call | result |
    /// |---|---|
    /// | `activate()` | returns `true`, frontmost unchanged |
    /// | `activate(from:options:)` | frontmost unchanged |
    /// | `NSWorkspace.openApplication(activates: true)` | no error, frontmost unchanged |
    /// | `/usr/bin/open -b` | activates |
    ///
    /// macOS 14's cooperative activation rules stop a non-active app raising
    /// another in-process, and every one of those APIs reports success anyway.
    /// Spawning `open` — a trusted LaunchServices helper — is honoured, and
    /// needs no Automation or Accessibility permission, which is what keeps
    /// this app requiring none at all.
    @discardableResult
    static func reveal(_ ancestors: [Int32]) -> Bool {
        guard case .owner(let app) = resolve(ancestors), let bundleID = app.bundleID else {
            return false
        }
        // Off the main thread: spawning a process is milliseconds, and this
        // runs from a click on a panel that must not stutter.
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // argv, never a shell. The bundle id comes from LaunchServices
            // rather than any payload, and this keeps that true regardless.
            process.arguments = ["-b", bundleID]
            do {
                try process.run()
            } catch {
                log.debug("open -b \(bundleID) failed to launch: \(error)")
                return
            }
            // waitUntilExit() is safe here only because this closure already
            // runs off the main thread — this call blocks until open exits.
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                log.debug("open -b \(bundleID) exited \(process.terminationStatus)")
            }
        }
        return true
    }
}
