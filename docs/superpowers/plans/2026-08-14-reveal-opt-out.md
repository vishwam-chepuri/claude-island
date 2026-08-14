# Reveal Opt-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `trackSessionApp` (default off) which hides the reveal row, stops the hook client walking the process tree, and drops the frontmost-mute back to its pre-ancestry heuristic.

**Architecture:** One setting in Core. The client learns it from a new `--no-ancestry` argv flag that `HookInstaller` writes into the hook block, so the client still reads no files and parses no JSON. The app additionally ignores `_island_pids` whenever the setting is off, which makes the setting authoritative even when the installed hooks are stale.

**Tech Stack:** Swift 6, SwiftUI, no third-party dependencies. Tests run through the in-repo harness: `swift run ClaudeIslandTests [filter]`.

## Global Constraints

- **No third-party dependencies.** Ever, anywhere in this repo.
- **`Sources/claude-island-notify` links no Foundation** and never parses JSON. Darwin only.
- **Comment style is "why", not "what".** Match the surrounding density — these files carry long explanatory comments recording what was measured and why an obvious alternative was rejected. A bare mechanical comment is a style violation here.
- **Every `IslandSettings` decoding key is optional with a default**, so an older settings file still loads.
- **Commit after each task.** No co-author trailer (see `CLAUDE.md`).
- **`git diff` is broken globally.** Use `--no-ext-diff` on any command that diffs.
- **Default is `false`.** `trackSessionApp` ships off; an absent key decodes off.

---

### Task 1: The setting key

**Files:**
- Modify: `Sources/ClaudeIslandCore/IslandSettings.swift` (property near `aboveOtherNotchHUDs` ~line 247, `CodingKeys` ~line 282, `init(from:)` ~line 287)
- Test: `Tests/ClaudeIslandCoreTests/SettingsTests.swift`

**Interfaces:**
- Produces: `IslandSettings.trackSessionApp: Bool` (default `false`)

- [ ] **Step 1: Write the failing test**

Add inside the existing `suite` in `SettingsTests.swift`:

```swift
test("Session-app tracking is off unless a settings file asks for it") {
    let bare = try JSONDecoder().decode(IslandSettings.self, from: Data("{}".utf8))
    await expectEqual(bare.trackSessionApp, false)

    let on = try JSONDecoder().decode(
        IslandSettings.self, from: Data("{\"trackSessionApp\":true}".utf8))
    await expectEqual(on.trackSessionApp, true)
}

test("Session-app tracking round-trips through a save") {
    var settings = IslandSettings()
    settings.trackSessionApp = true
    let data = try JSONEncoder().encode(settings)
    let back = try JSONDecoder().decode(IslandSettings.self, from: data)
    await expectEqual(back.trackSessionApp, true)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift run ClaudeIslandTests Settings`
Expected: FAIL — `value of type 'IslandSettings' has no member 'trackSessionApp'`

- [ ] **Step 3: Implement**

In `IslandSettings.swift`, after `aboveOtherNotchHUDs`:

```swift
/// Whether the hook client walks the process tree, and therefore whether the
/// card offers a jump to the session's app at all.
///
/// Off by default, and that default is a real decision rather than caution:
/// the jump reaches the *app*, never the tab, so on the setup this was built
/// for — several sessions inside one editor that is already frontmost — it
/// raises an app that is already in front and nothing moves. Shipping it on
/// would spend a walk of the process tree on every tool call, for every
/// session, to draw a button most people cannot use.
///
/// Turning it off also drops `muteWhileTerminalFrontmost` back to its
/// pre-ancestry rule, which is why the two captions cross-reference.
public var trackSessionApp: Bool = false
```

Add `trackSessionApp` to `CodingKeys`, and in `init(from:)`:

```swift
// Absent means off, matching the stored default — so an install that
// upgrades into this build loses the reveal row rather than silently
// gaining a process-tree walk it never asked for.
trackSessionApp = try c.decodeIfPresent(Bool.self, forKey: .trackSessionApp) ?? false
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run ClaudeIslandTests Settings` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeIslandCore/IslandSettings.swift Tests/ClaudeIslandCoreTests/SettingsTests.swift
git commit -m "Add the setting that governs the walk back to the terminal"
```

---

### Task 2: The hook client's `--no-ancestry` flag

**Files:**
- Modify: `Sources/claude-island-notify/main.swift` (~line 274, the `splicingAncestry` call)
- Test: `Tests/ClaudeIslandCoreTests/SocketPipelineTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 — the client never reads settings.
- Produces: the client honours `--no-ancestry` in argv.

