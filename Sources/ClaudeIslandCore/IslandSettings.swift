import Foundation

/// The alert sounds macOS ships in `/System/Library/Sounds`, which is what the
/// settings picker offers.
///
/// Hardcoded rather than read off the disk. Scanning that directory would pick
/// up whatever a future macOS adds — and anything the user dropped into
/// `~/Library/Sounds` — but the offered list would then differ between machines,
/// which is exactly the kind of thing a test cannot pin down and a bug report
/// cannot describe. This set has gone unchanged for many macOS releases; the
/// price of fixing it here is that a genuinely new system sound needs a code
/// change before it can be picked.
///
/// Names, not sounds: `NSSound` lives in AppKit and Core does not import it, so
/// nothing here can tell whether a name still resolves. That check belongs to
/// whoever rings it — see `AppController.sound(for:named:)`.
public enum SystemSound {
    /// Alphabetical, because a picker is scanned for a name. The three defaults
    /// are left scattered through it rather than promoted to the top: this is a
    /// list, not a ranking, and a familiar order beats a helpful one.
    public static let all = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
        "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
}

/// One cue's audio settings: whether it rings at all, and with what.
///
/// The settings pane offers these as one control — a picker of sound names with
/// **None** at the top — but they stay two stored fields, because keeping the
/// name while the cue is silent is the point: picking None and changing your
/// mind must not cost you the sound you had. See `select(_:)`.
///
/// Two fields is also what every settings.json already on disk holds, and what
/// an older build reading a file this one wrote still understands: `enabled`
/// false means silent there exactly as None means silent here. A dedicated
/// "none" spelling of `name` would have needed a migration in both directions.
public struct CueSound: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// A name from `SystemSound.all`. Free-form on purpose: the file is meant to
    /// be hand-editable, and a name this build does not list may still resolve
    /// on the machine that wrote it.
    ///
    /// Holds the last sound picked even while `enabled` is false, so it is not
    /// what rings — `selectedName` is.
    public var name: String

    public init(enabled: Bool = true, name: String) {
        self.enabled = enabled
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // No default for the name here: this type does not know which cue it
        // belongs to, and every cue has a different one. `IslandSettings` fills
        // the blank in, since it is the only place that knows.
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

extension CueSound {
    /// What the picker shows, and what would ring: a sound name, or nil for None.
    ///
    /// Every reader that wants "the sound this cue makes" wants this rather than
    /// `name`, which keeps its value through a spell of silence.
    public var selectedName: String? { enabled ? name : nil }

    /// Takes a picker selection — a sound name, or nil for None.
    ///
    /// The whole reason this is a method rather than two assignments at the call
    /// site: choosing None deliberately leaves `name` alone. Silencing a cue and
    /// silencing it *and forgetting what it rang* are a keystroke apart in the
    /// picker, and only one of them is what anybody meant.
    ///
    /// An empty name counts as None, because that is the tag SwiftUI needs for a
    /// picker row that stands for "nothing" — and because a `name` of `""` could
    /// not resolve to a sound anyway.
    public mutating func select(_ name: String?) {
        guard let name, !name.isEmpty else {
            enabled = false
            return
        }
        self.name = name
        enabled = true
    }
}

extension SoundCue {
    /// The sound this cue rang back when all three were hardcoded.
    ///
    /// Also the fallback for a stored name that no longer resolves, which is
    /// why it lives on the cue rather than only in `IslandSettings()`.
    public var defaultSoundName: String {
        switch self {
        case .done: "Glass"
        case .inputRequired: "Ping"
        case .waiting: "Pop"
        }
    }

    /// On, with the default sound: the behaviour of every build before these
    /// were settings at all.
    public var defaultSound: CueSound { CueSound(enabled: true, name: defaultSoundName) }
}

/// How long the cursor must rest on the island before the card opens, as a
/// stored millisecond count plus the rules that keep it sane.
///
/// Plain Swift in Core, and a named type rather than three literals scattered
/// through the app, because the clamp is the part worth testing: `settings.json`
/// is documented as hand-editable and the one edit that must never be honoured
/// verbatim is a delay long enough to read as a HUD that stopped responding to
/// hover at all.
public enum HoverDelay {
    /// No wait: peek opens the instant the cursor crosses the shape, which is
    /// what every build before this setting did. Kept reachable, and kept
    /// meaning *exactly* that — no timer, no deferred hop through the run loop.
    public static let minimum = 0
    /// Half a second. Beyond this the card stops feeling deliberate and starts
    /// feeling missed: a pointer genuinely aiming at the island has come to rest
    /// long before, so the extra wait buys no further discrimination and only
    /// makes a working HUD look broken.
    public static let maximum = 500
    /// 150ms. The delay exists for one gesture — a pointer sweeping across the
    /// top of the screen on its way to the menu bar or another window — and a
    /// sweep clears the island's few hundred points of width in well under this,
    /// so the card stays shut for the whole of it. A hover that means it still
    /// reads as immediate: 150ms is inside the time the hand takes to stop
    /// moving and the eye takes to land, so the card is open by the time anyone
    /// is looking at it.
    ///
    /// Erring short on purpose. Too short costs a card that opened when you did
    /// not mean it — annoying, visible, and obviously this setting's fault. Too
    /// long costs a card that does not open, which is indistinguishable from a
    /// broken HUD and sends people looking anywhere but here.
    public static let `default` = 150

    /// What the settings pane offers, and what a stored value is held to.
    public static let range = minimum...maximum

    /// Clamped rather than rejected: a hand-edited `30000` is fifteen seconds of
    /// a card that never opens, and refusing to load the file over it would
    /// throw away every other setting in there too. Snapping to the nearest end
    /// of the range keeps the HUD usable and leaves the odd number visible in
    /// the pane, where it can be corrected.
    public static func clamped(_ milliseconds: Int) -> Int {
        min(max(milliseconds, minimum), maximum)
    }

    /// The stored figure as the `Timer` interval the hover monitor schedules.
    /// Clamps on the way past, so no caller can hand a timer a wild value by
    /// skipping the setting's own validation.
    public static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(clamped(milliseconds)) / 1000
    }
}

