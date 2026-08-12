import Foundation

/// The terminals and code editors a Claude Code session is plausibly being
/// watched in, by bundle identifier.
///
/// Exists for exactly one decision: whether to *skip a sound* while one of these
/// is the frontmost app — see `IslandSettings.muteWhileTerminalFrontmost`. It
/// gates nothing else. The island still lights up, still pulses, still holds the
/// permission prompt open; the only thing this can ever take away is a chime.
///
/// **This is the fallback, and only the fallback.** A session whose process
/// ancestry resolved to an app is matched against *that* app exactly — see
/// `OwnerResolution` and `AppController.rings(_:under:frontmost:owner:)`. This
/// list is what remains for sessions that have no owning app to resolve: a
/// daemon-hosted background job, a tmux server, a session on the far end of an
/// SSH link.
///
/// For those it is still a guess, and the guess is still lopsided: a session in
/// a tmux client that is not frontmost goes on ringing, and an unrelated
/// terminal in front silences one it has nothing to do with. Both errors fall
/// in the harmless direction — a missing chime, never a missing alert — and the
/// setting is off by default.
///
/// Strings rather than `NSRunningApplication`: Core imports no AppKit, and
/// keeping the classification here is what makes it testable without a window
/// server. Whoever asks the workspace which app is in front — see
/// `AppController.rings(_:under:frontmost:owner:)` — passes the id in.
public enum TerminalApps {
    /// Bundle ids matched exactly.
    ///
    /// Written in each vendor's own capitalisation and lowercased once below.
    /// Bundle ids are case-insensitive to LaunchServices and real Info.plists are
    /// wildly inconsistent about it (`com.googlecode.iterm2`, `com.microsoft.VSCode`),
    /// so demanding one canonical case here would rot silently: a future entry
    /// typed the way the vendor writes it would look right and never match.
    ///
    /// Hardcoded, so adding an app is a code change. That is the same trade
    /// `SystemSound.all` makes and for the same reason — a list scanned from the
    /// machine would differ per install and could not be tested — but it is a
    /// sharper cost here, because an unlisted terminal is not merely absent from
    /// a picker: it silently behaves as "not a terminal" and rings.
    public static let bundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",  // Hyper
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        // Cursor ships through ToDesktop, so its id is an opaque build handle
        // rather than anything readable. It is stable across Cursor releases;
        // it is also the one entry here that cannot be sanity-checked by eye.
        "com.todesktop.230313mzl4w4u92",
        // JetBrains-derived but published under Google's id, so the prefix below
        // does not reach it.
        "com.google.android.studio",
    ]

    /// Families matched by prefix, because enumerating them is a losing game.
    ///
    /// JetBrains ships a dozen IDEs under `com.jetbrains.*` and adds more; Zed and
    /// Warp both suffix their id per release channel. The cost is over-matching:
    /// `com.jetbrains.toolbox` is a launcher, not an IDE, and will suppress a
    /// chime if it happens to be frontmost. Accepted — the worst case is one
    /// missed sound, which is the same worst case the whole setting has.
    public static let bundleIDPrefixes: [String] = [
        "com.jetbrains.",  // IntelliJ, PyCharm, GoLand, WebStorm, CLion, Rider, …
        "dev.zed.",  // Zed, Zed-Preview, Zed-Nightly
        "dev.warp.",  // Warp-Stable, Warp-Preview
    ]

    private static let exact: Set<String> = Set(bundleIDs.map { $0.lowercased() })
    private static let prefixes: [String] = bundleIDPrefixes.map { $0.lowercased() }

    /// Whether this bundle id belongs to a terminal or editor we know of.
    ///
    /// `nil`, empty, and unrecognised all answer false, and that direction is
    /// deliberate: "we do not know what this app is" must mean "not a terminal",
    /// so the fallback is to ring. An unknown app that silenced cues would be a
    /// HUD that stopped making noise for no reason the user could see or undo.
    public static func matches(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        if exact.contains(id) { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}
