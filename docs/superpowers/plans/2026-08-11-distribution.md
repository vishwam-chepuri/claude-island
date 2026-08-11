# Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ClaudeIsland installable by a stranger in one command, and keep it running across reboots.

**Architecture:** No signing identity exists, so a downloaded `.app` would arrive quarantined. Locally compiled code never is — so `Scripts/install.sh` clones, builds via the existing `bundle.sh`, installs to `/Applications`, and offers to wire up hooks. Launch-at-login uses `SMAppService.mainApp`, wrapped in a tiny `LoginItem` enum so `AppController` only gains a menu item.

**Tech Stack:** Bash, Swift 6, AppKit, ServiceManagement. No third-party dependencies.

## Global Constraints

- **macOS 14+.** `LSMinimumSystemVersion` is `14.0`; `install.sh` must refuse anything lower.
- **No third-party dependencies, ever.** `Package.swift` has none and gains none.
- **The app makes no network calls.** `install.sh` fetches; the app never does. Do not add an update check.
- **Ad-hoc signing only.** No Developer ID, no notarization, no hardened runtime flags.
- **Tests run `swift run ClaudeIslandTests`, never `swift test`.** XCTest is Xcode-only here.
- **Commits carry no `Co-Authored-By` line** (tree-level CLAUDE.md).
- **`git diff` is broken globally.** Any diffing command needs `-c diff.external=`, e.g. `git -c diff.external= show`.
- **Repo:** `github.com/vishwam-chepuri/claude-island`. The `gh` CLI is authenticated as a *different* account (`Vishwam10`) — see Task 6.

## File Structure

| File | Responsibility |
|---|---|
| `Scripts/install.sh` | **Create.** The one-liner: preflight, clone, build, install, hooks, launch. |
| `Sources/ClaudeIslandApp/LoginItem.swift` | **Create.** Sole owner of `SMAppService`. Nothing else imports ServiceManagement. |
| `Sources/ClaudeIslandApp/AppController.swift` | **Modify.** One menu item, one `@objc` action. |
| `Sources/ClaudeIslandApp/SelfTest.swift` | **Modify.** One check, state-restoring. |
| `Scripts/bundle.sh` | **Modify.** `VERSION` from the git tag. |
| `README.md` | **Modify.** Prepend a hero section. |

---

### Task 1: Spike — does `SMAppService` accept an ad-hoc signature?

**This is a decision gate, not a feature.** The spec names it as the one real risk. Nothing in Task 2 is worth building until it is answered. All code here is thrown away.

**Files:** none committed.

**Interfaces:**
- Consumes: nothing.
- Produces: a yes/no answer that decides whether Task 2 ships as written or as its fallback.

- [ ] **Step 1: Build and install a real bundle**

`SMAppService.mainApp` registers *the running bundle*, so this must be tested from `/Applications`, not `dist/`.

```bash
cd "/Users/vishwam/personal projects/claude dynamic island"
./Scripts/bundle.sh release
rm -rf /Applications/ClaudeIsland.app
cp -R dist/ClaudeIsland.app /Applications/
```

- [ ] **Step 2: Write a throwaway probe**

Create `/tmp/spike.swift` (outside the repo — this is not committed):

```swift
import Foundation
import ServiceManagement

let service = SMAppService.mainApp
print("status before: \(service.status.rawValue)")
do {
    try service.register()
    print("register() succeeded")
} catch {
    print("register() FAILED: \(error)")
}
print("status after: \(service.status.rawValue)")
```

- [ ] **Step 3: Run it from inside the installed bundle**

The probe must run as the bundled app, so temporarily call it from `main.swift` behind a `--spike` argument, rebuild, reinstall, and run:

```bash
/Applications/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --spike
```

`status` raw values: `0` = notRegistered, `1` = enabled, `2` = requiresApproval, `3` = notFound.

- [ ] **Step 4: Confirm it survives a rebuild — this is the real test**

