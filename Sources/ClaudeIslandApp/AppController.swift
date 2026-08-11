import AppKit
import ClaudeIslandCore
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let log = IslandLog.fromEnvironment()

    private var store: SessionStore!
    private var server: SocketServer!
    private var watcher: TranscriptWatcher!
    private var panel: IslandPanel!
    private var hoverMonitor: HoverMonitor!
    private let model = IslandViewModel()
    private let settings: SettingsStore
    /// What the settings window's health strip reads. Written from the three
    /// places the pipeline's state is actually known — the socket start, every
    /// arriving envelope, every snapshot — and read nowhere else.
    private let health = PipelineHealthStore()
    private var settingsWindow: SettingsWindowController!
    /// Whether to open the settings window as soon as the app is up — true on a
    /// fresh install, and for `--settings`. With no menu bar extra there is
    /// nothing on screen to find, so a first run that showed no window at all
    /// would be indistinguishable from one that failed to launch.
    private let opensSettingsAtLaunch: Bool

    private var socketTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var trackedTranscripts = Set<String>()

    // MARK: - Sound cues

    /// Every session id observed in at least one snapshot. A session's first
    /// appearance must seed `lastSoundCue` silently rather than ring for
    /// state it was already in before the HUD ever saw it (e.g. the app
    /// relaunching mid-session).
    private var seenSessionIDs = Set<String>()
    /// The cue each session was last observed in, so a repeat of the same cue
    /// — a second permission ask, another idle nudge — does not re-ring.
    private var lastSoundCue: [String: SoundCue] = [:]

    /// Mutes sound cues alone; the HUD keeps running.
    private var doNotDisturb: Bool { settings.doNotDisturb }

    init(settings loaded: IslandSettings, opensSettingsAtLaunch: Bool) {
        self.settings = SettingsStore(loaded)
        self.opensSettingsAtLaunch = opensSettingsAtLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already implies this, but be explicit: the app must never
        // take focus except to show its own settings window, so it must never
        // become a regular activation-policy app.
        NSApp.setActivationPolicy(.accessory)

        IslandPaths.ensureRoot()
        // Panel first: seeding the settings applies them, and applying
        // `hudEnabled: false` orders the panel out — which needs a panel.
        buildPanel()
        buildSettings()
        startPipeline()
        observeScreenChanges()
        log.debug("ClaudeIsland started")

        if opensSettingsAtLaunch { openSettings() }
    }

    /// Reopening the app — from Finder, Spotlight, or `open -a` — is the way
    /// back to the settings window.
    ///
    /// With the menu bar extra gone this is the app's only permanent entry
    /// point: the HUD itself is unclickable whenever it is dormant, which is
    /// most of the time, and an accessory app has no Dock icon to click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        log.debug("reopen requested (hasVisibleWindows: \(hasVisibleWindows))")
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    // MARK: - Panel

    private func buildPanel() {
        let geometry = NotchGeometryResolver.current()
        model.setGeometry(geometry)

        let frame = geometry?.panelRect
            ?? CGRect(
                x: 0, y: 0,
                width: NotchGeometryResolver.panelWidth,
                height: NotchGeometryResolver.panelHeight)

        panel = IslandPanel(contentRect: frame)
        let host = NSHostingView(rootView: IslandView(model: model))
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        hoverMonitor = HoverMonitor(panel: panel)
        hoverMonitor.onHoverChange = { [weak self] inside in
            guard let self else { return }
            self.model.isHovered = inside
            // The shape changes size on hover, so the hit region must follow it
            // immediately or the cursor can end up outside its own target.
            self.syncInteractiveRect()
        }
        hoverMonitor.onClickOutside = { [weak self] in
            guard let self, self.model.isPinnedOpen else { return }
            self.model.unpin()
            self.syncInteractiveRect()
        }

        // orderFrontRegardless, never makeKeyAndOrderFront: the latter would
        // defeat the entire point of a non-activating panel.
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        syncInteractiveRect()
    }

    private func syncInteractiveRect() {
        guard model.isEnabled, !model.snapshot.isDormant else {
            hoverMonitor.setInteractiveRect(.zero)
            return
        }
        // While pinned the region is the expanded card, so a second click can
        // land on it to unpin.
        hoverMonitor.setInteractiveRect(model.interactiveScreenRect)
    }

    private func repositionPanel() {
        guard let geometry = NotchGeometryResolver.current() else { return }
        model.setGeometry(geometry)
        panel.setFrame(geometry.panelRect, display: true)
        syncInteractiveRect()
        log.debug(
            "repositioned to \(geometry.hasNotch ? "notch" : "pill") at \(geometry.islandRect)")
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionPanel() }
        }
    }

    // MARK: - Pipeline

    private func startPipeline() {
        store = SessionStore(log: log)

        watcher = TranscriptWatcher(log: log) { [weak self] update in
            Task { @MainActor [weak self] in
                await self?.store.applyTranscript(update)
            }
        }

        server = SocketServer(log: log)
        // The client behind a held prompt vanishes when the terminal answers
        // first. Nothing else tells us, so this is the only way the card learns
        // to stop offering an answer it can no longer deliver.
        server.onWithdraw = { [weak self] token in
            Task { @MainActor [weak self] in
                await self?.store.withdrawDecision(token)
            }
        }
        model.onAnswerPermission = { [weak self] token, decision in
            self?.answerPermission(token, with: decision)
        }
        do {
            let stream = try server.start()
            health.socketListening(at: server.path)
            socketTask = Task { [weak self] in
                for await envelope in stream {
                    await self?.handle(envelope)
                }
            }
        } catch {
            log.debug("socket failed to start: \(error)")
            // Recorded as well as alerted. The alert is modal, fires once at
            // launch, and is gone the moment it is dismissed — which happens
            // before there is anything to connect it to, since the island looks
            // the same either way. The strip is what is still there to read an
            // hour later, when the emptiness is what prompts the question.
            health.socketFailed(at: server.path, reason: "\(error)")
            presentSocketFailure(error)
        }

        snapshotTask = Task { [weak self] in
            guard let store = self?.store else { return }
            for await snapshot in await store.snapshots() {
                await MainActor.run { self?.apply(snapshot) }
            }
        }
    }

    /// Delivers a decision to the waiting hook client.
    ///
    /// The write is a couple of hundred bytes into a socket with an empty send
    /// buffer, so this does not block the main thread. The prompt is retired here
    /// either way: if the write failed, the terminal had already settled it, and
    /// in both cases the card should stop offering to answer.
    private func answerPermission(_ token: UInt64, with decision: PermissionDecision) {
        let delivered = server.resolve(token, with: decision)
        if !delivered {
            log.debug("decision for \(token) arrived after the prompt was settled")
        }
        Task { [weak self] in await self?.store.withdrawDecision(token) }
    }

    private func handle(_ envelope: HookEnvelope) async {
        // Noted before anything can go wrong with this particular envelope: the
        // question the strip answers is whether the path from a hook to this
        // process works at all, and an envelope that arrived and was then
        // discarded still proves that it does.
        health.noteEvent()

        // A prompt whose client is already gone must not arrive answerable. The
        // withdrawal for it has, by then, already been delivered against a
        // session that was not yet waiting on anything, so it cleared nothing —
        // this is the half of that race the push notification cannot cover. A
        // hook installed without `--await-decision` hits it every single time.
        var envelope = envelope
        if let token = envelope.decisionToken, !server.isPendingDecision(token) {
            envelope.decisionToken = nil
        }
        await store.ingest(envelope)

        // Arm the transcript watcher the first time a session tells us where
        // its transcript lives.
        if let path = envelope.transcriptPath, !path.isEmpty,
            !trackedTranscripts.contains(envelope.sessionID)
        {
            trackedTranscripts.insert(envelope.sessionID)
            watcher.track(sessionID: envelope.sessionID, transcriptPath: path)
        }
        if envelope.event == .sessionEnd {
            trackedTranscripts.remove(envelope.sessionID)
            watcher.untrack(sessionID: envelope.sessionID)
        }
    }

    private func apply(_ snapshot: HUDSnapshot) {
        playSoundCues(for: snapshot)
        model.apply(snapshot)
        health.noteSessions(snapshot.sessionCount)

        // The hover monitor exists only while there is something to hover.
        // With no sessions it is torn down completely, which is what keeps idle
        // CPU at zero rather than merely low.
        let shouldMonitor = model.isEnabled && !snapshot.isDormant
        if shouldMonitor {
            hoverMonitor.start()
        } else {
            hoverMonitor.stop()
            model.isHovered = false
        }
        syncInteractiveRect()
    }

    /// Rings a sound on each session's edge into `.done`, `.awaitingPermission`,
    /// or the idle nudge — not on every snapshot they happen to still be in it.
    ///
    /// Tracking updates unconditionally even while the HUD is disabled, so
    /// re-enabling it never fires a catch-up sound for a transition that
    /// already happened silently.
    private func playSoundCues(for snapshot: HUDSnapshot) {
        let sessions = [snapshot.primary].compactMap { $0 } + snapshot.others
        var liveIDs = Set<String>()

        for session in sessions {
            liveIDs.insert(session.id)
            let cue = session.state.soundCue
            let firstObservation = seenSessionIDs.insert(session.id).inserted
            if !firstObservation, model.isEnabled, let cue, rings(cue),
                lastSoundCue[session.id] != cue
            {
                play(cue)
            }
            lastSoundCue[session.id] = cue
        }

        seenSessionIDs.formIntersection(liveIDs)
        lastSoundCue = lastSoundCue.filter { liveIDs.contains($0.key) }
    }

    /// Whether a cue is allowed to ring right now.
    ///
    /// The global mute outranks the per-cue switch, so one click silences
    /// everything without editing three switches that then have to be put back.
    /// Both checks live here rather than inside `play` so the preview button can
    /// ignore them — see `previewSound`.
    private func rings(_ cue: SoundCue) -> Bool { !doNotDisturb && settings[cue].enabled }

    /// Rings a cue with whatever sound it is set to.
    ///
    /// Reads the store at ring time rather than through `applySettings`: there
    /// is no live state to keep in step, so a change to a picker takes effect on
    /// the next cue with nothing to apply in between.
    private func play(_ cue: SoundCue) {
        Self.sound(for: cue, named: settings[cue].name)?.play()
    }

    /// Resolves a stored sound name to something that will actually make a
    /// noise, falling back to what this cue rang before it was configurable.
    ///
    /// `NSSound(named:)` answers nil for anything this Mac does not have — a
    /// name a future macOS drops, or a typo in a hand-edited settings.json.
    /// Falling silent there is the wrong failure: a cue that does not ring is
    /// indistinguishable from a cue that never fired, so a bad name would be
    /// read as "the HUD stopped noticing my sessions" rather than "that sound is
    /// gone", and there is nothing on screen at that moment to correct the
    /// impression. Ringing the default is wrong in a way you can hear, trace to
    /// this pane, and fix.
    ///
    /// Static, and separate from `play`, so --selftest can check the fallback
    /// resolved to the right sound without playing it.
    static func sound(for cue: SoundCue, named name: String) -> NSSound? {
        NSSound(named: name) ?? NSSound(named: cue.defaultSoundName)
    }

    /// Rings a cue on demand, from the settings window's play button.
    ///
    /// Deliberately ignores both the global mute and the cue's own switch: the
    /// button was just pressed, and a preview that answers with silence because
    /// of a switch elsewhere on the pane is indistinguishable from a broken
    /// button. It is also the only way to audition a sound for a cue you have
    /// not turned on yet.
    private func previewSound(_ cue: SoundCue) {
        play(cue)
    }

    private func presentSocketFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClaudeIsland could not open its socket"
        alert.informativeText =
            "\(error)\n\nThe HUD will run but receive no events. "
            + "Another copy may already be running."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Settings

    private func buildSettings() {
        settings.onChange = { [weak self] new in self?.applySettings(new) }
        let actions = SettingsActions(
            quit: { [weak self] in self?.quit() },
            revealSupportFolder: { [weak self] in self?.revealSupportFolder() },
            notifyBinaryPath: { Self.notifyBinaryPath() },
            previewSound: { [weak self] cue in self?.previewSound(cue) })
        settingsWindow = SettingsWindowController { [settings, model, health] in
            AnyView(SettingsView(store: settings, health: health, model: model, actions: actions))
        }
        // The health strip's elapsed label needs a clock, and this app promises
        // there is none when nothing is on screen to read it. The window is the
        // only thing that knows when that is true, so it owns the switch — see
        // `PipelineHealthStore.windowBecameVisible()` for why the view cannot.
        settingsWindow.onVisibilityChange = { [health] visible in
            visible ? health.windowBecameVisible() : health.windowWentAway()
        }
        // Seed the live state from what was loaded, so a HUD that was switched
        // off in a previous run comes back off rather than flashing on.
        applySettings(settings.current)
    }

    private func openSettings() {
        settingsWindow.show()
        let state = settingsWindow.diagnostics
        log.debug("settings window: \(state)")
    }

    /// Applies a settings change to the running app.
    ///
    /// Called for every change rather than only for the interesting ones: it is
    /// cheap, and it means there is exactly one path from a stored setting to
    /// its effect, so a setting cannot be honoured on relaunch but ignored live.
    ///
    /// The sound settings are the one deliberate exception, and they are an
    /// exception in the safe direction: `rings` and `play` read the store at the
    /// moment a cue fires, so there is no copy of them here that could go stale.
    private func applySettings(_ new: IslandSettings) {
        // The environment override outranks the stored setting, in both
        // directions: seeding settings at launch must not switch off logging
        // that `CLAUDE_ISLAND_DEBUG=1` asked for.
        let forcedByEnvironment = ProcessInfo.processInfo.environment["CLAUDE_ISLAND_DEBUG"] == "1"
        log.setEnabled(new.logging || forcedByEnvironment)
        model.debugTint = new.debugTint
        model.forcedMode = IslandMode(forcedName: new.forcedMode)

        guard new.hudEnabled != model.isEnabled else { return }
        model.setEnabled(new.hudEnabled)
        if new.hudEnabled {
            panel.orderFrontRegardless()
            if !model.snapshot.isDormant { hoverMonitor.start() }
        } else {
            panel.orderOut(nil)
            hoverMonitor.stop()
        }
        syncInteractiveRect()
    }

    // MARK: - Actions

    private func revealSupportFolder() {
        IslandPaths.ensureRoot()
        NSWorkspace.shared.activateFileViewerSelecting([IslandPaths.root])
    }

    private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    // MARK: - Lifecycle

    private func shutdown() {
        socketTask?.cancel()
        snapshotTask?.cancel()
        server?.stop()
        watcher?.stop()
        hoverMonitor?.stop()
        model.shutdown()
        // Belt and braces against the window's own teardown: quitting with the
        // settings window open must not leave its 1 Hz ticker scheduled.
        health.windowWentAway()
    }

    /// Where the hook client lives, for the settings.json command.
    ///
    /// Inside a bundle it sits next to the app binary; from `swift run` it sits
    /// next to the executable in .build.
    static func notifyBinaryPath() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = exe.deletingLastPathComponent().appendingPathComponent(
            "claude-island-notify")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
        // Fall back to the bundle's MacOS directory.
        if let bundled = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("claude-island-notify"),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled.path
        }
        return sibling.path
    }
}
