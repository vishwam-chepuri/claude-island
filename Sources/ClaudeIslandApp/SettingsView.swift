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
}

struct SettingsView: View {
    @Bindable var store: SettingsStore
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

    /// The panes are deliberately uneven — Sounds holds one switch — because
    /// the even alternative is the single long form this replaced, where the
    /// hook controls and the debug pins sat one scroll apart from the setting
    /// most people came to change.
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

    /// Still dimmed while the HUD is off, exactly as it was when the two
    /// switches sat together. The reason for the dimming now lives a pane away
    /// — a real cost of the split, accepted rather than papered over with a
    /// caption that would only restate the General pane.
    /// Still dimmed while the HUD is off, exactly as it was when the two
    /// switches sat together. The reason for the dimming now lives a pane away
    /// — a real cost of the split, accepted rather than papered over with a
    /// caption that would only restate the General pane.
    private var soundsPane: some View {
        Form {
            Toggle("Play sounds", isOn: soundsBinding)
                .disabled(!store.hudEnabled)
        }
        .formStyle(.grouped)
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