Ad-hoc signatures produce a **different cdhash on every build**. A login item registered against one build may be invalidated when the bundle is replaced, which is exactly what `install.sh` does on every update. So:

```bash
./Scripts/bundle.sh release
rm -rf /Applications/ClaudeIsland.app && cp -R dist/ClaudeIsland.app /Applications/
/Applications/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --spike   # status before: still 1?
```

Then reboot and confirm the app actually launches.

- [ ] **Step 5: Record the verdict and clean up**

```bash
rm /tmp/spike.swift
git -C "/Users/vishwam/personal projects/claude dynamic island" checkout Sources/ClaudeIslandApp/main.swift
```

**Decision:**
- `register()` succeeds **and** survives Step 4 → Task 2 as written.
- `register()` throws, or status resets after a rebuild → **stop and report.** The fallback is a `~/Library/LaunchAgents` plist written by `install.sh`, which the spec says to take only if this fails — and which the user has said they may prefer to drop entirely rather than ship. Do not choose unilaterally.

---

### Task 2: Launch at login

**Files:**
- Create: `Sources/ClaudeIslandApp/LoginItem.swift`
- Modify: `Sources/ClaudeIslandApp/SelfTest.swift` (check appended before the summary block, near line 264)
- Modify: `Sources/ClaudeIslandApp/AppController.swift` (menu in `rebuildMenu()`, action beside `toggleDebugTint`)

**Interfaces:**
- Consumes: nothing.
- Produces: `enum LoginItem` with `static var isAvailable: Bool`, `static var isEnabled: Bool`, `static var status: SMAppService.Status`, and `static func setEnabled(_ enabled: Bool) throws`.

The test comes first, and it is a `--selftest` check rather than a unit test: `ClaudeIslandTests` links no AppKit and cannot touch `SMAppService`, which is exactly the situation `--selftest` exists for.

- [ ] **Step 1: Write the failing self-test check**

In `SelfTest.swift`, immediately before the `var failures = 0` summary block (~line 274), add:

```swift
        // Registration silently failing is precisely the failure this feature
        // exists to prevent, and it would otherwise only surface on someone
        // else's reboot. Prior state is restored so running the self-test never
        // leaves a login item behind.
        if !LoginItem.isAvailable {
            checks.append(
                Check(
                    name: "launch at login registers",
                    skipped: "not running from a .app bundle"))
        } else {
            let wasEnabled = LoginItem.isEnabled
            do {
                try LoginItem.setEnabled(true)
                if LoginItem.status == .requiresApproval {
                    checks.append(
                        Check(
                            name: "launch at login registers",
                            skipped: "approval was revoked in System Settings"))
                } else {
                    checks.append(
                        Check(
                            name: "launch at login registers",
                            passed: LoginItem.isEnabled,
                            detail: "status \(LoginItem.status.rawValue)"))
                }
            } catch {
                checks.append(
                    Check(
                        name: "launch at login registers",
                        passed: false,
                        detail: "\(error)"))
            }
            try? LoginItem.setEnabled(wasEnabled)
        }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift build 2>&1 | tail -20
```

Expected: **compile error** — `cannot find 'LoginItem' in scope`. That is the failing state; there is no binary to run yet.

- [ ] **Step 3: Write `LoginItem.swift`**

```swift
import Foundation
import ServiceManagement

/// The only place `SMAppService` is touched.
///
/// `SMAppService.mainApp` registers the *running bundle*, so this is
/// meaningless outside a `.app` — from `swift run` there is no bundle to
/// register and `register()` fails. `isAvailable` gates on that rather than
/// letting the menu offer something that cannot work.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Throws whatever `SMAppService` throws. Callers surface it rather than
    /// swallow it: a login item that silently did not register is the one
    /// failure mode worth an alert.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 4: Add the menu item**

In `AppController.rebuildMenu()`, directly after the `tint` item is added to the menu (~line 349) and before `reveal`:

```swift
        if LoginItem.isAvailable {
            let login = NSMenuItem(
                title: LoginItem.isEnabled ? "Don't Launch at Login" : "Launch at Login",
                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            menu.addItem(login)
        }
```

- [ ] **Step 5: Add the action**

In `AppController`, directly after `toggleDebugTint()` (~line 461):

```swift
    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
            // Approval lives in System Settings and cannot be granted from here,
            // so say where it is rather than leaving the menu title lying.
            if LoginItem.status == .requiresApproval {
                let alert = NSAlert()
                alert.messageText = "Approval needed"
                alert.informativeText =
                    "Enable ClaudeIsland under System Settings → General → Login Items."
                alert.runModal()
            }
        } catch {
            presentError("Could not change the login item", error)
        }
        rebuildMenu()
    }
