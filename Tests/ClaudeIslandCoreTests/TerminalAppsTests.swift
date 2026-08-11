import ClaudeIslandCore
import Foundation

func registerTerminalAppsTests() {
    suite("Frontmost apps") {

        // The list is the whole feature — a bundle id that does not match is a
        // terminal that goes on chiming at someone who asked it not to, and
        // nothing in the UI would explain why. Spelled out one id at a time
        // rather than looped over `TerminalApps.bundleIDs`, which would only
        // prove the list matches itself.
        test("The terminals and editors we claim to know are matched") {
            for id in [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "com.mitchellh.ghostty",
                "com.github.wez.wezterm",
                "dev.warp.Warp-Stable",
                "org.alacritty",
                "net.kovidgoyal.kitty",
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                "com.todesktop.230313mzl4w4u92",  // Cursor
                "com.apple.dt.Xcode",
                "com.jetbrains.intellij",
                "com.jetbrains.pycharm",
                "com.jetbrains.goland",
                "com.google.android.studio",
                "dev.zed.Zed",
                "co.zeit.hyper",
            ] {
                await expect(TerminalApps.matches(bundleID: id), "\(id) is not recognised")
            }
        }

        // Channel suffixes are why those three families are matched by prefix:
        // Zed and Warp both ship several, and JetBrains ships a dozen products.
        test("Release channels and other JetBrains products come along") {
            for id in ["dev.zed.Zed-Preview", "dev.warp.Warp-Preview", "com.jetbrains.WebStorm"] {
                await expect(TerminalApps.matches(bundleID: id), "\(id) is not recognised")
            }
        }

        // The direction that matters more. Over-matching here means a cue the
        // user configured never rings, in a window where nothing about the app in
        // front looks related to Claude Code at all.
        test("An app that is not a terminal or editor does not match") {
            for id in [
                "com.apple.Safari", "com.apple.finder", "com.apple.mail",
                "com.tinyspeck.slackmacgap", "com.spotify.client", "us.zoom.xos",
                "com.apple.systempreferences",
            ] {
                await expect(!TerminalApps.matches(bundleID: id), "\(id) was taken for a terminal")
            }
        }

        // Unknown must mean "not a terminal", so the fallback is to ring. A nil
        // id is ordinary — an app with no bundle identifier is frontmost — and
        // silence there would be a HUD that stopped making noise for a reason
        // nobody could see or undo.
        test("An unknown or missing bundle id is not a terminal") {
            await expect(!TerminalApps.matches(bundleID: nil), "nil matched")
            await expect(!TerminalApps.matches(bundleID: ""), "an empty id matched")
            await expect(
                !TerminalApps.matches(bundleID: "com.example.something"), "an unknown id matched")
        }

        // LaunchServices treats bundle ids case-insensitively and Info.plists are
        // inconsistent about capitalisation, so matching must be too — otherwise
        // an entry typed the way its vendor writes it silently never fires.
        test("Matching ignores case, in the list and in the id") {
            await expect(
                TerminalApps.matches(bundleID: "COM.APPLE.TERMINAL"), "an upper-cased id missed")
            await expect(
                TerminalApps.matches(bundleID: "com.googlecode.iTerm2"), "iTerm2's own case missed")
            await expect(
                TerminalApps.matches(bundleID: "com.microsoft.vscode"), "a lower-cased id missed")
            await expect(
                TerminalApps.matches(bundleID: "COM.JETBRAINS.RubyMine"), "a prefix missed on case")
        }

        // A prefix entry has to be a whole reverse-DNS component or it will reach
        // things nobody meant it to — "dev.zed" without the dot would swallow
        // some future "dev.zedditor".
        test("Every prefix ends at a component boundary") {
            for prefix in TerminalApps.bundleIDPrefixes {
                await expect(prefix.hasSuffix("."), "\(prefix) does not end at a dot")
            }
        }
    }
}
