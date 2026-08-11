import ClaudeIslandCore
import Foundation
import Observation

/// Observable wrapper around `IslandSettings`, so SwiftUI can bind straight to
/// a toggle and the write to disk happens on the way past.
///
/// Lives in the app target rather than in Core: Core is deliberately free of
/// anything a headless `--replay` or the test harness would have to drag in,
/// and the persistence itself — the part the tests care about — is already
/// there as a plain struct.
@MainActor
@Observable
final class SettingsStore {
    /// Fired after any change is persisted, so the app can apply it live rather
    /// than wait for a relaunch. Set once, by `AppController`.
    @ObservationIgnored var onChange: ((IslandSettings) -> Void)?
    /// Where a failed write is reported. A settings file that silently stopped
    /// persisting would look exactly like a settings file that works.
    @ObservationIgnored var onWriteFailure: ((Error) -> Void)?

    var hudEnabled: Bool { didSet { persist() } }
    var doNotDisturb: Bool { didSet { persist() } }
    var logging: Bool { didSet { persist() } }
    var debugTint: Bool { didSet { persist() } }
    var forcedMode: String? { didSet { persist() } }
    var muteWhileTerminalFrontmost: Bool { didSet { persist() } }
    /// The display's `localizedName`, or nil for the menu bar's. Held even while
    /// that display is unplugged — see `IslandSettings.preferredDisplay`.
    var preferredDisplay: String? { didSet { persist() } }
    var doneSound: CueSound { didSet { persist() } }
    var inputRequiredSound: CueSound { didSet { persist() } }
    var waitingSound: CueSound { didSet { persist() } }

    /// The same indexing `IslandSettings` offers, so the pane can draw a row per
    /// `SoundCue` and bind straight to it.
    ///
    /// The setter assigns to the stored property rather than to a copy, so the
    /// `didSet` above still fires — a subscript that skipped it would move the
    /// switch on screen and forget it by the next launch, which is the one
    /// failure mode this whole store exists to prevent.
    subscript(cue: SoundCue) -> CueSound {
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

    /// Where `persist()` writes. Overridden by the self-test so it can exercise
    /// the whole store-to-disk path against a temporary directory rather than
    /// scribbling on the real settings file.
    @ObservationIgnored private let root: URL

    /// Takes the already-bootstrapped settings rather than loading them again,
    /// so the sentinel migration has provably run before any of this is read.
    init(_ settings: IslandSettings, root: URL = IslandPaths.root) {
        self.root = root
        hudEnabled = settings.hudEnabled
        doNotDisturb = settings.doNotDisturb
        logging = settings.logging
        debugTint = settings.debugTint
        forcedMode = settings.forcedMode
        muteWhileTerminalFrontmost = settings.muteWhileTerminalFrontmost
        preferredDisplay = settings.preferredDisplay
        doneSound = settings.doneSound
        inputRequiredSound = settings.inputRequiredSound
        waitingSound = settings.waitingSound
    }

    var current: IslandSettings {
        var s = IslandSettings()
        s.hudEnabled = hudEnabled
        s.doNotDisturb = doNotDisturb
        s.logging = logging
        s.debugTint = debugTint
        s.forcedMode = forcedMode
        s.muteWhileTerminalFrontmost = muteWhileTerminalFrontmost
        s.preferredDisplay = preferredDisplay
        s.doneSound = doneSound
        s.inputRequiredSound = inputRequiredSound
        s.waitingSound = waitingSound
        return s
    }

    private func persist() {
        let settings = current
        do {
            try settings.save(root: root)
        } catch {
            onWriteFailure?(error)
        }
        // Apply even if the write failed: the setting still took effect for this
        // run, and refusing to honour it would be a second failure on top of the
        // first.
        onChange?(settings)
    }
}
