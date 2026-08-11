import Foundation

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
    /// Mutes the sound cues without touching the HUD itself.
    public var doNotDisturb: Bool = false
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

    /// Every decoding key is optional with a default, so a settings file written
    /// by an older build — or hand-edited down to a single key — still loads,
    /// and gains the new keys the next time anything is saved.
    private enum CodingKeys: String, CodingKey {
        case hudEnabled, doNotDisturb, logging, debugTint, forcedMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hudEnabled = try c.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? true
        doNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
        logging = try c.decodeIfPresent(Bool.self, forKey: .logging) ?? false
        debugTint = try c.decodeIfPresent(Bool.self, forKey: .debugTint) ?? false
        forcedMode = try c.decodeIfPresent(String.self, forKey: .forcedMode)
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
