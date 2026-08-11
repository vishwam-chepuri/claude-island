import AppKit
import ClaudeIslandCore
import SwiftUI

/// Side effects the settings window needs but does not own.
///
/// Passed in as closures rather than reached for through a reference to
/// `AppController`, so the window stays a view over state and every mutation it
/// can cause is listed in one place.
@MainActor
struct SettingsActions {
    var quit: () -> Void
    var revealSupportFolder: () -> Void
    var notifyBinaryPath: () -> String
    /// Rings a cue's chosen sound now. Passed in rather than played here so the
    /// view keeps its promise of owning no side effects, and so mounting the
    /// pane in a test can hand it a no-op and make no noise.
    var previewSound: (SoundCue) -> Void
}

struct SettingsView: View {
    @Bindable var store: SettingsStore
    var health: PipelineHealthStore
    var model: IslandViewModel
    let actions: SettingsActions

    /// Bumped after any install or removal, to re-read hook state from disk.
    /// `HookInstaller` answers from `~/.claude/settings.json` every time, so
    /// there is nothing to cache — this just tells SwiftUI to ask again.
    @State private var hookRevision = 0
    @State private var hookMessage: String?
    @State private var hookMessageIsError = false
    @State private var writeFailure: String?

    /// Optional only because that is the shape `List` selection takes — "no
    /// pane" is not a state worth rendering. A click on empty sidebar space
    /// clears the selection, so the detail column falls back to General rather
    /// than going blank.
    @State private var pane: Pane? = .general

