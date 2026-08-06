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
          ClaudeIslandApp                     Run the HUD (menu bar only).
          ClaudeIslandApp --replay <file>     Feed a recorded JSONL event log
                                              through the full pipeline with no
                                              UI and print the state trace.
          ClaudeIslandApp --print-hooks       Print the settings.json hook block.
          ClaudeIslandApp --install-hooks     Merge hooks into ~/.claude/settings.json,
                                              preserving any existing entries.
          ClaudeIslandApp --uninstall-hooks   Remove only ClaudeIsland's entries.
          ClaudeIslandApp --probe-screens     Print notch geometry for each display.
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

func probeScreens() -> Int32 {
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
        let result = try HookInstaller.install(binaryPath: AppController.notifyBinaryPath())
        print("Installed \(result.installedEvents.count) hook events.")
        print("Preserved \(result.preservedOtherHooks) hook(s) belonging to other tools.")
        if let backup = result.backupPath { print("Backup: \(backup)") }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
        exit(1)
    }

case "--uninstall-hooks":
    do {
        try HookInstaller.uninstall()
        print("Removed ClaudeIsland hook entries.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
        exit(1)
    }

case "--probe-screens":
    exit(probeScreens())

case "--selftest":
    // Briefly moves the cursor to probe the hit region, then puts it back.
    _ = NSApplication.shared
    exit(await SelfTest.run())

case .some(let unknown) where unknown.hasPrefix("-"):
    FileHandle.standardError.write(Data("unknown option: \(unknown)\n".utf8))
    printUsage()
    exit(2)

default:
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
