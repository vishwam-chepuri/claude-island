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
/// The two travel together because they are read together, and because keeping
/// the name while the switch is off is the point — muting a cue must not lose
/// the sound that was picked for it.
public struct CueSound: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// A name from `SystemSound.all`. Free-form on purpose: the file is meant to
    /// be hand-editable, and a name this build does not list may still resolve
    /// on the machine that wrote it.
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
    /// Mutes every sound cue without touching the HUD itself, and without
    /// disturbing the per-cue switches below — one thing to hit when a meeting
    /// starts, that leaves the configuration to come back to afterwards.
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
        case hudEnabled, doNotDisturb, logging, debugTint, forcedMode
        case muteWhileTerminalFrontmost, preferredDisplay
        case doneSound, inputRequiredSound, waitingSound
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hudEnabled = try c.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? true
        doNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
        logging = try c.decodeIfPresent(Bool.self, forKey: .logging) ?? false
        debugTint = try c.decodeIfPresent(Bool.self, forKey: .debugTint) ?? false
        forcedMode = try c.decodeIfPresent(String.self, forKey: .forcedMode)
        // Absent means off, which is also the default — so every settings.json
        // written before this option existed keeps ringing exactly as it did.
        // Opting in is the only way to get the quieter behaviour.
        muteWhileTerminalFrontmost =
            try c.decodeIfPresent(Bool.self, forKey: .muteWhileTerminalFrontmost) ?? false
        // Absent — every settings.json written before the HUD could be moved —
        // means the menu-bar display, which is where those builds always drew.
        // Normalised on the way in so a hand-edited `""` reads as "no
        // preference" here rather than as a display named "" that will never be
        // found and will report itself missing forever.
        preferredDisplay = DisplaySelection.normalized(
            try c.decodeIfPresent(String.self, forKey: .preferredDisplay))

        // The upgrade path that matters: every settings.json written before
        // these keys existed has none of them, and must come back ringing
        // exactly what that build rang. A missing key here is not "no sound".
        func sound(_ key: CodingKeys, _ cue: SoundCue) throws -> CueSound {
            guard var stored = try c.decodeIfPresent(CueSound.self, forKey: key) else {
                return cue.defaultSound
            }
            // An object present but with no name in it — `{"enabled": false}`
            // from a hand-edit — takes the cue's default too. It would ring the
            // default anyway once resolved, and leaving the name empty would
            // draw an empty row in the picker that reads as a lost setting.
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