/// Everything the settings window can change, in one file.
///
/// This replaced a set of one-off sentinel files (`dnd`, `debug`, `tint`,
/// `force-mode`). Those were fine while every setting was a boolean nobody had
/// to discover, but a settings window needs somewhere to put values that are
/// not booleans, and it needs `hudEnabled` to survive a relaunch — which as a
/// menu-only toggle it never did.
///
/// Deliberately plain `Codable` over `UserDefaults`: the rest of this app's
/// state is a readable file under `~/.claude-island/`, `defaults read` on an
/// unsandboxed LSUIElement app is an awkward way to debug, and a JSON file can
/// be diffed, deleted, and hand-edited.
public struct IslandSettings: Codable, Equatable, Sendable {
    /// Whether the HUD draws at all. Persisted, unlike the menu-bar toggle it
    /// replaces — a switch that silently resets on every relaunch reads as a
    /// bug once it lives in a window rather than a menu.
    public var hudEnabled: Bool = true
    /// Which display the HUD draws on, by `NSScreen.localizedName`. Next to
    /// `hudEnabled` because it is the other half of the same question: whether
    /// the island is showing, and where.
    ///
    /// Nil means the display that owns the menu bar — what every build before
    /// this one did, and still the right default: that is where the notch is on
    /// the one Mac shape this HUD is drawn to imitate.
    ///
    /// A name rather than a display id, and a name that may well not be attached
    /// right now. `DisplaySelection` holds the reasoning for both, including what
    /// two identical monitors do to it. The short version: a `CGDirectDisplayID`
    /// survives neither a reboot nor a replug and cannot be shown in a picker; and
    /// this field is deliberately *not* rewritten when the display it names goes
    /// away, so unplugging a monitor falls back for as long as it is gone and the
    /// choice comes back with the cable.
    public var preferredDisplay: String?
    /// How long the cursor must rest on the island before peek opens, in
    /// milliseconds. Next to the two above because it belongs to the same
    /// question they do — whether the island is showing, where, and how eagerly
    /// it answers the pointer.
    ///
    /// Hover-in only. There is deliberately no matching close delay; see
    /// `HoverMonitor.openDelay` for why the asymmetry is the point rather than
    /// an omission.
    ///
    /// Stored as an integer count of milliseconds rather than a `TimeInterval`:
    /// this file is meant to be read and hand-edited, and `0.15` invites the
    /// question of what unit it is in where `150` does not.
    public var hoverOpenDelayMilliseconds: Int = HoverDelay.default
    /// Mutes every sound cue without touching the HUD itself, and without
    /// disturbing what the cues below are set to — one thing to hit when a
    /// meeting starts, that leaves the configuration to come back to afterwards.
    public var doNotDisturb: Bool = false
    /// Drops sound cues — and only sounds — while a terminal or editor is the
    /// frontmost app, on the theory that a chime tells you nothing you cannot
    /// already see on screen.
    ///
    /// Off by default: it changes what an existing install does, and it is a
    /// guess. `TerminalApps` spells out why "a terminal is in front" is not "you
    /// are watching this session" — we can see which app has focus, never which
    /// app a session belongs to. Nothing visual is gated on it, so a wrong guess
    /// costs a chime rather than an alert.
    public var muteWhileTerminalFrontmost: Bool = false
    /// One field per cue rather than a dictionary keyed by `SoundCue`: each
    /// decodes on its own, so a file naming only one of them keeps the defaults
    /// for the other two, and a cue added later cannot silently un-key the
    /// stored ones. Read them through `subscript(cue:)`.
    public var doneSound: CueSound = SoundCue.done.defaultSound
    public var inputRequiredSound: CueSound = SoundCue.inputRequired.defaultSound
    public var waitingSound: CueSound = SoundCue.waiting.defaultSound
    /// Off by default: a HUD has no business writing to disk on every tool call.
    public var logging: Bool = false
    /// Fills the island with a visible colour so its edges can be seen against
    /// the notch, which pure #000 deliberately blends into.
    public var debugTint: Bool = false
    /// Lifts the HUD above other notch apps, which otherwise win the hit test
    /// over the island shape and swallow the click that answers a permission
    /// prompt.
    ///
    /// Off by default, and the default is the interesting part. Those apps sit
    /// *at* screen-saver level, so the only level that beats one is above screen
    /// saver — there is no gentler value that still wins. On means the HUD is
    /// drawn higher than it needs to be for everyone who has no such app
    /// installed, which is most people, and `IslandPanel.level(aboveOtherNotchHUDs:)`
    /// is where that arithmetic lives. Opting in is for the desk where the notch
    /// is already taken.
    public var aboveOtherNotchHUDs: Bool = false
    /// Whether the hook client walks the process tree — and therefore whether
    /// the card offers a jump to the session's app at all.
    ///
    /// Off by default, and the default is the interesting part. The jump reaches
    /// the *app*, never the tab: `open -b` is the only call macOS honours from a
    /// background app, and it takes you no further than the bundle. On the setup
    /// this was built for — several sessions inside one editor that is already
    /// frontmost — it raises an app that is already in front, and nothing moves.
    /// Shipping it on would spend a process-tree read on every tool call of
    /// every session to draw a button that, measured, does nothing there.
    ///
    /// It also governs how exactly `muteWhileTerminalFrontmost` can aim, which
    /// is why the two captions point at each other: switching this off drops
    /// that mute back to "any terminal is in front", the rule it had before any
    /// of this existed.
    public var trackSessionApp: Bool = false
    /// Pins the HUD to one tier — "compact", "alert", "peek", "expanded".
    /// Hover and click cannot be synthesised without Accessibility permission,
    /// so without this the open tiers cannot be inspected at all.
    public var forcedMode: String?