- [ ] **Step 1: Write the failing test**

`SocketPipelineTests.swift` already spawns the real client against a temp socket; follow the existing helper in that file for spawning and reading one framed payload. Add:

```swift
test("The client sends the payload untouched when ancestry is switched off") {
    let raw = "{\"session_id\":\"s1\",\"hook_event_name\":\"PreToolUse\"}"
    let received = try await runClient(sending: raw, arguments: ["--no-ancestry"])
    await expectEqual(received, raw)
}

test("The client still stamps ancestry when the flag is absent") {
    let raw = "{\"session_id\":\"s1\",\"hook_event_name\":\"PreToolUse\"}"
    let received = try await runClient(sending: raw, arguments: [])
    await expect(received.contains("\"_island_pids\":["), "expected ancestry, got \(received)")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift run ClaudeIslandTests Socket`
Expected: FAIL — the first test receives a payload beginning `{"_island_pids":[`.

- [ ] **Step 3: Implement**

In `main.swift`, replace the unconditional splice:

```swift
// `--no-ancestry` is the whole of the opt-out on this side. Argv, not a file
// and not a parse: this binary reads stdin, connects, writes and exits, and
// keeping it that way is what holds it inside its millisecond budget on every
// tool call. A sentinel file would cost a syscall per event and reintroduce
// exactly what settings.json replaced.
//
// Skipping the walk as well as the splice is the point. Measuring an ancestry
// nobody will read would leave the cost in place and only hide the result.
let payload =
    CommandLine.arguments.contains("--no-ancestry")
    ? raw
    : splicingAncestry(into: raw, ancestorPIDs())
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run ClaudeIslandTests Socket` → PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/claude-island-notify/main.swift Tests/ClaudeIslandCoreTests/SocketPipelineTests.swift
git commit -m "Let the hook client be told not to walk the process tree"
```

---

### Task 3: The installer writes and detects the flag

**Files:**
- Modify: `Sources/ClaudeIslandCore/HookInstaller.swift` (`command` line 65, `matcher` 52, `hooksDictionary` 42, `hookBlockJSON` 31, `install` 76, `isCurrent` 171)
- Test: `Tests/ClaudeIslandCoreTests/HookInstallerTests.swift`

**Interfaces:**
- Consumes: `IslandSettings.trackSessionApp` (Task 1) — passed in by callers, not read here.
- Produces: `HookInstaller.install(binaryPath:trackSessionApp:settingsURL:)`, `HookInstaller.isCurrent(binaryPath:trackSessionApp:settingsURL:)`, `HookInstaller.hookBlockJSON(binaryPath:trackSessionApp:)`

- [ ] **Step 1: Write the failing test**

```swift
test("The installed command carries the opt-out flag only when tracking is off") {
    let url = tempSettingsURL()
    try HookInstaller.install(binaryPath: "/bin/notify", trackSessionApp: false, settingsURL: url)
    let off = try String(contentsOf: url, encoding: .utf8)
    await expect(off.contains("--no-ancestry"), "expected the flag when tracking is off")

    try HookInstaller.install(binaryPath: "/bin/notify", trackSessionApp: true, settingsURL: url)
    let on = try String(contentsOf: url, encoding: .utf8)
    await expect(!on.contains("--no-ancestry"), "expected no flag when tracking is on")
}

// Event flags first, then global ones. `isCurrent` compares command strings
// exactly, so an unstable order would make the installer report drift against
// its own most recent write.
test("Global flags follow event flags in the command") {
    let block = HookInstaller.hookBlockJSON(binaryPath: "/bin/notify", trackSessionApp: false)
    await expect(
        block.contains("/bin/notify --await-decision --no-ancestry"),
        "unexpected argument order in \(block)")
}

test("Hooks written for one tracking state read as stale in the other") {
    let url = tempSettingsURL()
    try HookInstaller.install(binaryPath: "/bin/notify", trackSessionApp: false, settingsURL: url)
    await expectEqual(
        HookInstaller.isCurrent(
            binaryPath: "/bin/notify", trackSessionApp: false, settingsURL: url), true)
    await expectEqual(
        HookInstaller.isCurrent(
            binaryPath: "/bin/notify", trackSessionApp: true, settingsURL: url), false)
}
```

Use whatever temp-settings helper `HookInstallerTests.swift` already defines; if it inlines the URL, inline it the same way rather than adding a helper.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift run ClaudeIslandTests Hook`
Expected: FAIL — extra argument `trackSessionApp` in call.

