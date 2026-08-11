import ClaudeIslandCore
import Foundation

private func tempRoot() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("island-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ body: String, _ name: String, in root: URL) throws {
    try body.write(
        to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

private func exists(_ name: String, in root: URL) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
}

func registerSettingsTests() {
    suite("Settings") {

        test("Defaults are what an install with no file gets") {
            let root = try tempRoot()
            let s = IslandSettings.load(root: root)
            await expect(s.hudEnabled, "HUD on by default")
            await expect(!s.doNotDisturb, "sounds on by default")
            await expect(!s.logging, "logging off by default")
            await expect(!s.debugTint, "tint off by default")
            await expect(s.forcedMode == nil, "not pinned by default")
        }

        test("Every field round-trips through the file") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.hudEnabled = false
            s.doNotDisturb = true
            s.logging = true
            s.debugTint = true
            s.forcedMode = "peek"
            try s.save(root: root)

            await expect(IslandSettings.load(root: root) == s, "loaded settings match what was saved")
        }

        // The whole reason this replaced the sentinel files: a HUD switched off
        // in the settings window used to come back on at every launch, because
        // `isEnabled` was the one toggle with nothing behind it.
        test("A disabled HUD stays disabled across a reload") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.hudEnabled = false
            try s.save(root: root)
            await expect(!IslandSettings.load(root: root).hudEnabled, "HUD still off")
        }

        test("A corrupt file loads as defaults rather than failing") {
            let root = try tempRoot()
            try write("{ this is not json", "settings.json", in: root)
            await expect(IslandSettings.load(root: root) == IslandSettings(), "fell back to defaults")
        }

        test("A file missing keys keeps the default for each") {
            let root = try tempRoot()
            try write(#"{"logging": true}"#, "settings.json", in: root)
            let s = IslandSettings.load(root: root)
            await expect(s.logging, "the key that was present won")
            await expect(s.hudEnabled, "a missing hudEnabled still defaults to true, not false")
            await expect(s.forcedMode == nil, "a missing forcedMode is absent, not empty")
        }

        test("Saving writes readable, stable JSON") {
            let root = try tempRoot()
            try IslandSettings().save(root: root)
            let text = try String(
                contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
            await expect(text.contains("\n"), "pretty-printed rather than one line")
            await expect(text.hasSuffix("\n"), "ends with a newline")
            await expect(
                text.range(of: "debugTint")!.lowerBound < text.range(of: "hudEnabled")!.lowerBound,
                "keys are sorted, so the file diffs cleanly")
        }

        // MARK: - Migration off the sentinel files

        test("Each sentinel file migrates into settings.json and is deleted") {
            let root = try tempRoot()
            try write("", "dnd", in: root)
            try write("", "debug", in: root)
            try write("", "tint", in: root)
            try write("peek\n", "force-mode", in: root)

            let s = IslandSettings.bootstrap(root: root)
            await expect(s.doNotDisturb, "dnd migrated")
            await expect(s.logging, "debug migrated")
            await expect(s.debugTint, "tint migrated")
            await expect(s.forcedMode == "peek", "force-mode migrated, trimmed")

            await expect(!exists("dnd", in: root), "dnd consumed")
            await expect(!exists("debug", in: root), "debug consumed")
            await expect(!exists("tint", in: root), "tint consumed")
            await expect(!exists("force-mode", in: root), "force-mode consumed")

            await expect(
                IslandSettings.load(root: root) == s,
                "the migrated values were persisted, not just returned")
        }

        test("A sentinel overrides the stored value, then stops existing") {
            let root = try tempRoot()
            try IslandSettings().save(root: root)  // logging: false
            try write("", "debug", in: root)

            await expect(IslandSettings.bootstrap(root: root).logging, "the touch turned logging on")
            // Second run: nothing left to consume, so the stored value stands
            // and can be turned back off from the window without the file
            // resurrecting it.
            await expect(IslandSettings.bootstrap(root: root).logging, "still on, from the JSON")
            var off = IslandSettings.load(root: root)
            off.logging = false
            try off.save(root: root)
            await expect(!IslandSettings.bootstrap(root: root).logging, "and it can be turned off")
        }

        test("An empty force-mode file pins nothing") {
            let root = try tempRoot()
            try write("\n", "force-mode", in: root)
            await expect(IslandSettings.bootstrap(root: root).forcedMode == nil, "not pinned")
        }

        test("Bootstrap on a clean root writes the file without inventing state") {
            let root = try tempRoot()
            let s = IslandSettings.bootstrap(root: root)
            await expect(s == IslandSettings(), "defaults")
            await expect(exists("settings.json", in: root), "the file now exists to be edited")
        }

        test("Bootstrap leaves an untouched settings file alone") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.forcedMode = "expanded"
            try s.save(root: root)
            await expect(IslandSettings.bootstrap(root: root) == s, "unchanged")
        }
    }
}
