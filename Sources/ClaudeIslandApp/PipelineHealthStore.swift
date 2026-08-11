import ClaudeIslandCore
import Foundation
import Observation

/// Live pipeline state, in the shape the settings window reads it.
///
/// A holder rather than a reference to `AppController`, for the same reason
/// `SettingsActions` is a bag of closures: the window is a view over state, and
/// every route from the window back into the running app should be listed in one
/// place. Here that list is empty — nothing on this object mutates the pipeline,
/// it only records what the pipeline already did.
///
/// The `PipelineHealth` value itself lives in Core and is pure; this is the thin
/// observable skin plus the one piece of state that cannot be pure, which is the
/// clock the elapsed label needs.
@MainActor
@Observable
final class PipelineHealthStore {
    private(set) var socket: PipelineHealth.Socket = .starting
    private(set) var lastEventAt: Date?
    private(set) var sessionCount = 0
    private(set) var statuslineForwarding = false

    /// Now, as far as the elapsed label is concerned. Only moves while the
    /// settings window is on screen — see `windowBecameVisible()`.
    private(set) var now = Date()

    @ObservationIgnored private var ticker: Timer?
    /// Injectable so the self-test can prove the ticker starts and stops without
    /// spending a second per assertion. Ships at 1 Hz.
    @ObservationIgnored private let tickInterval: TimeInterval

    init(tickInterval: TimeInterval = 1) {
        self.tickInterval = tickInterval
    }

    /// Assembled on read rather than stored, so there is exactly one definition
    /// of each derived answer and it is the one the headless suite covers.
    var current: PipelineHealth {
        PipelineHealth(
            socket: socket, lastEventAt: lastEventAt, sessionCount: sessionCount,
            statuslineForwarding: statuslineForwarding)
    }

    // MARK: - What the pipeline reports

    func socketListening(at path: String) {
        socket = .listening(path: path)
    }

    /// Kept, not just alerted on. The launch alert is modal and shown once; a
    /// user who dismissed it an hour ago and is now wondering why the island is
    /// empty has nothing left to read, which is the gap this closes.
    func socketFailed(at path: String, reason: String) {
        socket = .failed(path: path, reason: reason)
    }

    func noteEvent(at date: Date = Date()) {
        lastEventAt = date
    }

    func noteSessions(_ count: Int) {
        sessionCount = count
    }

    /// Re-reads whether the status line forwards to us.
    ///
    /// This one is a disk read (`~/.claude/settings.json`, then the script it
    /// names), so it happens when the window opens and after the Hooks pane
    /// changes something — never on the tick. It is also the only figure here
    /// the app does not otherwise observe: nothing notifies us when the user
    /// edits their own status-line script by hand, so a stale answer is possible
    /// between opens and is preferred to reading a file every second.
    func refreshStatusline() {
        statuslineForwarding = StatuslineInstaller.isInstalled()
    }

    // MARK: - The ticker

    /// Starts the clock behind "3s ago", and refreshes the figures that are only
    /// worth re-reading when someone is looking.
    ///
    /// An elapsed label is a clock, and this app's contract is that there is no
    /// clock when there is nothing to count: no session means no `syncTicker`
    /// timer at all, and `AppController.apply` tears the hover monitor down
    /// rather than leaving it idling. A timer that outlived this window would
    /// break that in the one way nobody would ever notice — window closed, HUD
    /// dormant, and a 1 Hz timer waking the process forever.
    ///
    /// So the ticker is anchored to the window's lifecycle rather than to the
    /// view's. SwiftUI's `onDisappear` does not fire for a hosted view whose
    /// window is merely ordered out: `SettingsWindowController` keeps the window
    /// alive across open/close cycles (`isReleasedWhenClosed = false`), so the
    /// view stays in the hierarchy and only the window goes off screen.
    /// `windowWillClose` and `windowDidMiniaturize` do fire, and they are what
    /// drive this.
    ///
    /// Honest limitation: a window left open but completely covered by another
    /// app keeps ticking. Occlusion state changes on every drag across the
    /// screen, and one 1 Hz timer against a window the user deliberately left
    /// open is not the case the contract is about.
    func windowBecameVisible() {
        refreshStatusline()
        now = Date()
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        // .common, like the HUD's ticker: the label should keep counting while a
        // picker or a menu in this window is tracking.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Called when the window closes or is miniaturised, and again from
    /// `AppController.shutdown()` — belt and braces, because the cost of missing
    /// one of those paths is a timer nobody can see.
    func windowWentAway() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Whether a timer is actually scheduled. The self-test asserts on this
    /// directly: "the label stopped updating" is not the same claim as "nothing
    /// is scheduled", and only the second one is the contract.
    var isTicking: Bool { ticker != nil }
}
