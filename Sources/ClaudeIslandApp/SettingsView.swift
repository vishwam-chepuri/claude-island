import AppKit
import ClaudeIslandCore
import Combine
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

    /// Pinned open, and the toggle that would unpin it is removed below — a
    /// sidebar the user can lose is one they cannot ask for again. Five fixed
    /// panes are the whole of this window's navigation; collapsing them leaves a
    /// detail column with no way to say which pane it is showing.
    @State private var columns = NavigationSplitViewVisibility.all

    /// The displays attached right now, re-read whenever the window learns they
    /// changed. Held in state rather than asked for inside `body`: SwiftUI has no
    /// reason to re-run a view because a monitor was unplugged, so a picker that
    /// read `NSScreen.screens` directly would go on offering a display that is no
    /// longer there for as long as the window stayed open.
    @State private var displays: [String] = []

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
            // The toolbar this split view hangs off the window — a sidebar
            // toggle for a sidebar that is pinned, and a tracking separator that
            // truncated the window's title to fit the sidebar's column — is
            // refused by the window itself. `.toolbar(removing:)` and
            // `.toolbar(.hidden, for: .windowToolbar)` are both no-ops from
            // inside an `NSHostingView`: photographed against a window with and
            // without them, the two captures were identical to the byte. See
            // `SettingsWindow`.
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            store.onWriteFailure = { error in
                writeFailure = "Could not save settings: \(error)"
            }
            displays = NotchGeometryResolver.attachedDisplayNames()
        }
        // On the window rather than on the General pane: the same notification is
        // what moves the HUD (see `AppController.observeScreenChanges`), and a
        // list refreshed only while its own pane happens to be showing would be
        // stale exactly when someone switches to it to find out where the island
        // went.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            displays = NotchGeometryResolver.attachedDisplayNames()
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

    /// Which display the island draws on.
    ///
    /// On Appearance, directly under the preview, because the preview is this
    /// row's own answer: it resolves the shape against whichever display is
    /// chosen here, so a notched panel previews a notch and anything else
    /// previews the pill. Picking a display on one pane to see what it did on
    /// another was the arrangement this replaced, and it made the preview look
    /// like decoration rather than the readout it is.
    ///
    /// The caption only appears when the chosen display is missing. A row that
    /// explained itself at all times would be four lines of prose above "Launch
    /// at login" for the single-display majority, who never touch this.
    private var displayRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Show it on", selection: preferredDisplayBinding) {
                // The default is a rule, not a display: it follows the menu bar
                // wherever that moves, which is not the same as naming the
                // display the menu bar happens to be on today. No separator
                // under it — a `Divider` in a `Picker` renders as a real row on
                // some macOS versions, and an inert row in a two-item menu is a
                // worse bug than the missing hairline it was meant to be.
                Text("The display with the menu bar").tag("")
                ForEach(displayOptions, id: \.self) { name in
                    // The remembered-but-absent display is offered too, marked as
                    // such — see `DisplaySelection.options`. Without it the picker
                    // would draw an empty row for a selection matching no tag,
                    // which reads as a setting that reset itself rather than one
                    // being honoured as soon as the cable goes back in.
                    Text(isAttached(name) ? name : "\(name) — not connected").tag(name)
                }
            }
            if let missing = missingDisplay {
                Text(
                    "\(missing) is not connected. The HUD is on the display with the menu bar "
                        + "until it is back — the choice is kept, not reset."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// How long the pointer must rest on the island before the card opens.
    ///
    /// On Appearance under the display picker, because the tier it gates is the
    /// one the preview above puts on screen: Peek is what this delay stands
    /// between the pointer and, and the segment marked Peek is a click away
    /// while the slider is being dragged. It is also the row someone comes
    /// looking for after the card popped open while they were reaching for the
    /// menu bar — a complaint about the island appearing when it should not,
    /// which is the pane that shows the island appearing.
    ///
    /// A slider rather than a Short/Medium/Long picker: the range is narrow,
    /// every value in it is usable, and what is being chosen is a feel — judged
    /// by dragging it and then hovering the real island, not by reading three
    /// words and guessing what they mean in milliseconds.
    ///
    /// The caption is always present, unlike the display row's. Both ends of
    /// this slider are legitimate settings that behave visibly differently, and
    /// the asymmetry it promises — only opening waits — is the one thing about
    /// this control that cannot be inferred from the control.
    private var hoverDelayRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Writes on every step it crosses, so one drag can persist twenty
            // times. Deliberate: each is a small atomic write to a file every
            // other control here already rewrites on each click, and committing
            // only on release is how a setting ends up lost when the window is
            // closed with the thumb still held.
            Slider(
                value: hoverDelayBinding,
                in: Double(HoverDelay.minimum)...Double(HoverDelay.maximum),
                step: 25
            ) {
                Text("Open on hover after")
            } minimumValueLabel: {
                Text("Instant")
            } maximumValueLabel: {
                Text("0.5s")
            }
            // The slider reads as a bare number otherwise, and "150" is not an
            // answer to "after what".
            .accessibilityValue(hoverDelayValueLabel)
            Text(hoverDelayCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Milliseconds, spelled the way the settings file spells them, so the
    /// caption and a hand-edit are talking about the same number.
    private var hoverDelayValueLabel: String {
        store.hoverOpenDelayMilliseconds == 0
            ? "Instant" : "\(store.hoverOpenDelayMilliseconds) ms"
    }

    private var hoverDelayCaption: String {
        guard store.hoverOpenDelayMilliseconds > 0 else {
            return "The card opens the instant the pointer touches the island — including "
                + "when it is only crossing the top of the screen on its way somewhere else."
        }
        return "The pointer has to rest on the island for \(hoverDelayValueLabel) before the "
            + "card opens, so a pointer merely crossing the top of the screen leaves it "
            + "closed. Moving away always closes it at once — only opening waits."
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
    /// question — "what is this thing going to look like on my screen" — as well
    /// as asking one, and behind the hook plumbing it would only be found by
    /// people who were already looking for it.
    ///
    /// The preview is fed made-up sessions and driven by a view model of its own;
    /// see `IslandPreviewSource` for why that second model is not an optimisation
    /// but the whole safety property.
    ///
    /// The two rows under it are the settings the preview is a picture of — which
    /// display the island takes its shape from, and how long the pointer waits
    /// for Peek. Both used to live on General, where changing one meant switching
    /// panes to see what it had done.
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
            Section {
                displayRow
                hoverDelayRow
            }
        }
        .formStyle(.grouped)
    }

    /// The two global gates at the top, then a row per cue.
    ///
    /// Both gates sit above the rows because both outrank them: the mute stops
    /// everything, and the frontmost-app switch stops everything while a terminal
    /// has focus. Reading downwards, the pane answers "can anything ring", then
    /// "can anything ring right now", then "what rings for what".
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
                Toggle(
                    "Stay quiet while a terminal is frontmost",
                    isOn: $store.muteWhileTerminalFrontmost)
            } footer: {
                // Says what it does, not what it is for. "Don't interrupt while
                // I'm watching the session" is the reason to want this and would
                // be the friendlier label, but it promises something this cannot
                // know: it sees which app has focus, never which app a session is
                // running in. The second sentence is the honest half — someone
                // hitting the false positive should be able to recognise it here
                // rather than file it as sounds having randomly stopped.
                Text(
                    "Skips the sound — never the alert on the island — while Terminal, iTerm2, "
                        + "Ghostty, VS Code, Xcode or another terminal or editor is the app in "
                        + "front. It can only tell which app you are in, not which one a session "
                        + "is running in, so a session in a window you cannot see goes quiet too."
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
                Text(cuesFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .disabled(!store.hudEnabled)
    }

    /// The cue rows' footer, which exists mostly to promise that Play still works.
    ///
    /// A row can be silent for a reason the row itself does not show, so the
    /// footer names whichever global gate is currently holding it down — the mute
    /// first, since it outranks the other. The promise is the constant part: the
    /// button rings whatever any of this says, because a preview answering with
    /// silence is indistinguishable from a broken button, and auditioning a sound
    /// with your terminal in front is precisely when it gets pressed.
    private var cuesFooter: String {
        switch (store.doNotDisturb, store.muteWhileTerminalFrontmost) {
        case (true, _):
            "None of these will ring while Play sounds is off. Play previews the chosen sound "
                + "anyway."
        case (false, true):
            "None of these will ring while a terminal is frontmost. Play previews the chosen "
                + "sound anyway."
        case (false, false):
            "Play previews the chosen sound, whatever these switches say."
        }
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

    /// `debugTint` deliberately has no row here. It is an authoring aid rather
    /// than a preference — switched on by accident it just makes the HUD look
    /// broken — and `touch ~/.claude-island/tint` already covers both uses:
    /// iterating on the shape, and a bug reporter showing where the island
    /// actually landed on a display it landed wrong on. See README, "Debug tint".
    private var advancedPane: some View {
        Form {
            Section {
                Toggle("Write a debug log", isOn: $store.logging)
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

    /// Every attached display, plus the stored choice when that is not one of
    /// them. Duplicate names collapse — two identical monitors are one row, and
    /// `DisplaySelection` says why that cannot be fixed here.
    private var displayOptions: [String] {
        DisplaySelection.options(attached: displays, chosen: store.preferredDisplay)
    }

    private func isAttached(_ name: String) -> Bool {
        displays.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The chosen display's name when it is not attached, for the caption.
    private var missingDisplay: String? {
        guard let chosen = DisplaySelection.normalized(store.preferredDisplay),
            !isAttached(chosen)
        else { return nil }
        return chosen
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

    /// Empty tag means the menu bar's display, the same way an absent key does in
    /// `settings.json` — so the default row and a file with nothing in it agree.
    private var preferredDisplayBinding: Binding<String> {
        Binding(
            get: { canonicalDisplayName(store.preferredDisplay) ?? "" },
            set: { store.preferredDisplay = DisplaySelection.normalized($0) })
    }

    /// The slider works in `Double`; the setting is a whole number of
    /// milliseconds. Rounded rather than truncated so a step lands on the value
    /// under the thumb, and clamped because nothing downstream should have to
    /// wonder whether a slider was bounded the way it looks.
    private var hoverDelayBinding: Binding<Double> {
        Binding(
            get: { Double(store.hoverOpenDelayMilliseconds) },
            set: { store.hoverOpenDelayMilliseconds = HoverDelay.clamped(Int($0.rounded())) })
    }

    /// The stored name spelled the way this picker's tags spell it.
    ///
    /// Resolution is case-insensitive, because the file is hand-editable — but a
    /// `Picker` compares tags exactly, so a hand-edited "dell p3223qe" would
    /// drive the HUD to the right display and still draw an empty row, which is
    /// the one thing this pane is careful never to do. Canonicalised for display
    /// only: nothing is written back, because rewriting the setting on the
    /// strength of what happens to be plugged in is precisely what the fallback
    /// must not do.
    private func canonicalDisplayName(_ stored: String?) -> String? {
        guard let stored = DisplaySelection.normalized(stored) else { return nil }
        return displays.first { $0.caseInsensitiveCompare(stored) == .orderedSame } ?? stored
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
