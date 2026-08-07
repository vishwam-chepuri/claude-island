import AppKit
import ClaudeIslandCore
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let log = IslandLog.fromEnvironment()
    private let nameResolver = SessionNameResolver()

    private var store: SessionStore!
    private var server: SocketServer!
    private var watcher: TranscriptWatcher!
    private var panel: IslandPanel!
    private var hoverMonitor: HoverMonitor!
    private var statusItem: NSStatusItem!
    private let model = IslandViewModel()

    private var socketTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var trackedTranscripts = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already implies this, but be explicit: the app must never
        // take focus, so it must never become a regular activation-policy app.
        NSApp.setActivationPolicy(.accessory)

        IslandPaths.ensureRoot()
        buildPanel()
        buildStatusItem()
        startPipeline()
        observeScreenChanges()
        log.debug("ClaudeIsland started")
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
        let resolver = nameResolver
        store = SessionStore(
            log: log,
            nameResolver: { [resolver] id in resolver.name(for: id) })

        watcher = TranscriptWatcher(log: log) { [weak self] update in
            Task { @MainActor [weak self] in
                await self?.store.applyTranscript(update)
            }
        }

        server = SocketServer(log: log)
        do {
            let stream = try server.start()
            socketTask = Task { [weak self] in
                for await envelope in stream {
                    await self?.handle(envelope)
                }
            }
        } catch {
            log.debug("socket failed to start: \(error)")
            presentSocketFailure(error)
        }

        snapshotTask = Task { [weak self] in
            guard let store = self?.store else { return }
            for await snapshot in await store.snapshots() {
                await MainActor.run { self?.apply(snapshot) }
            }
        }
    }

    private func handle(_ envelope: HookEnvelope) async {
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
        model.apply(snapshot)
        updateStatusItemGlyph()

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

    private func presentSocketFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ClaudeIsland could not open its socket"
        alert.informativeText =
            "\(error)\n\nThe HUD will run but receive no events. "
            + "Another copy may already be running."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "circle.dashed", accessibilityDescription: "ClaudeIsland")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }

    private func updateStatusItemGlyph() {
        let symbol: String
        if !model.isEnabled {
            symbol = "circle.dashed"
        } else if model.snapshot.primary?.state.isAlert == true {
            symbol = "exclamationmark.circle.fill"
        } else if model.snapshot.isDormant {
            symbol = "circle.dashed"
        } else {
            symbol = "circle.fill"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "ClaudeIsland")
        statusItem.button?.image?.isTemplate = true
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: model.isEnabled ? "Disable HUD" : "Enable HUD",
            action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let installed = HookInstaller.isInstalled()
        let install = NSMenuItem(
            title: installed ? "Reinstall Hooks" : "Install Hooks…",
            action: #selector(installHooks), keyEquivalent: "")
        install.target = self
        menu.addItem(install)

        if installed {
            let uninstall = NSMenuItem(
                title: "Remove Hooks", action: #selector(uninstallHooks), keyEquivalent: "")
            uninstall.target = self
            menu.addItem(uninstall)
        }

        let copyBlock = NSMenuItem(
            title: "Copy Hook JSON", action: #selector(copyHookBlock), keyEquivalent: "")
        copyBlock.target = self
        menu.addItem(copyBlock)

        menu.addItem(.separator())

        let logging = NSMenuItem(
            title: log.isEnabled ? "Disable Logging" : "Enable Logging",
            action: #selector(toggleLogging), keyEquivalent: "")
        logging.target = self
        menu.addItem(logging)

        let tint = NSMenuItem(
            title: model.debugTint ? "Hide Debug Tint" : "Show Debug Tint",
            action: #selector(toggleDebugTint), keyEquivalent: "")
        tint.target = self
        menu.addItem(tint)

        let reveal = NSMenuItem(
            title: "Reveal Support Folder", action: #selector(revealSupportFolder),
            keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ClaudeIsland", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private var statusLine: String {
        guard model.isEnabled else { return "HUD disabled" }
        let count = model.snapshot.sessionCount
        switch count {
        case 0: return "No active sessions"
        case 1: return "1 session · \(model.snapshot.primary?.state.label ?? "")"
        default: return "\(count) sessions"
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        model.setEnabled(!model.isEnabled)
        if model.isEnabled {
            panel.orderFrontRegardless()
            if !model.snapshot.isDormant { hoverMonitor.start() }
        } else {
            panel.orderOut(nil)
            hoverMonitor.stop()
        }
        syncInteractiveRect()
        updateStatusItemGlyph()
        rebuildMenu()
    }

    @objc private func installHooks() {
        do {
            let result = try HookInstaller.install(binaryPath: Self.notifyBinaryPath())
            let alert = NSAlert()
            alert.messageText = "Hooks installed"
            alert.informativeText = """
                \(result.installedEvents.count) events registered in ~/.claude/settings.json.
                \(result.preservedOtherHooks) existing hook(s) from other tools were preserved.
                Backup: \(result.backupPath.map { ($0 as NSString).lastPathComponent } ?? "none needed")

                Restart any running Claude Code sessions to pick them up.
                """
            alert.runModal()
        } catch {
            presentError("Could not install hooks", error)
        }
        rebuildMenu()
    }

    @objc private func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            let alert = NSAlert()
            alert.messageText = "Hooks removed"
            alert.informativeText = "Only ClaudeIsland's entries were removed."
            alert.runModal()
        } catch {
            presentError("Could not remove hooks", error)
        }
        rebuildMenu()
    }

    @objc private func copyHookBlock() {
        let text = HookInstaller.hookBlockJSON(binaryPath: Self.notifyBinaryPath())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleLogging() {
        let turningOn = !log.isEnabled
        log.setEnabled(turningOn)
        // Persist through the sentinel file so it survives a relaunch.
        if turningOn {
            FileManager.default.createFile(atPath: IslandPaths.debugFlag.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: IslandPaths.debugFlag)
        }
        rebuildMenu()
    }

    @objc private func toggleDebugTint() {
        model.debugTint.toggle()
        if model.debugTint {
            IslandPaths.ensureRoot()
            FileManager.default.createFile(atPath: IslandPaths.tintFlag.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: IslandPaths.tintFlag)
        }
        rebuildMenu()
    }

    @objc private func revealSupportFolder() {
        IslandPaths.ensureRoot()
        NSWorkspace.shared.activateFileViewerSelecting([IslandPaths.root])
    }

    @objc private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Lifecycle

    private func shutdown() {
        socketTask?.cancel()
        snapshotTask?.cancel()
        server?.stop()
        watcher?.stop()
        hoverMonitor?.stop()
        model.shutdown()
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
