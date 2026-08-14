import ClaudeIslandCore
import SwiftUI

// MARK: - Tiers

/// The four poses the Appearance pane can put the island in.
///
/// Deliberately not `IslandMode` itself, even though it maps onto four of its
/// five cases. The fifth is `.dormant`, which is the island being *exactly* the
/// cutout and therefore invisible on purpose — a segment offering that is one
/// the user presses once and reads as a preview that broke.
enum IslandPreviewTier: String, CaseIterable, Identifiable {
    case compact, alert, peek, expanded

    var id: Self { self }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .alert: "Alert"
        case .peek: "Peek"
        case .expanded: "Expanded"
        }
    }

    /// What the preview's model is pinned to — `forcedMode`, the same field the
    /// Advanced pane writes to disk, set on a model that is not the HUD's.
    var mode: IslandMode {
        switch self {
        case .compact: .compact
        case .alert: .alert
        case .peek: .peek
        case .expanded: .expanded
        }
    }
}

// MARK: - The preview's own island

/// The model and fixtures behind the Appearance preview, kept out of the view so
/// the isolation below can be asserted from `--selftest` rather than only argued
/// for in a comment.
@MainActor
final class IslandPreviewSource {
    /// The preview's island. Never the app's.
    ///
    /// `AppController` owns exactly one `IslandViewModel`, and `forcedMode` on it
    /// is a pin on the real shape on the real screen — the same field the
    /// Advanced pane warns about. Driving that one from here would mean merely
    /// *opening* a settings pane pinned the user's HUD to whichever tier the
    /// segmented control happened to be showing, and left it pinned, because
    /// nothing else ever clears it. So the preview gets a second model, wired to
    /// nothing: no socket feeding it snapshots, no `onAnswerPermission`, no
    /// panel, no hover monitor. It shares the drawing code and nothing else,
    /// which is exactly the amount of sharing this pane is for.
    let model = IslandViewModel()

    /// Nothing is applied here on purpose. SwiftUI evaluates a `@State` default
    /// on every view init and keeps only the first instance, so anything that
    /// scheduled work in this initialiser would leak a timer per body pass.
    init() {}

    /// Poses the island.
    ///
    /// The fixture is rebuilt on every call rather than cached, so the elapsed
    /// figures count from the moment the segment was pressed. A cached one is
    /// still live — the ticker keeps it moving — but it reads "3h 12m" after the
    /// window has sat open all afternoon, which is accurate and useless.
    /// `trackSessionApp` is passed in rather than defaulted because this pane's
    /// whole claim is that it draws the card with the same code the HUD does. A
    /// preview that offered a reveal row the real card no longer has would be
    /// advertising a control the user has switched off, on the one surface where
    /// they go to look the card over.
    func show(
        _ tier: IslandPreviewTier, trackSessionApp: Bool, on preferredDisplay: String? = nil
    ) {
        // Re-resolved per pose rather than once, and against the chosen display
        // rather than always the menu bar's: the two have different shapes — a
        // notch on the built-in panel, the fallback pill on anything else — and
        // the preview is only worth having if it shows the one the HUD will
        // actually take. Unplugging that display between poses falls back here
        // exactly as it does on screen, because it is the same resolution.
        model.setGeometry(Self.geometry(preferredDisplay: preferredDisplay))
        model.forcedMode = tier.mode
        // The expanded card's reveal row asks who owns each session, and these
        // sessions were never launched by anything — resolved for real they all
        // come back `.unknown`, and the preview would permanently advertise
        // "terminal unknown", the one state the spec says a real user does not
        // reach. Pin a plausible owner instead. A property rather than an
        // argument to `refreshOwners` because the ticker refreshes on its own
        // once a second and would put the real answer back.
        model.trackSessionApp = trackSessionApp
        model.ownerResolver = { _ in .owner(Self.previewOwner) }
        model.apply(IslandPreviewFixtures.snapshot(for: tier))
    }

    /// The app the preview claims its invented sessions are running in.
    /// Terminal, because it is on every Mac and the name is the entire label.
    private static let previewOwner = OwnerResolution.AppInfo(
        pid: 501, bundleID: "com.apple.Terminal", name: "Terminal", isRegular: true)

    /// Stops the ticker the fixtures start.
    ///
    /// Not optional housekeeping: every fixture holds a running or waiting
    /// session, so `apply` schedules a repeating 1 Hz timer, and the main
    /// runloop — not this object — owns it. Dropping the source without this
    /// leaves that timer firing once a second for the rest of the process's
    /// life, waking the app up on behalf of a settings pane that closed hours
    /// ago. The HUD's idle-CPU contract has no exception for previews.
    func shutdown() {
        model.shutdown()
    }

