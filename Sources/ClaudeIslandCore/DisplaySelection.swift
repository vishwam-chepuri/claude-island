import Foundation

/// Which display the HUD ends up on, once the stored choice has been checked
/// against the displays that are actually attached.
public struct DisplayResolution: Equatable, Sendable {
    /// Index into the list this was resolved against. Always a valid one — there
    /// is deliberately no "nowhere" case. A HUD that resolves to no display is a
    /// HUD that has silently stopped existing, which is indistinguishable from a
    /// crash to anyone looking at the notch.
    public let index: Int
    /// The name that was asked for when nothing attached answered to it, so the
    /// caller can say *why* it is drawing somewhere else. Nil when the stored
    /// choice was found, and nil when there was no stored choice at all.
    public let missing: String?

    public init(index: Int, missing: String? = nil) {
        self.index = index
        self.missing = missing
    }
}

/// Picking a display by name, and falling back when that display is gone.
///
/// Names, not screens: `NSScreen` is AppKit and Core does not import it, so the
/// app hands in `NSScreen.screens.map(\.localizedName)` and gets back an index.
/// The split is not bookkeeping. The behaviour worth being certain about is what
/// happens when the chosen monitor is *unplugged*, and a rule expressed over
/// `NSScreen` could only ever be exercised by physically pulling a cable —
/// a check nobody runs, on a machine whose monitors we cannot see. Over a list
/// of strings it is three lines of test.
///
/// ## Why the name is the identity
///
/// The stored identity is `NSScreen.localizedName` ("Built-in Retina Display",
/// "DELL P3223QE"). The alternatives were weighed and rejected:
///
/// - `CGDirectDisplayID` is what the geometry already carries, and it is the
///   obvious "stable id" — but it is assigned by the window server per session.
///   It changes across a reboot, and across unplug/replug on the same boot, so a
///   setting keyed on it would come back pointing at nothing (or, worse, at
///   whichever display inherited the number) exactly when it was needed most.
/// - The EDID triple (vendor, model, serial via `CGDisplayVendorNumber` and
///   friends) really is stable, but a great many panels report a serial of 0, so
///   two identical monitors collapse anyway; and none of it is showable in a
///   picker, so the name would have to be stored *alongside* it — two facts that
///   can disagree, to fix a case the second fact does not actually fix.
///
/// The name is what the picker has to display regardless, it survives relaunches
/// and replugs, and when it goes stale the failure is the same one an unplugged
/// monitor already produces — which this type is built to handle rather than
/// avoid. Its honest failure modes:
///
/// - **Two identical monitors** report the same `localizedName`. They cannot be
///   told apart here, the picker offers one row for both (see `options`), and
///   the first match in `NSScreen.screens` order wins. Which of the two that is
///   can change between launches. Documented rather than papered over: the fix
///   is the EDID serial, and on identical monitors that is usually 0 as well.
/// - **A renamed or re-badged display** (System Settings can rename an AirPlay
///   or Sidecar screen; a docking station can re-badge one) stops matching, and
///   the HUD falls back to the menu-bar display. The stored name is *not*
///   rewritten, so renaming it back restores the choice — the same behaviour as
///   unplugging it, which is the behaviour this whole type is arranged around.
public enum DisplaySelection {
    /// Trims a stored or typed name, and turns blank into "no preference".
    ///
    /// `settings.json` is documented as hand-editable, and `"preferredDisplay":
    /// ""` from a hand-edit means "stop pinning it" — not "look for a display
    /// with no name", which would report a missing display forever.
    public static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Where to draw, given what is plugged in.
    ///
    /// `menuBarIndex` is the fallback rather than index 0 on purpose: "the
    /// display with the menu bar" is the default the setting is defined against,
    /// and it is not always the first entry in a caller's list.
    ///
    /// Returns nil only when there are no displays at all, which on a Mac means
    /// there is nothing to draw on and nobody to see it.
    public static func resolve(preferred: String?, attached: [String], menuBarIndex: Int)
        -> DisplayResolution?
    {
        guard !attached.isEmpty else { return nil }
        // A menu-bar index that does not index the list it came with is a caller
        // bug, but drawing off-screen over it would be a worse one.
        let fallback = attached.indices.contains(menuBarIndex) ? menuBarIndex : 0

        guard let wanted = normalized(preferred) else {
            return DisplayResolution(index: fallback)
        }
        if let match = attached.firstIndex(where: { matches($0, wanted) }) {
            return DisplayResolution(index: match)
        }
        // The chosen display is not here — unplugged, asleep, renamed, or on a
        // different Mac entirely. Fall back, and say so: the caller logs it, and
        // the picker keeps offering the stored name rather than snapping to
        // something the user never chose.
        return DisplayResolution(index: fallback, missing: wanted)
    }

    /// The names a picker should offer: everything attached, plus the stored
    /// choice when that is not among them.
    ///
    /// The second half is the whole point. A picker whose selection matches no
    /// row draws an empty one, which reads as a setting that reset itself — so
    /// an unplugged monitor would look like the app forgetting the choice it is
    /// in fact still honouring the moment the cable goes back in.
    ///
    /// Duplicates are collapsed because two identical monitors report the same
    /// name: a second row carrying the same tag can never be selected, so it
    /// would only ever be a row that does nothing.
    public static func options(attached: [String], chosen: String?) -> [String] {
        var seen = Set<String>()
        var options = attached.filter { seen.insert($0.lowercased()).inserted }
        if let chosen = normalized(chosen), !options.contains(where: { matches($0, chosen) }) {
            // Appended, not prepended: the attached displays are the real
            // answers, and the missing one is a footnote to them.
            options.append(chosen)
        }
        return options
    }

    /// Case-insensitive because the name may have been typed into the JSON by
    /// hand. Not fuzzy beyond that — "DELL P3223QE" and "DELL P2723QE" are
    /// different monitors, and a near-match is the one kind of wrong answer that
    /// would be hard to notice.
    private static func matches(_ name: String, _ wanted: String) -> Bool {
        name.caseInsensitiveCompare(wanted) == .orderedSame
    }
}