    public init() {}

    public static var path: URL { IslandPaths.settingsFile }

    /// Indexed access to the three sound fields, so the settings pane can loop
    /// over `SoundCue.allCases` instead of repeating one row against three
    /// field names — and so a fourth cue is a compile error here rather than a
    /// row nobody remembered to add.
    public subscript(cue: SoundCue) -> CueSound {
        get {
            switch cue {
            case .done: doneSound
            case .inputRequired: inputRequiredSound
            case .waiting: waitingSound
            }
        }
        set {
            switch cue {
            case .done: doneSound = newValue
            case .inputRequired: inputRequiredSound = newValue
            case .waiting: waitingSound = newValue
            }
        }
    }

    /// Every decoding key is optional with a default, so a settings file written
    /// by an older build — or hand-edited down to a single key — still loads,
    /// and gains the new keys the next time anything is saved.
    private enum CodingKeys: String, CodingKey {
        case hudEnabled, doNotDisturb, logging, debugTint, forcedMode, aboveOtherNotchHUDs
        case muteWhileTerminalFrontmost, trackSessionApp, preferredDisplay
        case hoverOpenDelayMilliseconds
        case doneSound, inputRequiredSound, waitingSound
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hudEnabled = try c.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? true
        doNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
        logging = try c.decodeIfPresent(Bool.self, forKey: .logging) ?? false
        debugTint = try c.decodeIfPresent(Bool.self, forKey: .debugTint) ?? false
        forcedMode = try c.decodeIfPresent(String.self, forKey: .forcedMode)
        // Absent means off, which keeps every existing install exactly where it
        // is in the window order. Raising the level for people who never asked
        // would trade a conflict they may not have for a HUD above their screen
        // saver, which is the worse of the two surprises.
        aboveOtherNotchHUDs =
            try c.decodeIfPresent(Bool.self, forKey: .aboveOtherNotchHUDs) ?? false
        // Absent means off, which is also the default — so every settings.json
        // written before this option existed keeps ringing exactly as it did.
        // Opting in is the only way to get the quieter behaviour.
        muteWhileTerminalFrontmost =
            try c.decodeIfPresent(Bool.self, forKey: .muteWhileTerminalFrontmost) ?? false
        // Absent means off, and here that is not the harmless direction: every
        // settings.json written before this key belongs to an install that has
        // been showing the reveal row, and this takes it away from them. That
        // is the intended trade rather than an oversight — the row cannot reach
        // a tab, so it is a no-op wherever sessions share an editor, and the
        // walk behind it runs on every tool call whether or not anyone clicks.
        // Anyone who wants it back has one switch to find, and the caption in
        // General says what it costs.
        trackSessionApp = try c.decodeIfPresent(Bool.self, forKey: .trackSessionApp) ?? false
        // Absent — every settings.json written before the HUD could be moved —
        // means the menu-bar display, which is where those builds always drew.
        // Normalised on the way in so a hand-edited `""` reads as "no
        // preference" here rather than as a display named "" that will never be
        // found and will report itself missing forever.
        preferredDisplay = DisplaySelection.normalized(
            try c.decodeIfPresent(String.self, forKey: .preferredDisplay))
        // Absent means the default dwell rather than 0, so an install that
        // predates this key gains the delay instead of keeping the old
        // hair-trigger — the old behaviour is the bug this setting fixes, and it
        // stays reachable by dragging the slider to Instant.
        //
        // Clamped, never trusted: the range is the only thing standing between a
        // hand-edited 30000 and a card that appears never to open.
        hoverOpenDelayMilliseconds = HoverDelay.clamped(
            try c.decodeIfPresent(Int.self, forKey: .hoverOpenDelayMilliseconds)
                ?? HoverDelay.default)