```

- [ ] **Step 6: Build, bundle, install, and run the self-test**

```bash
swift build && ./Scripts/bundle.sh release
rm -rf /Applications/ClaudeIsland.app && cp -R dist/ClaudeIsland.app /Applications/
/Applications/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --selftest
```

Expected: **45 checks passed** (44 existing + this one). Run with the screen unlocked, or three unrelated checks report as skipped and the exit code is 2.

- [ ] **Step 7: Confirm the self-test left no trace**

```bash
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
```

Expected: ClaudeIsland is **absent** (or in whatever state it was in before Step 6) — the check restores `wasEnabled`.

- [ ] **Step 8: Verify the menu item by hand**

Launch the app, click the menu bar extra, toggle **Launch at Login**, confirm the title flips to "Don't Launch at Login" and the entry appears in System Settings. Toggle it back off.

- [ ] **Step 9: Commit**

```bash
git add Sources/ClaudeIslandApp/LoginItem.swift Sources/ClaudeIslandApp/AppController.swift Sources/ClaudeIslandApp/SelfTest.swift
git commit -m "Survive a reboot

An always-on HUD that vanishes on restart is indistinguishable from one
that broke. SMAppService.mainApp, wrapped so nothing else imports
ServiceManagement, with a self-test check because registration failing
silently would otherwise only surface on someone else's reboot."
```

---

### Task 3: Version `bundle.sh` from the git tag

**Files:**
- Modify: `Scripts/bundle.sh:33` (the `VERSION="0.1.0"` line)

**Interfaces:**
- Consumes: nothing.
- Produces: `CFBundleShortVersionString` derived from `git describe --tags --abbrev=0`, with the leading `v` stripped. Task 6 relies on this reading the `v0.1.0` tag.

- [ ] **Step 1: Replace the hardcoded version**

In `Scripts/bundle.sh`, replace:

```bash
VERSION="0.1.0"
```

with:

```bash
# The tag is the version. Outside a tagged checkout — a fresh shallow clone
# before any tag exists, or a branch ahead of one — say so rather than claim a
# release number that was never cut.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0-dev")"
VERSION="${VERSION#v}"
```

`CFBundleVersion` keeps the short SHA it already uses; only the marketing version changes.

- [ ] **Step 2: Verify it falls back cleanly with no tags**

There are currently no tags, so this exercises the fallback path first:

```bash
cd "/Users/vishwam/personal projects/claude dynamic island"
git tag -l                     # expect: empty
./Scripts/bundle.sh release
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/ClaudeIsland.app/Contents/Info.plist
```

Expected: `0.0.0-dev`

- [ ] **Step 3: Verify it reads a tag, then remove the throwaway tag**

```bash
git tag v9.9.9-test
./Scripts/bundle.sh release
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/ClaudeIsland.app/Contents/Info.plist
git tag -d v9.9.9-test
```

Expected: `9.9.9-test` — confirming both the tag read and the `v` strip.

- [ ] **Step 4: Commit**

```bash
git add Scripts/bundle.sh
git commit -m "Take the version from the tag