    /// Falls back to a plausible notch when no screen answers.
    ///
    /// Without geometry every measurement on the model is zero and the preview
    /// renders an empty box, which looks like a bug rather than like the missing
    /// display it is. The fallback is only reachable with no screens at all, in
    /// which case there is no settings window to show it in either.
    private static func geometry(preferredDisplay: String?) -> NotchGeometry {
        NotchGeometryResolver.current(preferredDisplay: preferredDisplay)
            ?? NotchGeometry(
                islandRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                panelRect: CGRect(
                    x: 0, y: 0,
                    width: NotchGeometryResolver.panelWidth,
                    height: NotchGeometryResolver.panelHeight),
                hasNotch: true,
                screenID: 0)
    }
}

// MARK: - Fixtures

/// Made-up sessions for the Appearance preview.
///
/// Built the way `SelfTest` builds its fixtures — `Session`'s real initialiser,
/// then the fields the card draws set on top — rather than by pushing invented
/// hook envelopes through `SessionReducer`. The reducer would produce a session
/// that is provably reachable, but this only ever has to be a *believable* one,
/// and going through the reducer would mean encoding an event script for each
/// tier that has to be reread every time the state machine changes.
enum IslandPreviewFixtures {
    /// Each tier gets the sessions worth looking at that tier with: one running
    /// session for the pill, a prompt for the alert, the whole context block for
    /// the peek, and a switcher with something in every colour for the card.
    ///
    /// Session ids are scoped per tier, which is not cosmetic. `IslandViewModel`
    /// detects a completion as a *crossing* into `.done` between consecutive
    /// snapshots, so a session that was `thinking` under one tier and `done`
    /// under the next would fire a completion pulse — blue edge, and the display
    /// taken over by whichever session "finished" — because somebody pressed a
    /// segment. A fresh id is never a crossing, so the tiers cannot bleed into
    /// each other this way.
    static func snapshot(for tier: IslandPreviewTier, now: Date = Date()) -> HUDSnapshot {
        switch tier {
        case .compact:
            return HUDSnapshot(primary: working("compact", now: now))

        case .alert:
            var asking = working("alert", now: now)
            asking.state = .awaitingPermission(
                PermissionAsk(
                    toolName: "Bash",
                    kind: .bash,
                    target: "rm -rf .build && swift build -c release",
                    since: now.addingTimeInterval(-6),
                    // Answerable, because that is the ordinary case once the
                    // hooks are current — and inert regardless: the preview's
                    // model has no `onAnswerPermission`, and the stage refuses
                    // hit testing, so the buttons this token would unlock in the
                    // open tiers cannot be pressed at all.
                    decisionToken: 1,
                    detail: "rm -rf .build && swift build -c release"))
            return HUDSnapshot(primary: asking, others: [background("alert", now: now)])

        case .peek:
            return HUDSnapshot(primary: working("peek", now: now))

        case .expanded:
            // Three sessions: enough for the switcher to be a list rather than a
            // single highlighted row, and one of each colour so the rail down
            // the left says something.
            //
            // No 5-hour window in this fixture, though the card draws one. That
            // figure only ever arrives from the status-line forwarder, so
            // showing it unconditionally here would advertise a meter that never
            // appears for anyone who declined to install it.
            return HUDSnapshot(
                primary: working("expanded", now: now),
                others: [background("expanded", now: now), finished("expanded", now: now)])
        }
    }

    /// The session every tier is built around: mid-turn, with a branch, a model,
    /// an effort, a plan and enough of a trail for the card's recent list.
    private static func working(_ tier: String, now: Date) -> Session {
        var s = base(
            id: "\(tier)-alpha", title: "Polish the peek tier",
            folder: "claude-island", startedAgo: 21 * 60, now: now)
        s.gitBranch = "feature/appearance-pane"
        s.model = "claude-opus-5"
        s.effort = "high"
        s.tokens.contextTokens = 84_200
        // Both non-zero, because `hasLineChanges` is what gates the chip: a
        // fixture with no line counts would preview a card that quietly has one
        // fewer row than most real ones.
        s.linesAdded = 412
        s.linesRemoved = 86
        s.tasks = TaskProgress(items: [
            TaskItem(id: "1", subject: "Add the Appearance pane", status: .completed),
            TaskItem(id: "2", subject: "Feed it a synthetic snapshot", status: .completed),
            TaskItem(id: "3", subject: "Fit the card to the stage", status: .inProgress),
            TaskItem(id: "4", subject: "Check the tint follows", status: .pending),
            TaskItem(id: "5", subject: "Run the self-test", status: .pending),
        ])

        // The in-flight call sits at the head of `recentTools` as well as in the
        // state, exactly as the reducer leaves it; `TrailSection` filters it back
        // out by its missing end stamp so the NOW row does not show twice.
        let live = ToolActivity(
            kind: .edit, toolName: "Edit",
            target: "Sources/ClaudeIslandApp/SettingsView.swift",
            startedAt: now.addingTimeInterval(-9))
        s.state = .running(live)
        s.recentTools = [
            live,
            ToolActivity(
                kind: .read, toolName: "Read", target: "Sources/ClaudeIslandApp/IslandView.swift",
                startedAt: now.addingTimeInterval(-38), endedAt: now.addingTimeInterval(-31)),
            ToolActivity(
                kind: .bash, toolName: "Bash", target: "swift build",
                startedAt: now.addingTimeInterval(-92), endedAt: now.addingTimeInterval(-44)),
            ToolActivity(
                kind: .grep, toolName: "Grep", target: "forcedMode",
                startedAt: now.addingTimeInterval(-120), endedAt: now.addingTimeInterval(-118)),
        ]
        return s
    }