- [ ] **Step 3: Implement**

Thread the flag through. `command` becomes:

```swift
/// Event arguments first, then global ones, and that order is load-bearing:
/// `isCurrent` compares whole command strings, so an order that varied would
/// make a freshly written block read as stale against itself.
private static func command(binaryPath: String, event: HookEvent, trackSessionApp: Bool) -> String {
    let global = trackSessionApp ? [] : ["--no-ancestry"]
    return ([quoteIfNeeded(binaryPath)] + event.clientArguments + global)
        .joined(separator: " ")
}
```

Add `trackSessionApp: Bool` to `matcher`, `hooksDictionary`, `hookBlockJSON`, `install` and `isCurrent`, forwarding it. Put it after `binaryPath` and before `settingsURL` everywhere, so every signature reads the same way.

- [ ] **Step 4: Run to verify it passes**

Run: `swift run ClaudeIslandTests Hook` → PASS. The app target will not compile yet; Task 6 fixes its call sites.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeIslandCore/HookInstaller.swift Tests/ClaudeIslandCoreTests/HookInstallerTests.swift
git commit -m "Write the ancestry opt-out into the hook block"
```

---

### Task 4: The app ignores ancestry when tracking is off

**Files:**
- Modify: `Sources/ClaudeIslandApp/AppController.swift` (static `rings` ~line 388)
- Modify: `Sources/ClaudeIslandApp/IslandViewModel.swift` (`refreshOwners` ~line 835)
- Test: `Tests/ClaudeIslandCoreTests/TerminalAppsTests.swift` (where the existing `rings` matrix lives)

**Interfaces:**
- Consumes: `IslandSettings.trackSessionApp` (Task 1)
- Produces: no new API; `rings` gains the gate internally.

- [ ] **Step 1: Write the failing test**

Add beside the existing mute-matrix tests:

```swift
// The safety net that makes the setting authoritative. Hooks can be stale,
// hand-edited, or rewritten by another tool, so a session can still be
// carrying a resolvable ancestry after tracking is switched off. What is on
// screen has to follow the setting, not the payload.
test("With tracking off the mute ignores a resolved owner and falls back") {
    var settings = IslandSettings()
    settings.trackSessionApp = false
    settings.muteWhileTerminalFrontmost = true
    // Owner matches frontmost: with tracking on this would silence the cue.
    await expectEqual(
        AppController.rings(
            .done, under: settings, frontmost: "com.apple.Safari", owner: "com.apple.Safari"),
        true)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift run ClaudeIslandTests Terminal`
Expected: FAIL — got `false`, because the owner still matched.

- [ ] **Step 3: Implement**

Inside the static `rings`, before the owner is consulted:

```swift
// Tracking off means there is no owner to speak of, whatever the payload
// happens to still carry. Collapsing it here rather than at the call site
// keeps the rule in the one pure function --selftest and the suites drive.
let owner = settings.trackSessionApp ? ownerBundleID() : nil
```

and use that local everywhere the autoclosure was called. In `refreshOwners`, return early so the walk is never even attempted:

```swift
guard mode == .expanded, settings.trackSessionApp else {
    ownerCache = [:]
    return
}
```

Clearing rather than leaving the cache is deliberate: a stale entry would outlive the setting change and draw a row that the card no longer reserves space for. `IslandViewModel` needs access to the current settings for this — follow whatever it already uses to read `debugTint`; if it holds no settings reference, add a `var trackSessionApp: Bool = false` set by `AppController` alongside the other live-applied settings.

- [ ] **Step 4: Run to verify it passes**

Run: `swift run ClaudeIslandTests` → PASS (all suites)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeIslandApp/AppController.swift Sources/ClaudeIslandApp/IslandViewModel.swift Tests/ClaudeIslandCoreTests/TerminalAppsTests.swift
git commit -m "Let the setting, not the payload, decide whether a session has an app"
```

---

### Task 5: The row disappears and the card shrinks

**Files:**
- Modify: `Sources/ClaudeIslandApp/IslandContentViews.swift:349` (the `RevealRow` call site)
- Modify: `Sources/ClaudeIslandApp/IslandViewModel.swift` (`expandedChromeHeight` ~line 270, `expandedHeight` ~line 732)
- Modify: `Sources/ClaudeIslandApp/SelfTest.swift` (~line 1765-1795)

**Interfaces:**
- Consumes: `IslandViewModel.trackSessionApp` (Task 4)
- Produces: `IslandViewModel.revealBlockHeight: CGFloat` — `revealRowHeight + 5` when tracking is on, `0` when off.

- [ ] **Step 1: Write the failing check**

This one is guarded by `--selftest`, not the unit harness. Replace the single sizing check with a pair that runs in both states. In `SelfTest.swift`, beside the existing reveal check:

```swift
// Two states now, and the pair is the check. The card is sized from a
// hand-tallied constant, so hiding a row without taking its height out of
// that tally would leave a gap that no single-state check can see: each
// state on its own looks self-consistent, and only the difference between
// them shows the tally drifting from what is drawn.
model.trackSessionApp = true
let withRow = model.expandedHeight(for: sessions)
model.trackSessionApp = false
let withoutRow = model.expandedHeight(for: sessions)
checks.append(
    Check(
        name: "hiding the reveal row shortens the card by exactly the row",
        passed: abs((withRow - withoutRow) - (IslandViewModel.revealRowHeight + 5)) < 0.5,
        detail: "with=\(withRow) without=\(withoutRow) "
            + "expected difference=\(IslandViewModel.revealRowHeight + 5)"))
model.trackSessionApp = true
```

Keep the existing "the reveal row's content fits the height the card reserves" check exactly as it is — it still applies whenever the row is drawn.

- [ ] **Step 2: Run it to verify it fails**

Run: `rm -f ~/.claude-island/force-mode; swift run ClaudeIslandApp --selftest 2>&1 | grep -i reveal`
Expected: FAIL — the difference is 0, because the height is still a constant.

**Note:** clear `force-mode` first, or roughly a dozen unrelated mode checks fail and read as a regression.

- [ ] **Step 3: Implement**

Take the term out of the constant and give it a name:

```swift
    static let expandedChromeHeight: CGFloat =
        bodyTopPadding  // 7
        + 12  // "sessions" label row plus its 3pt bottom padding
        + 15  // divider with 7pt above and below
        + 13  // meta line
        + 28  // context label, its 7pt top padding, and the meter
        + bodyBottomPadding  // 13

    /// The reveal row and its 5pt top padding, or nothing when the session's
    /// app is not being tracked.
    ///
    /// Conditional, so it belongs here rather than in `expandedChromeHeight` —
    /// the same reason the chip row and the 5-hour meter are added in
    /// `expandedHeight` instead of tallied into the constant.
    var revealBlockHeight: CGFloat { trackSessionApp ? Self.revealRowHeight + 5 : 0 }
```

Add `+ revealBlockHeight` to the sum in `expandedHeight`. At the call site in `IslandContentViews.swift`:

```swift
                if model.trackSessionApp {
                    RevealRow(session: session, model: model)
                        .padding(.top, 5)
                }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run ClaudeIslandApp --selftest 2>&1 | tail -5`
Expected: every check passes (one skip, `not running from a .app bundle`, is expected outside a bundle).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeIslandApp/IslandContentViews.swift Sources/ClaudeIslandApp/IslandViewModel.swift Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "Let the card end where it does when there is no reveal row"
```

---

### Task 6: The toggle, its caption, and the amended Sounds caption

**Files:**
- Modify: `Sources/ClaudeIslandApp/SettingsStore.swift` (~line 22, beside the other `didSet` properties)
- Modify: `Sources/ClaudeIslandApp/SettingsView.swift` (General pane ~line 157; Sounds caption ~line 433; `installHooks` 847; `hookStatus` 753; the paste-block button 894)

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces: `SettingsStore.trackSessionApp: Bool`

- [ ] **Step 1: Add the store property**

```swift
var trackSessionApp: Bool { didSet { persist() } }
```

Set it in the initialiser from `settings.trackSessionApp`, and write it back in the `current` builder, alongside every other property.

- [ ] **Step 2: Add the toggle to General**

In the first `Section` of `generalPane`, after "Show the HUD":

```swift
                Toggle("Find the app each session is running in", isOn: $store.trackSessionApp)
```

with a footer:

```swift
                Text(
                    "Reads each session's process ancestry so the expanded card can offer a "
                        + "jump to the app it is running in, and so \"Stay quiet while a "
                        + "terminal is frontmost\" can tell your session's own app from any "
                        + "terminal. The jump reaches the app, never the tab, so several "
                        + "sessions in one editor all land in the same place. Switching this "
                        + "on or off rewrites this app's hook commands in "
                        + "~/.claude/settings.json."
                )
```

- [ ] **Step 3: Amend the Sounds caption**

The mute footer currently promises per-session exactness unconditionally. Make the promise conditional on the new setting, keeping the existing text for the tracking-on case and adding, when off:

```swift
                        + (store.trackSessionApp
                            ? ""
                            : " With \"Find the app each session is running in\" switched off, "
                                + "this cannot tell one session's app from another, so it goes "
                                + "quiet for any terminal or editor at all.")
```

- [ ] **Step 4: Fix the three `HookInstaller` call sites**

`installHooks()`, `hookStatus`, and the paste-block button each gain `trackSessionApp: store.trackSessionApp`.

- [ ] **Step 5: Build and check by eye**

Run: `swift build 2>&1 | tail -5` → no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeIslandApp/SettingsStore.swift Sources/ClaudeIslandApp/SettingsView.swift
git commit -m "Offer the walk back to the terminal as a setting"
```

---

### Task 7: Rewrite the hooks on change, and reconcile at launch

**Files:**
- Modify: `Sources/ClaudeIslandApp/AppController.swift` (wherever `settings.onChange` is assigned, and the launch path)

**Interfaces:**
- Consumes: Tasks 1, 3 and 6.

- [ ] **Step 1: Rewrite on change**

In the `onChange` handler, when `trackSessionApp` differs from what the installed block encodes:

```swift
    /// Keeps the hook block in step with the setting, so the walk actually
    /// stops rather than merely being ignored.
    ///
    /// Only ever rewrites a block that is already ours: a hand-rolled or
    /// third-party hook is somebody else's file to manage. Nothing is written
    /// when hooks are not installed at all — there is no block to correct, and
    /// installing one uninvited would put this app in a file the user never
    /// asked it to touch.
    private func reconcileHooks(with settings: IslandSettings) {
        let binary = notifyBinaryPath()
        guard HookInstaller.isInstalled(),
            !HookInstaller.isCurrent(binaryPath: binary, trackSessionApp: settings.trackSessionApp)
        else { return }
        do {
            try HookInstaller.install(binaryPath: binary, trackSessionApp: settings.trackSessionApp)
        } catch {
            // Reported, never swallowed: a rewrite that failed leaves the walk
            // running, and the only visible symptom would be a battery cost
            // nobody can trace back to here. The setting still governs what is
            // drawn, so the app is wrong-but-quiet without this.
            log.debug("could not rewrite hooks for trackSessionApp: \(error)")
            settingsStore.onWriteFailure?(error)
        }
    }
```

- [ ] **Step 2: Reconcile at launch**

Call `reconcileHooks(with:)` once during startup, after settings load. Without it every existing install flips to `false` on upgrade, finds hooks that lack the flag, and sits in the "Update Hooks" state until someone visits a pane they had no reason to visit.

- [ ] **Step 3: Verify by hand against a scratch settings file**

Do **not** point this at your real `~/.claude/settings.json`. Copy it to `tmp/`, run the installer against the copy through the test harness, and confirm the flag appears and disappears with the setting.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeIslandApp/AppController.swift
git commit -m "Keep the hook block in step with the setting"
```

---

### Task 8: Documentation and a full verification pass

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the default and what upgrading changes**

Record that the reveal row is off by default, that switching it on rewrites the hook block, and that the frontmost-mute is less precise while it is off.

- [ ] **Step 2: Full verification**

```bash
swift run ClaudeIslandTests
rm -f ~/.claude-island/force-mode
swift run ClaudeIslandApp --selftest
```

Expected: every unit test passes; `--selftest` passes with only the `not running from a .app bundle` skip.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Say that the walk back to the terminal ships switched off"
```

## Self-Review

**Spec coverage.** Setting and default → Task 1. Client flag → Task 2. Installer emission and detection → Task 3. Mute fallback and the ignore-the-payload safety net → Task 4. Row hidden and card resized, with the sizing checks → Task 5. Toggle, its caption, the amended Sounds caption → Task 6. Rewrite on toggle, reconcile at launch, surfaced failure → Task 7. README → Task 8. Every "Supporting changes" entry in the spec has a task.

**Type consistency.** `trackSessionApp` is the name in `IslandSettings`, `SettingsStore`, `IslandViewModel` and every `HookInstaller` signature. The flag string is `--no-ancestry` in the client and the installer. `revealBlockHeight` is defined in Task 5 and used only there.

**Known gap.** Task 4 leaves one thing to the implementer's judgement — how `IslandViewModel` reads the setting, since that depends on how it already receives `debugTint`. That is a lookup, not a decision.