A hardcoded 0.1.0 would ship as 0.1.0 forever. Outside a tagged checkout
it reports 0.0.0-dev rather than claiming a release that was never cut."
```

---

### Task 4: `Scripts/install.sh`

**Files:**
- Create: `Scripts/install.sh`

**Interfaces:**
- Consumes: `Scripts/bundle.sh` (invoked, not reimplemented), and `ClaudeIsland --install-hooks`.
- Produces: nothing other tasks consume. Task 5 documents its URL.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# One-line installer for ClaudeIsland.
#
#   curl -fsSL https://raw.githubusercontent.com/vishwam-chepuri/claude-island/main/Scripts/install.sh | bash
#
# It builds from source rather than downloading a binary, and that is the whole
# point: there is no Developer ID to sign with, so a downloaded .app would
# arrive quarantined and Sequoia removed the Control-click bypass. Code compiled
# on the machine it runs on is never quarantined.

set -euo pipefail

REPO="https://github.com/vishwam-chepuri/claude-island.git"
APP_NAME="ClaudeIsland.app"
DRY_RUN=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say()  { echo "==> $*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then echo "    would: $*"; else "$@"; fi; }
die()  { echo "error: $*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || die "ClaudeIsland needs macOS 14 or later (found $(sw_vers -productVersion))."

# Command Line Tools ships the Swift compiler, git, and codesign. Its installer
# is an asynchronous GUI, so trigger it and exit — a script that waits on it
# either hangs or races the user.
if ! xcode-select -p >/dev/null 2>&1; then
    say "Command Line Tools are required. Opening Apple's installer."
    xcode-select --install >/dev/null 2>&1 || true
    die "Finish that install, then re-run this command."
fi

# /Applications is writable by admin users; fall back rather than ask for sudo.
if [ -w /Applications ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
    run mkdir -p "$DEST"
fi

# --- Build -----------------------------------------------------------------

TMP="$(mktemp -d)"
# The clone is temporary on purpose: a repo left in a surprise location is state
# that goes stale and that nobody knows to delete. Updating is re-running this.
trap 'rm -rf "$TMP"' EXIT

say "Cloning vishwam-chepuri/claude-island"
run git clone --depth 1 --quiet "$REPO" "$TMP/src"

say "Building (this takes a minute)"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "    would: $TMP/src/Scripts/bundle.sh release"
else
    ( cd "$TMP/src" && ./Scripts/bundle.sh release >/dev/null )
fi

# --- Install ---------------------------------------------------------------

# Copying over a live bundle produces a half-replaced app.
if pgrep -x ClaudeIsland >/dev/null 2>&1; then
    say "Quitting the running copy"
    run pkill -x ClaudeIsland
    run sleep 1
fi

say "Installing to $DEST"
run rm -rf "$DEST/$APP_NAME"
run cp -R "$TMP/src/dist/$APP_NAME" "$DEST/"

APP="$DEST/$APP_NAME"
BIN="$APP/Contents/MacOS/ClaudeIsland"

# --- Hooks -----------------------------------------------------------------

# Piped into bash, stdin *is this script* — a prompt that reads stdin would
# consume its own source. /dev/tty reaches the user's terminal regardless.
if [ "$ASSUME_YES" -eq 1 ]; then
    answer=y
elif [ -r /dev/tty ]; then
    printf '==> Install Claude Code hooks into ~/.claude/settings.json? [Y/n] '
    read -r answer < /dev/tty || answer=y
    answer="${answer:-y}"
else
    answer=n
fi

case "$answer" in
    [Yy]*)
        say "Installing hooks"
        run "$BIN" --install-hooks
        ;;
    *)
        say "Skipped. Run '$BIN --install-hooks' when you're ready."
        ;;
esac

# --- Launch ----------------------------------------------------------------

say "Launching"
run open "$APP"

echo ""
echo "Installed $APP"
echo "Restart any running Claude Code sessions to pick up the hooks."
echo "Enable 'Launch at Login' from the menu bar extra to keep it across reboots."
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Scripts/install.sh
```

- [ ] **Step 3: Verify `--dry-run` touches nothing**

```bash
./Scripts/install.sh --dry-run
```