    /// A second session, working away in another repo. Present so the switcher
    /// and the attention count have something to count.
    private static func background(_ tier: String, now: Date) -> Session {
        var s = base(
            id: "\(tier)-beta", title: "Chase the flaky socket test",
            folder: "api", startedAgo: 7 * 60, now: now)
        s.gitBranch = "main"
        s.model = "claude-sonnet-5"
        s.tokens.contextTokens = 31_500
        s.state = .thinking
        return s
    }

    /// A session that has stopped. Only ever appears in the expanded fixture, and
    /// only ever as a session first *seen* finished — see the id scoping above.
    private static func finished(_ tier: String, now: Date) -> Session {
        var s = base(
            id: "\(tier)-gamma", title: "Draft the release notes",
            folder: "docs", startedAgo: 52 * 60, now: now)
        s.gitBranch = "release/1.4"
        s.model = "claude-sonnet-5"
        s.tokens.contextTokens = 12_800
        s.state = .done
        return s
    }

    private static func base(
        id: String, title: String, folder: String, startedAgo: TimeInterval, now: Date
    ) -> Session {
        var s = Session(id: id, startedAt: now.addingTimeInterval(-startedAgo))
        // A folder under a plainly fake home: `displayName` falls back to the
        // last path component, so a real-looking path would put someone else's
        // directory names in front of the user as if they were their own.
        s.cwd = "/Users/you/Code/\(folder)"
        s.aiTitle = title
        s.lastEventAt = now.addingTimeInterval(-4)
        return s
    }
}

// MARK: - The pane's preview

/// The Appearance pane's island: the real shape, the real content views, the
/// real view model — posed with fake sessions on a backdrop that makes it
/// visible indoors.
struct IslandPreview: View {
    /// Read, never written. The only setting the preview reflects is the debug
    /// tint, and it reflects it rather than offering it: the switch stays in
    /// Advanced, beside the rest of the development aids.
    let store: SettingsStore

    @State private var source = IslandPreviewSource()
    @State private var tier: IslandPreviewTier = .compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tall enough that the expanded card still lands around 0.85 scale.
    /// Measured against these fixtures on notched hardware: compact and alert
    /// come to 486x39, peek to 528x190, and expanded to 600x396 — taller than
    /// any pane this window can offer it. The three short tiers are therefore
    /// drawn 1:1 and simply leave desktop below them, which is what the top of a
    /// real screen looks like anyway.
    private static let stageHeight: CGFloat = 350
    /// Clearance between the drawn shape and the stage's sides and floor. Not the
    /// top: the island is meant to meet that edge, which is the point of the
    /// concave flares.
    private static let stageInset: CGFloat = 14