        // The upgrade path that matters: every settings.json written before
        // these keys existed has none of them, and must come back ringing
        // exactly what that build rang. A missing key here is not "no sound".
        func sound(_ key: CodingKeys, _ cue: SoundCue) throws -> CueSound {
            guard var stored = try c.decodeIfPresent(CueSound.self, forKey: key) else {
                return cue.defaultSound
            }
            // An object present but with no name in it — `{"enabled": false}`
            // from a hand-edit — takes the cue's default too. The cue still
            // reads as None in the picker, since `enabled` is what decides
            // that; what the default buys is a sound to go back to when None
            // is changed, instead of a row that has to be chosen twice.
            if stored.name.isEmpty { stored.name = cue.defaultSoundName }
            return stored
        }
        doneSound = try sound(.doneSound, .done)
        inputRequiredSound = try sound(.inputRequiredSound, .inputRequired)
        waitingSound = try sound(.waitingSound, .waiting)
    }

    // MARK: - Persistence

    /// Reads the file, falling back to defaults for anything missing or
    /// unreadable.
    ///
    /// Never throws. A corrupt settings file must not stop the HUD from
    /// starting — the worst outcome of ignoring it is that the window opens
    /// showing defaults, which is also the fix.
    public static func load(root: URL = IslandPaths.root) -> IslandSettings {
        guard let data = try? Data(contentsOf: settingsURL(in: root)),
            let decoded = try? JSONDecoder().decode(IslandSettings.self, from: data)
        else { return IslandSettings() }
        return decoded
    }

    public func save(root: URL = IslandPaths.root) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = Self.settingsURL(in: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)  // Trailing newline: this file is meant to be readable.
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Loads settings, folding in any sentinel file left over from the old
    /// scheme and deleting it.
    ///
    /// This is the *only* place the sentinel files are read, and it consumes
    /// them, so there is never a moment where two files disagree about one
    /// setting. It also keeps `touch ~/.claude-island/tint` working as a
    /// documented shell-level shortcut: the touch is picked up on the next
    /// launch and folded into the JSON, exactly as it needed a relaunch before.
    ///
    /// Call once, early, before anything reads settings.
    @discardableResult
    public static func bootstrap(root: URL = IslandPaths.root) -> IslandSettings {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: settingsURL(in: root).path)
        var settings = load(root: root)
        var changed = false

        func consume(_ name: String, _ apply: (String) -> Void) {
            let flag = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: flag.path) else { return }
            let body = (try? String(contentsOf: flag, encoding: .utf8)) ?? ""
            apply(body.trimmingCharacters(in: .whitespacesAndNewlines))
            try? fm.removeItem(at: flag)
            changed = true
        }

        consume("dnd") { _ in settings.doNotDisturb = true }
        consume("debug") { _ in settings.logging = true }
        consume("tint") { _ in settings.debugTint = true }
        consume("force-mode") { body in
            settings.forcedMode = body.isEmpty ? nil : body.lowercased()
        }

        if changed || !existed { try? settings.save(root: root) }
        return settings
    }

    private static func settingsURL(in root: URL) -> URL {
        root.appendingPathComponent("settings.json")
    }
}
