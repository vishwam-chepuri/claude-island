import AppKit
import ClaudeIslandCore
import Foundation

// Headless entry points run and exit before any AppKit state is touched, so
// --replay works over SSH, in CI, and with no window server at all.

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print(
        """
        ClaudeIsland — a Dynamic Island-style HUD for Claude Code sessions.

        USAGE
          ClaudeIslandApp                     Run the HUD (no Dock or menu bar icon).
          ClaudeIslandApp --settings          Run the HUD and open the settings
                                              window. Launching the app again
                                              while it is running does the same.
          ClaudeIslandApp --replay <file>     Feed a recorded JSONL event log
                                              through the full pipeline with no
                                              UI and print the state trace.
          ClaudeIslandApp --print-hooks       Print the settings.json hook block.
          ClaudeIslandApp --install-hooks     Merge hooks into ~/.claude/settings.json,
                                              preserving any existing entries.
          ClaudeIslandApp --uninstall-hooks   Remove only ClaudeIsland's entries.
          ClaudeIslandApp --probe-screens [display]
                                              Print notch geometry for each display,
                                              and which one the HUD would draw on.
                                              Naming a display tries that choice
                                              without saving it — including one
                                              that is not plugged in, to see the
                                              fallback.
          ClaudeIslandApp --selftest          Verify focus and click-through behaviour.
                                              Moves the cursor briefly, then restores it.
          ClaudeIslandApp --help
        """)
}

func runReplay(_ path: String) async -> Int32 {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
        return 2
    }
    do {
        let output = try await ReplayDriver().run(fileURL: url)
        print(output.text)
        print("")
        print("\(output.decodedCount) events replayed, \(output.skippedCount) skipped")
        print("\(output.finalSessions.count) session(s) still tracked at end")
        for session in output.finalSessions {
            let modelName = Format.model(session.model).map { " · \($0)" } ?? ""
            print(
                "  \(session.displayName)\(modelName) — \(session.state.traceName), "
                    + "\(session.recentTools.count) recent tool(s)")
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("replay failed: \(error)\n".utf8))
        return 1
    }
}

/// Geometry per display, and where the HUD would put itself.
///
/// `override` stands in for the stored preference, which is the only way to see
/// what happens to a display that is not plugged in without editing the settings
/// file of a running app — or unplugging something. Naming a display that is not
/// attached is a legitimate use of it, not a mistake: the fallback is the
/// interesting half of this feature and this is how you watch it happen.
func probeScreens(override: String?) -> Int32 {
    for screen in NSScreen.screens {
        let g = NotchGeometryResolver.resolve(for: screen)
        print("\(screen.localizedName)")
        print("  frame        \(screen.frame)")
        print("  safeArea.top \(screen.safeAreaInsets.top)")
        print("  auxLeft      \(screen.auxiliaryTopLeftArea.map(String.init(describing:)) ?? "nil")")
        print(
            "  auxRight     \(screen.auxiliaryTopRightArea.map(String.init(describing:)) ?? "nil")")
        print("  -> \(g.hasNotch ? "NOTCH" : "PILL") island \(g.islandRect)")
        print("     panel \(g.panelRect)")
    }
    if let menuBar = NotchGeometryResolver.menuBarScreen() {
        print("\nmenu bar screen: \(menuBar.localizedName)")
    }
    // Which display the HUD would use right now, which is a different question
    // from what is stored: the setting names a display that may not be plugged
    // in, and the whole point of this probe is to be able to see that from a
    // terminal rather than by looking at the notch. `load`, never `bootstrap` —
    // a probe must not write to the settings file of a running app.
    let preferred = override ?? IslandSettings.load().preferredDisplay
    print(
        "preferred display: \(preferred ?? "(none — the menu bar's)")"
            + (override == nil ? "" : "  [from the command line, not settings.json]"))
    if let resolved = NotchGeometryResolver.resolveDisplay(preferred: preferred) {
        print("drawing on: \(resolved.screen.localizedName)")
        if let missing = resolved.missing {
            print("  \"\(missing)\" is not attached — fell back to the menu bar's display")
        }
    }
    return 0
}

switch arguments.first {
case "--help", "-h":
    printUsage()
    exit(0)

case "--replay":
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data("--replay requires a file path\n".utf8))
        exit(2)
    }
    exit(await runReplay(arguments[1]))

case "--print-hooks":
    print(HookInstaller.hookBlockJSON(binaryPath: AppController.notifyBinaryPath()))
    exit(0)

case "--install-hooks":
    do {
        let notify = AppController.notifyBinaryPath()
        let result = try HookInstaller.install(binaryPath: notify)
        print("Installed \(result.installedEvents.count) hook events.")
        print("Preserved \(result.preservedOtherHooks) hook(s) belonging to other tools.")
        if let backup = result.backupPath { print("Backup: \(backup)") }

        // The status line is where Claude Code publishes the exact context
        // window. Optional: without it the window is inferred, and everything
        // else still works.
        switch try StatuslineInstaller.install(binaryPath: notify) {
        case .installed(let script, let backup):
            print("Status line: forwarding from \(script).")
            if let backup { print("Backup: \(backup)") }
        case .alreadyInstalled(let script):
            print("Status line: already forwarding from \(script).")
        case .skipped(let reason):
            print("Status line: skipped — \(reason.description).")
            print("  The context window will be inferred instead. To wire it up by hand,")
            print("  add this after your status-line script reads stdin:")
            print("    \(StatuslineInstaller.forwardLine(binaryPath: notify))")
        case .removed, .notPresent:
            break
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
        exit(1)
    }

case "--uninstall-hooks":
    do {
        try HookInstaller.uninstall()
        print("Removed ClaudeIsland hook entries.")
        if case .removed(let script) = try StatuslineInstaller.uninstall() {
            print("Removed the status-line forward line from \(script).")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
        exit(1)
    }

case "--probe-screens":
    // A leading dash is a mistyped flag, not a display: no monitor is called
    // "--selftest", and silently probing for one would answer a question nobody
    // asked with a fallback that looks like a result.
    exit(probeScreens(override: arguments.dropFirst().first { !$0.hasPrefix("-") }))

case "--selftest":
    // Briefly moves the cursor to probe the hit region, then puts it back.
    _ = NSApplication.shared
    exit(await SelfTest.run())

case .some(let unknown) where unknown.hasPrefix("-") && unknown != "--settings":
    FileHandle.standardError.write(Data("unknown option: \(unknown)\n".utf8))
    printUsage()
    exit(2)

default:
    // Before anything reads settings: this folds any leftover sentinel file
    // into settings.json and reports whether this is a fresh install.
    let hadSettings = FileManager.default.fileExists(atPath: IslandSettings.path.path)
    let settings = IslandSettings.bootstrap()

    let app = NSApplication.shared
    let controller = AppController(
        settings: settings,
        opensSettingsAtLaunch: !hadSettings || arguments.first == "--settings")
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