Expected: every mutating line prefixed `would:` — clone, bundle, rm, cp, hooks, open. Then confirm nothing happened:

```bash
ls -d /Applications/ClaudeIsland.app   # from Task 2; must not have been replaced
```

- [ ] **Step 4: Verify the macOS floor and the option parser**

```bash
./Scripts/install.sh --help          # expect: the usage comment, exit 0
./Scripts/install.sh --nonsense      # expect: "unknown option: --nonsense", exit 2
```

- [ ] **Step 5: Run it for real**

```bash
./Scripts/install.sh
```

Expected: builds, quits the running copy, installs to `/Applications`, prompts for hooks, launches. Confirm the temp dir is gone (the trap fired) and the island appears.

- [ ] **Step 6: Test it piped — this cannot be verified any other way**

The `/dev/tty` handling only matters when stdin is occupied, so it must actually be piped. Before the script exists on `main`, simulate it locally:

```bash
cat Scripts/install.sh | bash -s -- --dry-run
```

Expected: reaches the hook prompt and **accepts typed input** rather than skipping past it or hanging. A script reading plain stdin fails here; this is the whole reason for `/dev/tty`.

- [ ] **Step 7: Commit**

```bash
git add Scripts/install.sh
git commit -m "Install in one line

Builds from source rather than shipping a binary, because there is no
Developer ID and a downloaded .app would arrive quarantined. The hook
prompt reads /dev/tty: piped into bash, stdin is the script itself."
```

---

### Task 5: README hero

**Files:**
- Modify: `README.md:1-30` (prepend; the existing `## Build` section onward is untouched)

**Interfaces:**
- Consumes: the `install.sh` URL from Task 4.
- Produces: nothing.

The current README opens with build instructions and reaches architecture by line 40. It is a good engineering document and a bad landing page. This is a **prepend, not a rewrite** — everything from `## Build` down stays exactly as written.

- [ ] **Step 1: Replace the opening block**

Replace lines 1–30 (from `# ClaudeIsland` through the closing fence of the ASCII diagram, stopping *before* `## Build`) with:

````markdown
# ClaudeIsland

A Dynamic Island-style HUD pinned to the notch that shows, in real time, what
your running Claude Code sessions are doing.

```
┌─────────────────────────────────────────────┐
│  ⌘ Bash  swift build           0:12     o°o │   compact
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│  ✋ Allow Write? · claude-island   0:07   ②  │   alert
│     ~/notch/Sources/IslandPanel.swift        │
└─────────────────────────────────────────────┘
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/vishwam-chepuri/claude-island/main/Scripts/install.sh | bash
```

Clones, builds, installs to `/Applications`, and offers to wire up the hooks.
Pass `--dry-run` to see exactly what it would do first, or read it — it is
[one file](Scripts/install.sh).

It builds from source rather than downloading a binary, and that is deliberate:
this project has no Developer ID to sign with, so a downloaded `.app` would
arrive quarantined and macOS would tell you it could not be verified. Code
compiled on your own machine never is. Building also means you get a binary for
your own architecture with no universal-binary machinery.

**Requirements:** macOS 14+, and Command Line Tools (the script offers to
install them). No Xcode. No dependencies. Roughly a minute to build.

Restart any running Claude Code sessions afterwards, and turn on **Launch at
Login** from the menu bar extra so it survives a reboot.

Everything is local — the app makes no network calls, ever.
````

- [ ] **Step 2: Verify the fences survived**

Nested code fences are the easy way to corrupt this file. Confirm the count is even and the ASCII diagram still renders:

```bash
grep -c '^```' README.md
```

Expected: an even number. Then open the preview in an editor and confirm the diagram block is not swallowing the Install section.

- [ ] **Step 3: Confirm nothing below `## Build` moved**

```bash
git -c diff.external= diff --stat README.md
```

Expected: additions concentrated at the top; the architecture, "Things worth knowing", and notch sections show no changes.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Lead with how to install it