    var body: some View {
        VStack(spacing: 12) {
            stage
            Picker("Tier", selection: $tier) {
                ForEach(IslandPreviewTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .onAppear {
            source.show(
                tier, trackSessionApp: store.trackSessionApp, on: store.preferredDisplay)
        }
        .onDisappear { source.shutdown() }
        .onChange(of: tier) { _, chosen in
            source.show(
                chosen, trackSessionApp: store.trackSessionApp, on: store.preferredDisplay)
        }
        // Same reasoning as the display picker below: the toggle lives one pane
        // away, and a stage still showing a reveal row after it was switched off
        // would be a preview of a card that no longer exists.
        .onChange(of: store.trackSessionApp) { _, tracking in
            source.show(tier, trackSessionApp: tracking, on: store.preferredDisplay)
        }
        // The display picker sits directly under this stage, so this is what
        // makes the pane a readout rather than a still: choosing a notchless
        // display reshapes the island in place, without the pane being left or
        // the tier being pressed again. It also still covers the picker being
        // changed from anywhere else — a preview showing a notch for a HUD that
        // is now a pill on an external monitor is worse than no preview at all.
        .onChange(of: store.preferredDisplay) { _, display in
            source.show(tier, trackSessionApp: store.trackSessionApp, on: display)
        }
        // Read through to the store rather than copied at appear, so throwing the
        // switch in Advanced and coming back here shows the tint already applied
        // — and so does throwing it while this pane is open, if the window is
        // ever split.
        .onChange(of: store.debugTint, initial: true) { _, tinted in
            source.model.debugTint = tinted
        }
    }

    /// The stage the island is posed on.
    ///
    /// The island is filled pure `#000` with no border of its own, because on the
    /// real screen it *is* the notch: the cutout it grows out of is already
    /// black, and any lift at all shows as a seam along the one edge they share.
    /// A settings window has no cutout and no bezel, so that same fill is either
    /// invisible (light appearance) or an unreadable smudge (dark). The backdrop
    /// supplies what the hardware normally does — something plainly not black to
    /// read the silhouette against — and its top edge stands in for the top of
    /// the panel, which on a notched display is the top of the screen.
    private var stage: some View {
        GeometryReader { geo in
            backdrop
                .overlay(alignment: .top) {
                    // An overlay, not a child in a stack: `IslandView` frames
                    // itself to the panel's full 980x520 so its internal layout
                    // is the HUD's layout and not a re-derivation of it, and a
                    // child that size would drag the stage out to match. An
                    // overlay is measured by its host and hangs over the edges,
                    // which the clip below trims.
                    IslandView(model: source.model)
                        .scaleEffect(scale(in: geo.size), anchor: .top)
                        // A picture, not a control. Every gesture the island
                        // carries would land on the preview's own model — a tap
                        // toggles a pin that `forcedMode` already outranks, a
                        // switcher row selects a session that does not exist —
                        // so they would all be affordances that do nothing
                        // visible. Refusing them is more honest than offering
                        // them.
                        .allowsHitTesting(false)
                        // Mirrors `IslandView`'s own morph. The two have to stay
                        // in step: the scale is computed from the tier's final
                        // size, so a scale that snapped while the shape sprang
                        // would draw the expanded card at compact's scale for the
                        // length of the collapse and spill it over the stage's
                        // edge on the way down. Duplicated constants are the
                        // price of not reaching into the HUD's view to publish
                        // them; drift shows up as exactly that brief overflow.
                        .animation(morph, value: source.model.mode)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(height: Self.stageHeight)
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.19, green: 0.20, blue: 0.27),
                Color(red: 0.43, green: 0.37, blue: 0.53),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(alignment: .top) {
            // The menu bar band the island lives inside. Decoration, and sized
            // from the model rather than guessed, so it agrees with the shape it
            // sits behind. Zero on a notchless display, where the HUD draws a
            // floating pill instead and there is no band to suggest.
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: source.model.notchBandHeight)
        }
    }

    private var morph: Animation {
        reduceMotion
            ? .spring(response: 0.001, dampingFraction: 1)
            : .spring(response: 0.38, dampingFraction: 0.78)
    }

    /// Fits the drawn shape into the stage, and never enlarges it.
    ///
    /// Enlarging would be a lie: the island's type is tuned to read at 8–11pt
    /// inside a 38pt notch band, and a magnified preview would answer a question
    /// nobody asked. Shrinking is a compromise, and past a point an unavoidable
    /// one — both flanks have to clear a 220pt cutout, so the expanded card is
    /// 600pt across before the window's sidebar is accounted for, and it is
    /// taller still. The type gets correspondingly harder to read, and at the
    /// window's minimum width the expanded card falls to about 0.6; the
    /// alternative is a card cropped at the stage's edge, which looks exactly
    /// like the layout bug the card's height budget exists to prevent.
    private func scale(in available: CGSize) -> CGFloat {
        let shape = source.model.shapeSize
        // The concave flares hang past the frame on both sides — the same
        // correction `interactiveScreenRect` makes for the hit region.
        let width = shape.width + 2 * source.model.topFlare
        guard width > 1, shape.height > 1, available.width > 1, available.height > 1
        else { return 1 }
        let fit = min(
            (available.width - 2 * Self.stageInset) / width,
            (available.height - Self.stageInset) / shape.height)
        // The floor is for layout transients only — a GeometryReader proposing
        // almost nothing on its first pass must not collapse the island to a
        // speck it then has to spring back from.
        return min(1, max(0.25, fit))
    }
}