    /// Pinned open. This window has no toolbar, so the sidebar toggle that
    /// normally brings a collapsed column back has nowhere to draw itself; a
    /// sidebar the user can lose is one they cannot ask for again.
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        VStack(spacing: 0) {
            // maxHeight, not just the natural height: a pane's content is
            // taller than the window on a short display, and without this the
            // VStack lets it overflow its slot instead of scrolling inside it —
            // which silently clipped the first section header under the title
            // bar rather than putting it at the top of a scroll view.
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            store.onWriteFailure = { error in
                writeFailure = "Could not save settings: \(error)"
            }
        }
    }

    // MARK: - Navigation

    /// The panes are deliberately uneven — General holds three rows, Sounds
    /// holds a mute and three cues — because the even alternative is the single
    /// long form this replaced, where the hook controls and the debug pins sat
    /// one scroll apart from the setting most people came to change.
    private enum Pane: String, CaseIterable, Identifiable {
        case general, appearance, sounds, hooks, advanced

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .sounds: "Sounds"
            case .hooks: "Hooks"
            case .advanced: "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .sounds: "speaker.wave.2"
            case .hooks: "link"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    private var sidebar: some View {
        List(Pane.allCases, selection: $pane) { item in
            Label(item.title, systemImage: item.symbol)
        }
        // A floor rather than a fixed width: "Appearance" is the longest label
        // today, but the column still has to survive a larger text size.
        .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 220)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane ?? .general {
        case .general: generalPane
        case .appearance: appearancePane
        case .sounds: soundsPane
        case .hooks: hooksPane
        case .advanced: advancedPane
        }
    }

    // MARK: - Panes

    private var generalPane: some View {
        Form {
            healthStrip
            Section {
                LabeledContent("Status", value: statusLine)
                Toggle("Show the HUD", isOn: $store.hudEnabled)
                if LoginItem.isAvailable {
                    Toggle("Launch at login", isOn: launchAtLoginBinding)
                }
            } footer: {
                if !LoginItem.isAvailable {
                    Text("Launch at login is only available when running from ClaudeIsland.app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Whether anything is reaching the HUD at all.
    ///
    /// On General, above the switches, rather than in a Diagnostics pane of its
    /// own. The question it answers — "why is nothing showing up" — is asked by
    /// someone who has no reason to believe anything is broken yet, so a pane
    /// they would have to suspect the pipeline to click on is exactly the wrong
    /// place: it is found only by people who already know. General is the pane
    /// this window opens on, including on the fresh install where the window
    /// opens itself, and when all is well the strip is a tick and four plain
    /// rows — quiet enough to sit above the switches without shouting.
    ///
    /// The failure it exists for is invisible by construction — an island with
    /// nothing on it is also the resting state — so the rows under the headline
    /// trace the chain in order: the socket is up, something arrived, sessions
    /// are tracked. A dead socket breaks it at the first link and says so in
    /// red; a quiet afternoon breaks it at the second and must not.
    private var healthStrip: some View {
        Section("Event pipeline") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: healthSymbol)
                    .foregroundStyle(healthTint)
                    .imageScale(.large)
                    // The colour is a repetition of the headline, not the only
                    // carrier of it, so the icon has nothing of its own to say.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pipeline.headline)
                    if let explanation = pipeline.explanation {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LabeledContent("Socket") {
                Text(pipeline.socketLabel())
                    .multilineTextAlignment(.trailing)
                    // A bind failure's reason is a whole sentence from strerror,
                    // and truncating the one line that names the cause would
                    // leave the strip saying only that something is wrong.
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(pipeline.level == .degraded ? Color.red : Color.secondary)
            }
            LabeledContent("Last hook event", value: pipeline.lastEventLabel(now: health.now))
            // Overlaps the Status line below by a count, deliberately: this row
            // is the end of the pipeline's chain ("did anything become a
            // session"), where Status is what the island is currently drawing.
            // They agree in the healthy case and are read for different reasons.
            LabeledContent("Sessions tracked", value: "\(pipeline.sessionCount)")
            LabeledContent("Status line") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(pipeline.statuslineForwarding ? "Forwarding" : "Not installed")
                        .foregroundStyle(.secondary)
                    // Never red, and never phrased as a fault. Without it the
                    // context window is inferred and everything else on the card
                    // is unaffected, so a strip that flagged it would send people
                    // to fix the one thing here that is not broken.
                    if !pipeline.statuslineForwarding {
                        Text("Optional — the context window is inferred without it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Second in the sidebar rather than last: it is the one pane that answers a
    /// question — "what is this thing going to look like on my screen" — instead
    /// of asking one, and behind the hook plumbing it would only be found by
    /// people who were already looking for it.
    ///
    /// The preview is fed made-up sessions and driven by a view model of its own;
    /// see `IslandPreviewSource` for why that second model is not an optimisation
    /// but the whole safety property. Nothing on this pane writes a setting.
    private var appearancePane: some View {
        Form {
            Section {
                IslandPreview(store: store)
            } footer: {
                Text(
                    "These sessions are invented — the HUD draws them with the same "
                        + "code it draws yours with. The tier buttons pose this preview "
                        + "only; to pin the real HUD, use Advanced."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// One mute at the top, then a row per cue.
    ///
    /// The whole pane is still dimmed while the HUD is off, exactly as the lone
    /// switch was: no HUD means no cues, because `playSoundCues` will not ring
    /// for a HUD nobody can see. The reason for the dimming lives a pane away —
    /// a real cost of the split, accepted rather than papered over with a
    /// caption that would only restate the General pane.
    ///
    /// The cue rows are *not* dimmed by the mute above them. Muted is a state
    /// you configure through, and the play button has to keep working while it
    /// is on or it reads as broken; the footer says so instead.
    private var soundsPane: some View {
        Form {
            Section {
                Toggle("Play sounds", isOn: soundsBinding)
            } footer: {
                Text(
                    "Silences every cue at once, without disturbing the switches below — "
                        + "turning it back on restores what you had."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(SoundCue.allCases, id: \.self) { cue in
                    soundRow(cue)
                }
            } header: {
                Text("Cues")
            } footer: {
                Text(
                    store.doNotDisturb
                        ? "None of these will ring while Play sounds is off. Play previews the "
                            + "chosen sound anyway."
                        : "Play previews the chosen sound, whatever these switches say."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .disabled(!store.hudEnabled)
    }

    /// One cue: what it means in this app's terms, whether it rings, what it
    /// rings, and a way to hear that without waiting for a session to do it.
    ///
    /// The picker and the play button stay live under an *off* switch on
    /// purpose. The switch says whether the cue rings, not whether it can be
    /// set up — auditioning three sounds before deciding to turn a cue on is the
    /// normal way to use this pane, and a row that goes dead the moment you
    /// switch it off makes that a two-step dance.
    private func soundRow(_ cue: SoundCue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(cue.settingsTitle, isOn: soundEnabledBinding(cue))
            Text(cue.settingsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker("Sound", selection: soundNameBinding(cue)) {
                    ForEach(soundOptions(for: cue), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                Button {
                    actions.previewSound(cue)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                // The label reads "Play" for every row, which is fine to look at
                // and useless to hear: VoiceOver reads the rows one after
                // another and three identical buttons name nothing.
                .accessibilityLabel("Play the sound for \(cue.settingsTitle)")
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    /// The offered sounds, plus whatever this cue is set to if that is not one
    /// of them.
    ///
    /// This file is documented as hand-editable, and `SystemSound.all` is a
    /// fixed list rather than whatever the machine has — so a name that works
    /// perfectly well can be absent from it. A `Picker` whose selection matches
    /// no tag draws an empty row, which reads as a setting that was lost rather
    /// than one this build simply does not offer.
    private func soundOptions(for cue: SoundCue) -> [String] {
        let chosen = store[cue].name
        guard !SystemSound.all.contains(chosen) else { return SystemSound.all }
        return [chosen] + SystemSound.all
    }

    private var hooksPane: some View {
        Form {
            Section("Claude Code hooks") {
                LabeledContent("Hooks", value: hookStatus.label)
                if let hookMessage {
                    Text(hookMessage)
                        .font(.caption)
                        .foregroundStyle(hookMessageIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(hookStatus.actionTitle) { installHooks() }
                    if hookStatus != .absent {
                        Button("Remove") { uninstallHooks() }
                    }
                    Spacer()
                    Button("Copy Hook JSON") { copyHookJSON() }
                }
                if hookStatus == .stale {
                    Text(
                        "These hooks predate the permission prompt learning to wait, so "
                            + "prompts arrive with no way to answer them from the HUD."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("Restart any running Claude Code sessions after changing these.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPane: some View {
        Form {
            Section {
                Toggle("Write a debug log", isOn: $store.logging)
                Toggle("Show debug tint", isOn: $store.debugTint)
                Picker("Pin the HUD to", selection: forcedModeBinding) {
                    Text("Off — follow hover and click").tag("")
                    Text("Compact").tag("compact")
                    Text("Alert").tag("alert")
                    Text("Peek").tag("peek")
                    Text("Expanded").tag("expanded")
                }
                if store.forcedMode != nil {
                    Text(
                        "The HUD is pinned. Leave this off unless you are inspecting a "
                            + "tier — it also fails most of --selftest's mode checks."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button("Reveal Support Folder") { actions.revealSupportFolder() }
            }
        }
        .formStyle(.grouped)
    }

    /// Outside the split view on purpose, so it belongs to the window rather
    /// than to whichever pane happens to be showing.
    ///
    /// With no menu bar extra, this button is the only way to quit the app —
    /// ⌘Q works but only while this window has focus, and the window is not
    /// always open. A Quit that can be scrolled out of sight, or that lives on
    /// one pane out of four, is not a Quit. The write failure rides along for
    /// the same reason: a save can fail from any pane, including the login-item
    /// switch on General while the user is reading Hooks.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let writeFailure {
                Text(writeFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Stored in ~/.claude-island/settings.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit ClaudeIsland") { actions.quit() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Derived state

    /// Recomputed on read, which is what makes the strip live: `health.now`
    /// moves once a second while this window is open, so the elapsed label
    /// re-renders with it and everything else re-renders when it changes.
    private var pipeline: PipelineHealth { health.current }

    /// Three states, three shapes, so the strip is not read by colour alone: an
    /// aerial for listening, a tick for working, a warning triangle for a socket
    /// that never bound.
    private var healthSymbol: String {
        switch pipeline.level {
        case .degraded: "exclamationmark.triangle.fill"
        case .idle: "antenna.radiowaves.left.and.right"
        case .healthy: "checkmark.circle.fill"
        }
    }

    /// Idle is deliberately unaccented. Amber for "nothing has arrived yet"
    /// would make the ordinary state — a machine with no session running — look
    /// like a problem, which is the mirror image of the bug this strip fixes.
    private var healthTint: Color {
        switch pipeline.level {
        case .degraded: .red
        case .idle: .secondary
        case .healthy: .green
        }
    }

    private var statusLine: String {
        guard store.hudEnabled else { return "Hidden" }
        switch model.snapshot.sessionCount {
        case 0: return "No active sessions"
        case 1: return "1 session · \(model.snapshot.primary?.state.label ?? "")"
        case let n: return "\(n) sessions"
        }
    }

    private enum HookStatus: Equatable {
        case absent, stale, current

        var label: String {
            switch self {
            case .absent: "Not installed"
            case .stale: "Installed, out of date"
            case .current: "Installed"
            }
        }

        var actionTitle: String {
            switch self {
            case .absent: "Install Hooks…"
            case .stale: "Update Hooks"
            case .current: "Reinstall"
            }
        }
    }

    private var hookStatus: HookStatus {
        _ = hookRevision  // Re-reads whenever an install or removal bumps this.
        guard HookInstaller.isInstalled() else { return .absent }
        return HookInstaller.isCurrent(binaryPath: actions.notifyBinaryPath()) ? .current : .stale
    }

    // MARK: - Bindings with side effects

    /// Inverted so the label can be positive: a switch reading "Do Not Disturb"
    /// that is *on* when sounds are *off* has to be read twice every time.
    private var soundsBinding: Binding<Bool> {
        Binding(get: { !store.doNotDisturb }, set: { store.doNotDisturb = !$0 })
    }

    /// Both halves of a cue write through `SettingsStore`'s subscript, which
    /// lands on a stored property and persists on the way past — so a switch or
    /// a picker is on disk before the sound it describes can next fire.
    private func soundEnabledBinding(_ cue: SoundCue) -> Binding<Bool> {
        Binding(get: { store[cue].enabled }, set: { store[cue].enabled = $0 })
    }

    private func soundNameBinding(_ cue: SoundCue) -> Binding<String> {
        Binding(get: { store[cue].name }, set: { store[cue].name = $0 })
    }

    /// Not backed by `settings.json` — the real state lives in `SMAppService`,
    /// and mirroring it into our file would create a second answer that goes
    /// stale the moment the user changes it in System Settings.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { wanted in
                do {
                    try LoginItem.setEnabled(wanted)
                    if LoginItem.status == .requiresApproval { showApprovalNeeded() }
                } catch {
                    // `register()` itself throws once the user has switched the
                    // item off in System Settings, so re-check status rather
                    // than treat every throw as opaque.
                    if LoginItem.status == .requiresApproval {
                        showApprovalNeeded()
                    } else {
                        writeFailure = "Could not change the login item: \(error)"
                    }
                }
            })
    }

    private var forcedModeBinding: Binding<String> {
        Binding(
            get: { store.forcedMode ?? "" },
            set: { store.forcedMode = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Actions

    private func installHooks() {
        let notify = actions.notifyBinaryPath()
        do {
            let result = try HookInstaller.install(binaryPath: notify)
            var lines = ["\(result.installedEvents.count) events registered in settings.json."]
            if result.preservedOtherHooks > 0 {
                lines.append("\(result.preservedOtherHooks) hook(s) from other tools preserved.")
            }
            // Mirrors the CLI's --install-hooks, which wires the status line up
            // too. The menu bar route used to install only the hooks, so the
            // context window was silently inferred rather than read.
            switch try StatuslineInstaller.install(binaryPath: notify) {
            case .installed(let script, _):
                lines.append("Status line now forwarding from \(script).")
            case .alreadyInstalled:
                break
            case .skipped(let reason):
                lines.append("Status line skipped — \(reason.description). Context window "
                    + "will be inferred instead.")
            case .removed, .notPresent:
                break
            }
            if let backup = result.backupPath {
                lines.append("Backup: \((backup as NSString).lastPathComponent)")
            }
            report(lines.joined(separator: " "), isError: false)
        } catch {
            report("Could not install hooks: \(error)", isError: true)
        }
    }

    private func uninstallHooks() {
        do {
            _ = try HookInstaller.uninstall()
            var text = "ClaudeIsland's entries were removed from settings.json."
            if case .removed(let script) = try StatuslineInstaller.uninstall() {
                text += " The forwarding line was removed from \(script)."
            }
            report(text, isError: false)
        } catch {
            report("Could not remove hooks: \(error)", isError: true)
        }
    }

    private func copyHookJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            HookInstaller.hookBlockJSON(binaryPath: actions.notifyBinaryPath()), forType: .string)
        report("Hook JSON copied to the clipboard.", isError: false)
    }

    private func report(_ message: String, isError: Bool) {
        hookMessage = message
        hookMessageIsError = isError
        hookRevision += 1
        // Installing hooks wires the status line up too, and removing them takes
        // it out again — so the one figure on the strip that is read from disk
        // has to be re-read here, or General keeps reporting what was true
        // before the button on this pane was pressed.
        health.refreshStatusline()
    }

    private func showApprovalNeeded() {
        writeFailure =
            "Enable ClaudeIsland under System Settings → General → Login Items."
    }
}

/// How the three cues are named to someone who has never read the enum.
///
/// The case names describe the transition; these describe what the user saw
/// happen, which is the only way `waiting` and `inputRequired` can be told
/// apart — one is Claude blocked on an answer it cannot proceed without, the
/// other is Claude with nothing left to do until you type. They ring for
/// different reasons and the second one is the one people switch off, so a
/// label reading "Waiting" for either would make the wrong switch the obvious
/// one to hit.
extension SoundCue {
    fileprivate var settingsTitle: String {
        switch self {
        case .done: "A session finished"
        case .inputRequired: "A permission request needs an answer"
        case .waiting: "Claude is waiting on you"
        }
    }

    fileprivate var settingsCaption: String {
        switch self {
        case .done: "Claude stopped working and the card reads done."
        case .inputRequired:
            "A tool is asking to run, or Claude asked a question — the turn is blocked until "
                + "it is answered."
        case .waiting:
            "The idle nudge: nothing is blocked, Claude has just run out of things to do "
                + "until you type."
        }
    }
}