The README opened with build instructions and reached architecture by
line 40 — a good engineering document and a bad landing page. The rest
stays exactly as written."
```

---

### Task 6: Cut v0.1.0

**Files:** none. This is release mechanics.

**Interfaces:**
- Consumes: Task 3's tag-derived version.
- Produces: the `v0.1.0` tag and a GitHub release.

- [ ] **Step 1: Resolve the `gh` account mismatch — do this first, and ask**

`gh` is authenticated as `Vishwam10`; the repo belongs to `vishwam-chepuri`. The tree's CLAUDE.md requires confirming which account owns a `gh` write before making one.

```bash
gh auth status
gh api user --jq .login          # expect: Vishwam10
```

**Stop and ask the user** which account should create the release. Do not run `gh release create` under `Vishwam10` on the assumption it will work.

- [ ] **Step 2: Merge the feature branch**

`permission-decisions-from-the-island` carries commits that are not on `main`, plus everything from this plan. A tag should describe what ships.

```bash
git checkout main
git merge --no-ff permission-decisions-from-the-island
```

- [ ] **Step 3: Verify main is green before tagging**

```bash
swift build && swift run ClaudeIslandTests
./Scripts/bundle.sh release
/Applications/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --selftest
```

Expected: 98+ tests passing, 45 self-test checks passing. **Do not tag on a red build.**

- [ ] **Step 4: Tag**

```bash
git tag -a v0.1.0 -m "First release"
git push origin main --tags
```

- [ ] **Step 5: Verify the tag flows into the bundle**

This is the whole reason Task 3 exists:

```bash
./Scripts/bundle.sh release
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/ClaudeIsland.app/Contents/Info.plist
```

Expected: `0.1.0`

- [ ] **Step 6: Create the release**

Using whichever account Step 1 settled on. No binary is attached — the install path is the script, and attaching an ad-hoc `.app` would invite exactly the quarantine problem this design avoids.

```bash
gh release create v0.1.0 -R vishwam-chepuri/claude-island \
  --title "v0.1.0" \
  --notes "Install: \`curl -fsSL https://raw.githubusercontent.com/vishwam-chepuri/claude-island/main/Scripts/install.sh | bash\`

Builds from source — macOS 14+, Command Line Tools, no Xcode, no dependencies."
```

- [ ] **Step 7: Verify the one-liner works from a clean state**

The real test. On a machine (or account) without the repo:

```bash
rm -rf /Applications/ClaudeIsland.app
curl -fsSL https://raw.githubusercontent.com/vishwam-chepuri/claude-island/main/Scripts/install.sh | bash
```

Expected: clone, build, prompt, launch. If the raw URL 404s, `main` has not been pushed.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| One line / seven steps | 4 |
| `/dev/tty` prompt | 4 (Steps 1, 6) |
| `--dry-run` | 4 (Step 3) |
| CLT async-installer trap | 4 (Step 1 preflight) |
| Temp clone, not permanent | 4 (Step 1, `trap`) |
| Quit before copying | 4 (Step 1) |
| `SMAppService` + menu toggle | 2 |
| Ad-hoc signing risk spike | 1 |
| `LaunchAgents` fallback | 1 (Step 5 decision — deliberately not pre-built) |
| `bundle.sh` version from tag | 3 |
| README hero as prepend | 5 |
| `gh` account mismatch | 6 (Step 1) |
| Branch lands before tag | 6 (Step 2) |
| Self-test check for login item | 2 (Step 1) |

**Type consistency:** `LoginItem.isAvailable` / `.isEnabled` / `.status` / `.setEnabled(_:)` are defined in Task 2 Step 3 and used identically in Task 2 Steps 1, 4, and 5. `Check(name:passed:detail:)` and `Check(name:skipped:)` match the existing initialisers in `SelfTest.swift:28` and `:34`.

**Known gap, deliberate:** the `LaunchAgents` fallback has no task. Writing it before the spike answers would be building the thing the spike exists to avoid, and the user may prefer dropping launch-at-login entirely over shipping the uglier version. Task 1 Step 5 stops and asks.
