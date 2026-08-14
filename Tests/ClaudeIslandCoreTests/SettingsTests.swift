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
            await expect(
                !s.aboveOtherNotchHUDs,
                "the HUD stays below other notch apps until asked — winning means "
                    + "drawing above the screen saver")
            await expect(
                s.preferredDisplay == nil,
                "no display is pinned by default — the HUD follows the menu bar")
            await expect(
                !s.muteWhileTerminalFrontmost,
                "the frontmost-terminal gate is opt-in — it changes what an install already does")
            await expectEqual(
                s.hoverOpenDelayMilliseconds, 150,
                "a fresh install waits out a pointer passing across the notch")
            await expect(
                s.showToolTrace,
                "the trail of finished calls is on by default — it is the card's answer to "
                    + "what the session has been doing")
            await expect(
                s[.done] == CueSound(enabled: true, name: "Glass")
                    && s[.inputRequired] == CueSound(enabled: true, name: "Ping")
                    && s[.waiting] == CueSound(enabled: true, name: "Pop"),
                "all three cues ring, with the sounds they always rang")
        }

        test("Every field round-trips through the file") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.hudEnabled = false
            s.doNotDisturb = true
            s.logging = true
            s.debugTint = true
            s.aboveOtherNotchHUDs = true
            s.forcedMode = "peek"
            s.muteWhileTerminalFrontmost = true
            s.preferredDisplay = "DELL P3223QE"
            s.hoverOpenDelayMilliseconds = 300
            s.showToolTrace = false
            s.doneSound = CueSound(enabled: false, name: "Hero")
            s.inputRequiredSound = CueSound(enabled: true, name: "Sosumi")
            s.waitingSound = CueSound(enabled: false, name: "Tink")
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
            // The upgrade path that matters for this key: every settings.json
            // written before the switch existed must keep the level it had, not
            // silently rise above the screen saver.
            await expect(
                !s.aboveOtherNotchHUDs,
                "a settings.json predating the switch stays below other notch apps")
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

        // MARK: - Per-cue sounds

        // The one that matters. Every settings.json on disk before per-cue
        // sounds existed looks exactly like this, and the upgrade has to be
        // inaudible: three cues on, ringing the three sounds that build
        // hardcoded. Anything else and installing an update silently changes —
        // or worse, silences — an alert someone relies on, with nothing in the
        // window to explain why it stopped.
        test("A settings file written before per-cue sounds still rings Glass, Ping and Pop") {
            let root = try tempRoot()
            try write(
                """
                {
                  "debugTint" : false,
                  "doNotDisturb" : false,
                  "hudEnabled" : true,
                  "logging" : false
                }
                """, "settings.json", in: root)

            let s = IslandSettings.load(root: root)
            for (cue, name) in [
                (SoundCue.done, "Glass"), (.inputRequired, "Ping"), (.waiting, "Pop"),
            ] {
                await expect(s[cue].enabled, "\(cue) came back switched off")
                await expectEqual(s[cue].name, name, "\(cue) came back with the wrong sound")
            }
            await expect(!s.doNotDisturb, "and nothing was muted globally either")
        }

        test("Each cue's choice round-trips on its own") {
            let root = try tempRoot()
            var s = IslandSettings()
            s[.waiting] = CueSound(enabled: false, name: "Purr")
            try s.save(root: root)

            let loaded = IslandSettings.load(root: root)
            await expect(
                loaded[.waiting] == CueSound(enabled: false, name: "Purr"),
                "the cue that was changed")
            await expect(
                loaded[.done] == SoundCue.done.defaultSound
                    && loaded[.inputRequired] == SoundCue.inputRequired.defaultSound,
                "the two that were not")
        }

        // Silencing a cue must not cost you the sound you picked for it — that is
        // the whole reason the switch and the name are stored side by side
        // rather than as one "off means no sound" field.
        test("A cue set to None keeps the sound it was set to") {
            let root = try tempRoot()
            var s = IslandSettings()
            s[.done] = CueSound(enabled: false, name: "Submarine")
            try s.save(root: root)
            await expectEqual(IslandSettings.load(root: root)[.done].name, "Submarine")
        }

        // MARK: - None

        // What the picker reads, and the only thing anything should ask when it
        // wants to know what a cue sounds like: a silenced cue's `name` is a
        // memory, not a sound, and a caller reaching for it would ring a cue the
        // user set to None.
        test("A cue reports its sound, or nothing when it is set to None") {
            await expectEqual(SoundCue.done.defaultSound.selectedName, "Glass")
            await expect(
                CueSound(enabled: false, name: "Submarine").selectedName == nil,
                "a silenced cue offered up the sound it is holding")
        }

        // The one rule that makes None safe to pick: it is not a way to lose the
        // sound you had. Someone silencing a cue for an afternoon has to be able
        // to put it back without remembering what it was.
        test("Picking None silences a cue and hands the sound back on the way out") {
            var sound = CueSound(enabled: true, name: "Submarine")
            sound.select(nil)
            await expect(sound.selectedName == nil, "None did not silence it")
            await expectEqual(sound.name, "Submarine", "None threw away the sound it was set to")

            sound.select("Submarine")
            await expectEqual(
                sound.selectedName, "Submarine", "coming back off None did not restore it")
        }

        test("Picking a sound for a silenced cue turns it back on") {
            var sound = CueSound(enabled: false, name: "Submarine")
            sound.select("Hero")
            await expectEqual(sound.selectedName, "Hero", "the newly picked sound does not ring")
        }

        // The picker's None row carries an empty tag, so the empty string has to
        // arrive here meaning None rather than being stored as a sound name that
        // could never resolve.
        test("An empty selection counts as None") {
            var sound = CueSound(enabled: true, name: "Submarine")
            sound.select("")
            await expect(sound.selectedName == nil, "an empty tag was taken for a sound")
            await expectEqual(sound.name, "Submarine", "and it kept the name, as None does")
        }

        // None is stored as `enabled: false`, which is what every build before it
        // already wrote for a switched-off cue and what an older build still
        // understands — the option is new, the file is not.
        test("None round-trips through the file as a silenced cue") {
            let root = try tempRoot()
            var s = IslandSettings()
            s[.inputRequired].select(nil)
            try s.save(root: root)

            let text = try String(
                contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
            await expect(
                text.contains(#""enabled" : false"#),
                "None wrote something an older build would not read as silent")

            let loaded = IslandSettings.load(root: root)
            await expect(loaded[.inputRequired].selectedName == nil, "None did not come back")
            await expectEqual(
                loaded[.inputRequired].name, "Ping", "and the sound to go back to was lost")
        }

        // Hand-editing is a documented way to use this file, and half a cue is
        // what a hand-edit produces.
        test("A cue object with no sound name in it takes the cue's default") {
            let root = try tempRoot()
            try write(#"{"waitingSound": {"enabled": false}}"#, "settings.json", in: root)
            let s = IslandSettings.load(root: root)
            await expect(!s[.waiting].enabled, "the half that was written won")
            await expectEqual(s[.waiting].name, "Pop", "the half that was not fell back")
        }

        // A default that is not in the list would draw a picker with nothing
        // selected on a fresh install — the setting would look broken before it
        // had ever been touched.
        test("Every cue's default sound is one the picker offers") {
            for cue in SoundCue.allCases {
                await expect(
                    SystemSound.all.contains(cue.defaultSoundName),
                    "\(cue) defaults to \(cue.defaultSoundName), which is not offered")
            }
        }

        // MARK: - Staying quiet while a terminal is frontmost

        test("The frontmost-terminal gate round-trips on its own") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.muteWhileTerminalFrontmost = true
            try s.save(root: root)

            let loaded = IslandSettings.load(root: root)
            await expect(loaded.muteWhileTerminalFrontmost, "the switch came back off")
            await expect(
                loaded == s, "and nothing else moved when it was written")
        }

        // The upgrade has to be inaudible in the other direction too: an install
        // that was ringing before this option existed must go on ringing exactly
        // as it did, wherever the user happens to be looking. A default of *on*
        // would silence cues on update with nothing in the window to explain it,
        // which is why absence has to decode as off rather than as "no preference
        // yet, pick the nice one".
        test("A settings file written before this option loads with it off") {
            let root = try tempRoot()
            try write(
                """
                {
                  "debugTint" : false,
                  "doNotDisturb" : false,
                  "doneSound" : { "enabled" : true, "name" : "Hero" },
                  "hudEnabled" : true,
                  "logging" : false
                }
                """, "settings.json", in: root)

            let s = IslandSettings.load(root: root)
            await expect(!s.muteWhileTerminalFrontmost, "an absent key turned the gate on")
            await expectEqual(s[.done].name, "Hero", "and the rest of the file still loaded")
        }

        // MARK: - Which display the HUD draws on

        test("The chosen display round-trips on its own") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.preferredDisplay = "DELL P3223QE"
            try s.save(root: root)

            let loaded = IslandSettings.load(root: root)
            await expectEqual(
                loaded.preferredDisplay, "DELL P3223QE", "the display came back wrong")
            await expect(loaded == s, "and nothing else moved when it was written")
        }

        // The upgrade path: every settings.json on disk before the HUD could be
        // moved has no such key, and those builds drew on the menu bar's display.
        // A default of anything else would relocate a working HUD on update.
        test("A settings file written before the display could be chosen keeps the menu bar") {
            let root = try tempRoot()
            try write(
                """
                {
                  "debugTint" : false,
                  "doNotDisturb" : false,
                  "doneSound" : { "enabled" : true, "name" : "Hero" },
                  "hudEnabled" : true,
                  "logging" : false,
                  "muteWhileTerminalFrontmost" : true
                }
                """, "settings.json", in: root)

            let s = IslandSettings.load(root: root)
            await expect(s.preferredDisplay == nil, "an absent key pinned a display")
            await expectEqual(s[.done].name, "Hero", "and the rest of the file still loaded")
            await expect(s.muteWhileTerminalFrontmost, "including the key next to it")
        }

        // Hand-editing is a documented way to use this file, and clearing a
        // string by emptying it is what a hand-edit looks like. Left as-is it
        // would be a display named "" that is never found and reports itself
        // missing in the picker forever.
        test("A blank display name means the menu bar, not a display called nothing") {
            let root = try tempRoot()
            try write(#"{"preferredDisplay": "   "}"#, "settings.json", in: root)
            await expect(IslandSettings.load(root: root).preferredDisplay == nil, "blank pinned")
        }

        test("A stored display name is kept verbatim, only trimmed") {
            let root = try tempRoot()
            try write(#"{"preferredDisplay": "  DELL P3223QE\n"}"#, "settings.json", in: root)
            await expectEqual(IslandSettings.load(root: root).preferredDisplay, "DELL P3223QE")
        }

        // MARK: - The hover delay

        test("The hover delay round-trips on its own") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.hoverOpenDelayMilliseconds = 275
            try s.save(root: root)

            let loaded = IslandSettings.load(root: root)
            await expectEqual(loaded.hoverOpenDelayMilliseconds, 275, "the delay came back wrong")
            await expect(loaded == s, "and nothing else moved when it was written")
        }

        // Instant is a setting, not an absence, and it is exactly what every
        // build before this one did. It has to survive a save/load cycle rather
        // than reading as "unset" and coming back as the default — otherwise the
        // one person who deliberately wants the old hair-trigger cannot keep it.
        test("A delay of zero is stored, not read as no preference") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.hoverOpenDelayMilliseconds = 0
            try s.save(root: root)
            await expectEqual(IslandSettings.load(root: root).hoverOpenDelayMilliseconds, 0)
        }

        // The upgrade path. An absent key means the new default rather than 0:
        // the hair-trigger open is the behaviour this setting exists to fix, so
        // an existing install should get the fix and can opt back out with the
        // slider. Nothing else about the file may shift on the way in.
        test("A settings file written before the hover delay loads with the default") {
            let root = try tempRoot()
            try write(
                """
                {
                  "debugTint" : false,
                  "doNotDisturb" : false,
                  "doneSound" : { "enabled" : true, "name" : "Hero" },
                  "hudEnabled" : true,
                  "logging" : false,
                  "muteWhileTerminalFrontmost" : true,
                  "preferredDisplay" : "DELL P3223QE"
                }
                """, "settings.json", in: root)

            let s = IslandSettings.load(root: root)
            await expectEqual(
                s.hoverOpenDelayMilliseconds, HoverDelay.default,
                "an absent key did not fall back to the default dwell")
            await expectEqual(s[.done].name, "Hero", "and the rest of the file still loaded")
            await expectEqual(s.preferredDisplay, "DELL P3223QE", "including the key next to it")
        }

        // Hand-editing is a documented way to use this file, and the failure it
        // can cause here is uniquely bad: a card that takes thirty seconds to
        // open is indistinguishable from a HUD that has stopped noticing hover,
        // and the pane that would explain it is the one you would never suspect.
        test("An out-of-range hover delay is clamped rather than honoured") {
            let root = try tempRoot()
            for (stored, wanted) in [(30000, 500), (501, 500), (-1, 0), (-30000, 0)] {
                try write(
                    #"{"hoverOpenDelayMilliseconds": \#(stored)}"#, "settings.json", in: root)
                await expectEqual(
                    IslandSettings.load(root: root).hoverOpenDelayMilliseconds, wanted,
                    "a stored \(stored) was not clamped")
            }
        }

        test("A hover delay inside the range is kept exactly") {
            let root = try tempRoot()
            for stored in [0, 1, 150, 499, 500] {
                try write(
                    #"{"hoverOpenDelayMilliseconds": \#(stored)}"#, "settings.json", in: root)
                await expectEqual(
                    IslandSettings.load(root: root).hoverOpenDelayMilliseconds, stored,
                    "a legal \(stored) was altered")
            }
        }

        // The monitor schedules a `Timer` with whatever this returns, so the
        // clamp has to hold on this path too — not only on the way off disk.
        test("The delay in seconds is clamped and in the unit a timer wants") {
            await expectEqual(HoverDelay.seconds(150), 0.15)
            await expectEqual(HoverDelay.seconds(0), 0, "instant must be exactly zero")
            await expectEqual(HoverDelay.seconds(30000), 0.5, "an absurd delay reached a timer")
            await expectEqual(HoverDelay.seconds(-5), 0)
        }

        test("The default delay is inside the range the pane offers") {
            await expect(
                HoverDelay.range.contains(HoverDelay.default),
                "the slider would open with its thumb off the end of its own track")
            await expect(
                HoverDelay.minimum == 0,
                "instant has to remain reachable — it is what every earlier build did")
        }

        // MARK: - The tool trace

        // Off is the whole point of the setting, and a false that reads back as
        // "unset" would come back on at the next launch — the failure the
        // sentinel files had, and the reason this file exists.
        test("A trace switched off stays off across a reload") {
            let root = try tempRoot()
            var s = IslandSettings()
            s.showToolTrace = false
            try s.save(root: root)

            let loaded = IslandSettings.load(root: root)
            await expect(!loaded.showToolTrace, "the trail came back switched on")
            await expect(loaded == s, "and nothing else moved when it was written")
        }

        // The upgrade path. Every settings.json written before this key existed
        // came from a build with no way to hide the trail, so an absent key has
        // to mean shown: an update that quietly removed a section of the card
        // would read as the card having lost it, not as a default changing.
        test("A settings file written before the trace switch still shows the trail") {
            let root = try tempRoot()
            try write(
                """
                {
                  "debugTint" : false,
                  "doNotDisturb" : false,
                  "hoverOpenDelayMilliseconds" : 275,
                  "hudEnabled" : true,
                  "logging" : false,
                  "preferredDisplay" : "DELL P3223QE"
                }
                """, "settings.json", in: root)

            let s = IslandSettings.load(root: root)
            await expect(s.showToolTrace, "an absent key hid the trail instead of showing it")
            await expectEqual(s.hoverOpenDelayMilliseconds, 275, "and the rest of the file loaded")
            await expectEqual(s.preferredDisplay, "DELL P3223QE", "including the key beside it")
        }

        // Hand-editing is documented, and this is the edit someone makes when
        // they have found the key in the file rather than the switch in the pane.
        test("The trace key is honoured from a hand-edited file") {
            let root = try tempRoot()
            try write(#"{"showToolTrace": false}"#, "settings.json", in: root)
            await expect(!IslandSettings.load(root: root).showToolTrace, "the hand-edit was ignored")
            try write(#"{"showToolTrace": true}"#, "settings.json", in: root)
            await expect(IslandSettings.load(root: root).showToolTrace, "true did not survive either")
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

    // The rule the stored name is read through. Expressed over a list of display
    // names rather than over `NSScreen` precisely so the case that matters — the
    // chosen monitor is not plugged in — can be written down here instead of
    // requiring somebody to pull a cable while watching the notch.
    suite("Display selection") {

        let attached = ["Built-in Retina Display", "DELL P3223QE", "LG UltraFine"]

        test("No preference means the display with the menu bar") {
            let r = DisplaySelection.resolve(preferred: nil, attached: attached, menuBarIndex: 0)
            await expectEqual(r?.index, 0)
            await expect(r?.missing == nil, "nothing is missing when nothing was asked for")
        }

        test("A chosen display that is attached is the one used") {
            let r = DisplaySelection.resolve(
                preferred: "DELL P3223QE", attached: attached, menuBarIndex: 0)
            await expectEqual(r?.index, 1)
            await expect(r?.missing == nil, "reported missing while plugged in")
        }

        test("Matching ignores case, because this name can be typed by hand") {
            await expectEqual(
                DisplaySelection.resolve(
                    preferred: "dell p3223qe", attached: attached, menuBarIndex: 0)?.index, 1)
        }

        // The one that matters. Unplugging a monitor must leave the HUD on a
        // screen that exists — not at coordinates that belong to nothing, and
        // not nowhere at all.
        test("A chosen display that is gone falls back to the menu bar's, and says so") {
            let stillHere = ["Built-in Retina Display", "DELL P3223QE"]
            let r = DisplaySelection.resolve(
                preferred: "LG UltraFine", attached: stillHere, menuBarIndex: 0)
            await expectEqual(r?.index, 0, "the HUD did not land on the menu bar's display")
            await expectEqual(r?.missing, "LG UltraFine", "the fallback went unreported")
        }

        // The fallback is "the display with the menu bar", not "the first one" —
        // and the two are only the same because AppKit happens to order that
        // array menu-bar-first.
        test("The fallback is the menu bar's display wherever it sits in the list") {
            let r = DisplaySelection.resolve(
                preferred: "Unplugged", attached: attached, menuBarIndex: 2)
            await expectEqual(r?.index, 2)
        }

        test("A nonsense menu-bar index still resolves to a real display") {
            let r = DisplaySelection.resolve(
                preferred: nil, attached: attached, menuBarIndex: 9)
            await expectEqual(
                r?.index, 0, "an out-of-range fallback must not become an off-screen panel")
        }

        test("No displays at all resolves to nothing") {
            await expect(
                DisplaySelection.resolve(preferred: "DELL P3223QE", attached: [], menuBarIndex: 0)
                    == nil,
                "there is no display to fall back to, and nobody to see it")
        }

        test("Blank and whitespace preferences read as no preference") {
            for blank in ["", "   ", "\n"] {
                let r = DisplaySelection.resolve(
                    preferred: blank, attached: attached, menuBarIndex: 1)
                await expectEqual(r?.index, 1, "blank \"\(blank)\" was not treated as unset")
                await expect(r?.missing == nil, "blank \"\(blank)\" was reported missing")
            }
        }

        // MARK: - What the picker offers

        test("The picker offers every attached display") {
            await expectEqual(DisplaySelection.options(attached: attached, chosen: nil), attached)
        }

        // A picker whose selection matches no row draws an empty one, which reads
        // as a setting that reset itself rather than one waiting for a cable.
        test("A remembered display that is unplugged is still offered") {
            let options = DisplaySelection.options(
                attached: ["Built-in Retina Display"], chosen: "LG UltraFine")
            await expectEqual(options, ["Built-in Retina Display", "LG UltraFine"])
        }

        test("A chosen display that is attached is not offered twice") {
            await expectEqual(
                DisplaySelection.options(attached: attached, chosen: "dell p3223qe"), attached)
        }

        // Two identical monitors report identical names. The second row would
        // carry the same tag as the first and could never be selected, so it
        // would be a row that does nothing — see DisplaySelection for the honest
        // account of what this costs.
        test("Two identical monitors collapse to one row") {
            await expectEqual(
                DisplaySelection.options(
                    attached: ["DELL P3223QE", "DELL P3223QE"], chosen: nil),
                ["DELL P3223QE"])
        }

        test("A blank stored choice adds no row") {
            await expectEqual(DisplaySelection.options(attached: attached, chosen: "  "), attached)
        }
    }
}
