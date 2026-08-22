# Homebrew Install Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `brew install vishwam-chepuri/tap/claude-island` + `claude-island-install` produces the same end state as `Scripts/install.sh`.

**Architecture:** A source-building formula in a new public tap. The formula builds via `Scripts/bundle.sh` (with two new env overrides), installs the .app into its keg plus a finish helper into bin; the helper does install.sh's quit/staged-swap/hooks dance into /Applications, which the sandboxed formula cannot.

**Tech Stack:** bash (macOS 3.2 — no 4.x-isms), Homebrew formula Ruby, SwiftPM via existing bundle.sh.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-22-homebrew-tap-design.md`.
- macOS 14 minimum (`depends_on macos: :sonoma`).
- `install.sh` is not modified.
- No co-author lines in commits. The tap checkout lives outside `~/personal projects`, so the gitconfig includeIf does NOT apply there — set local user.name/email in the tap repo before any commit, and never commit with the @chronus.com address.
- Env override names: `CLAUDE_ISLAND_VERSION`, `CLAUDE_ISLAND_SWIFT_FLAGS`. Helper command name: `claude-island-install`. First release tag: `v0.7.0`.
- One commit per task as it verifies.

---

### Task 1: bundle.sh env overrides

**Files:**
- Modify: `Scripts/bundle.sh` (build lines ~20-23, version lines ~44-46)

**Interfaces:**
- Produces: `CLAUDE_ISLAND_VERSION` (overrides `git describe`; already-stripped or `v`-prefixed both fine), `CLAUDE_ISLAND_SWIFT_FLAGS` (whitespace-split extra args to every `swift build`).

- [ ] **Step 1: Edit the build invocations**

Replace the two `swift build` lines and `--show-bin-path` line so all three carry the flags. bash 3.2 + `set -u` forbids expanding an empty array — use the `${arr[@]+...}` idiom:

```bash
# Extra `swift build` flags for environments that need them. Homebrew is the
# motivating case: SwiftPM's own sandbox-exec cannot nest inside Homebrew's
# build sandbox, so its formula passes --disable-sandbox through here.
# Deliberately word-split; these flags never contain spaces.
read -r -a SWIFT_FLAGS <<< "${CLAUDE_ISLAND_SWIFT_FLAGS:-}"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product ClaudeIslandApp
swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product claude-island-notify

BIN_DIR="$(swift build -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"
```

- [ ] **Step 2: Edit the version stamping**

```bash
# The tag is the version. CLAUDE_ISLAND_VERSION overrides for builds outside a
# git checkout — a release tarball has no .git, so `git describe` would claim
# 0.0.0-dev for code that is exactly a release. BUILD falls back the same way.
VERSION="${CLAUDE_ISLAND_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0-dev")}"
VERSION="${VERSION#v}"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo "${CLAUDE_ISLAND_VERSION:-dev}")"
```

- [ ] **Step 3: Verify default behavior unchanged**

Run: `./Scripts/bundle.sh release && defaults read "$PWD/dist/ClaudeIsland.app/Contents/Info.plist" CFBundleShortVersionString`
Expected: `0.6.0` (the tag), build succeeds as before.

- [ ] **Step 4: Verify the overrides**

Run: `CLAUDE_ISLAND_VERSION=9.9.9 CLAUDE_ISLAND_SWIFT_FLAGS=--disable-sandbox ./Scripts/bundle.sh release && defaults read "$PWD/dist/ClaudeIsland.app/Contents/Info.plist" CFBundleShortVersionString`
Expected: builds (flag accepted) and prints `9.9.9`. Also run `bash -n Scripts/bundle.sh`.

- [ ] **Step 5: Rebuild clean and commit**

Run `./Scripts/bundle.sh release` once more so dist/ isn't left stamped 9.9.9, then:
```bash
git add Scripts/bundle.sh && git commit -m "Let bundle.sh take its version and build flags from the environment"
```

### Task 2: Scripts/brew-install.sh

**Files:**
- Create: `Scripts/brew-install.sh` (mode 755)

**Interfaces:**
- Consumes: keg layout `<keg>/ClaudeIsland.app` + `<keg>/bin/claude-island-install` (Task 3 installs it that way); app flags `--install-hooks`, `--uninstall-hooks`.
- Produces: `claude-island-install [--dry-run] [-y|--yes] [--uninstall] [-h|--help]`.

- [ ] **Step 1: Write the script**

Full content (install.sh's install half, adapted; the duplication is deliberate — install.sh must stay one standalone curl-pipeable file):

```bash
#!/bin/bash
# claude-island-install — the finish step for a Homebrew install.
#
#   brew install vishwam-chepuri/tap/claude-island && claude-island-install
#
# The formula builds ClaudeIsland.app into its keg, but Homebrew sandboxes
# post_install away from /Applications — and the app must live at a stable
# path: --install-hooks bakes the absolute binary path into
# ~/.claude/settings.json, and Launch at login registers the running bundle's
# real path. A versioned keg path dies on every upgrade; /Applications does
# not. So this script, installed into brew's bin by the formula, does the copy
# the formula cannot: the same quit / staged-swap / hooks-offer dance as
# Scripts/install.sh's install half, deliberately duplicated from it.

set -euo pipefail

APP_NAME="ClaudeIsland.app"
DRY_RUN=0
ASSUME_YES=0
UNINSTALL=0

usage() {
    cat <<'EOF'
claude-island-install — copy the Homebrew-built ClaudeIsland.app into
/Applications (falling back to ~/Applications) and offer to wire the Claude
Code hooks. Re-run after every `brew upgrade claude-island`.

OPTIONS
  --dry-run      Print what would happen without doing any of it.
  -y, --yes      Skip the hooks confirmation prompt and answer yes.
  --uninstall    Quit the app, remove its hooks, delete the installed copy.
                 Follow with `brew uninstall claude-island`.
  -h, --help     Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --help|-h)   usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { echo "==> $*"; }
run() { if [ "$DRY_RUN" -eq 1 ]; then echo "    would: $*"; else "$@"; fi; }
die() { echo "error: $*" >&2; exit 1; }

# Installed at <keg>/bin/claude-island-install and reached through brew's
# opt and bin symlinks — resolve back to the real keg, where the .app sits.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
KEG="$(cd "$(dirname "$SELF")/.." && pwd)"
APP_SRC="$KEG/$APP_NAME"

# Copying over a live bundle produces a half-replaced app. pgrep and pkill are
# a TOCTOU pair — if the process exits in between, pkill finds nothing and
# returns 1, which must not abort the script.
quit_running_copy() {
    if pgrep -x ClaudeIsland >/dev/null 2>&1; then
        say "Quitting the running copy"
        run pkill -x ClaudeIsland || true
        # pkill returns when the signal is sent, not when the process is gone.
        # Poll, bounded, rather than sleep a fixed amount and lose the race.
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "    would: wait for the running copy to quit"
        else
            for _ in $(seq 1 20); do
                pgrep -x ClaudeIsland >/dev/null 2>&1 || break
                sleep 0.25
            done
            if pgrep -x ClaudeIsland >/dev/null 2>&1; then
                say "Still running after 5s — continuing anyway."
            fi
        fi
    fi
}

# --- Uninstall ---------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
    INSTALLED=""
    for d in /Applications "$HOME/Applications"; do
        if [ -d "$d/$APP_NAME" ]; then INSTALLED="$d/$APP_NAME"; break; fi
    done
    quit_running_copy
    # Hooks first, and from whichever binary still exists — removing entries
    # only needs the marker, not a live install.
    HOOK_BIN="$APP_SRC/Contents/MacOS/ClaudeIsland"
    [ -n "$INSTALLED" ] && HOOK_BIN="$INSTALLED/Contents/MacOS/ClaudeIsland"
    if [ -x "$HOOK_BIN" ]; then
        say "Removing hooks"
        run "$HOOK_BIN" --uninstall-hooks \
            || say "Hook removal failed — check ~/.claude/settings.json by hand."
    fi
    if [ -n "$INSTALLED" ]; then
        say "Removing $INSTALLED"
        run rm -rf "$INSTALLED"
    else
        say "No installed copy found in /Applications or ~/Applications."
    fi
    echo ""
    echo "Now remove the Homebrew keg too:  brew uninstall claude-island"
    exit 0
fi

# --- Install -----------------------------------------------------------------

[ -d "$APP_SRC" ] || die "no $APP_NAME at $APP_SRC — reinstall with: brew reinstall claude-island"

# /Applications is writable by admin users; fall back rather than ask for sudo.
if [ -w /Applications ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
    run mkdir -p "$DEST"
fi

# Staged rather than in place: rm-then-cp has a window where a failed copy or
# a Ctrl-C leaves neither a working old install nor a working new one. Copy to
# a staging path first; the final swap is a rename, which cannot partially
# apply. The trap removes a half-written staging copy on any exit.
STAGING="$DEST/.$APP_NAME.new"
[ "$DRY_RUN" -eq 1 ] || trap 'rm -rf "$STAGING"' EXIT

quit_running_copy

say "Installing to $DEST"
run rm -rf "$STAGING"
run cp -R "$APP_SRC" "$STAGING"
run rm -rf "$DEST/$APP_NAME"
run mv "$STAGING" "$DEST/$APP_NAME"

APP="$DEST/$APP_NAME"
BIN="$APP/Contents/MacOS/ClaudeIsland"

# --- Hooks -------------------------------------------------------------------

# Same /dev/tty reasoning as install.sh: opening it is the only real test for
# an attached terminal, and an unanswerable prompt defaults to "no" — --yes
# already covers unattended consent, so failing open would rewrite
# ~/.claude/settings.json (and possibly the status-line script) with nobody
# having answered.
if [ "$ASSUME_YES" -eq 1 ]; then
    answer=y
elif { exec 3</dev/tty; } 2>/dev/null; then
    printf '==> Install Claude Code hooks into ~/.claude/settings.json (and your status-line script, if one is configured)? [Y/n] '
    if read -r answer <&3; then answer="${answer:-y}"; else answer=n; fi
    exec 3<&-
else
    answer=n
fi

case "$answer" in
    [Yy]*)
        say "Installing hooks"
        if run "$BIN" --install-hooks; then
            HOOKS_STATUS=installed
        else
            HOOKS_STATUS=failed
            say "Hook install failed — run '$BIN --install-hooks' by hand."
        fi
        ;;
    *)
        HOOKS_STATUS=skipped
        say "Skipped. Run '$BIN --install-hooks' when you're ready."
        ;;
esac

# --- Launch ------------------------------------------------------------------

say "Launching"
run open "$APP" || true

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete: nothing was installed."
else
    echo "Installed $APP"
    case "$HOOKS_STATUS" in
        installed) echo "Restart any running Claude Code sessions to pick up the hooks." ;;
        failed)    echo "Hooks were not installed — run '$BIN --install-hooks' by hand." ;;
        skipped)   echo "Hooks were not installed. Run '$BIN --install-hooks' when you're ready." ;;
    esac
    echo "Re-run claude-island-install after every 'brew upgrade claude-island'."
fi
```

- [ ] **Step 2: Syntax + help + guard checks (no keg yet, so failure paths)**

```bash
bash -n Scripts/brew-install.sh
chmod +x Scripts/brew-install.sh
Scripts/brew-install.sh --help                 # usage, exit 0
Scripts/brew-install.sh --bogus; echo "rc=$?"  # unknown option, rc=2
Scripts/brew-install.sh --dry-run; echo "rc=$?" # dies: no ClaudeIsland.app next to Scripts/ — expected until it runs from a keg
```
Expected: the last one exits 1 with the `no ClaudeIsland.app at …` message (Scripts/ has no sibling app). Real-path behavior is exercised in Task 4 from an actual keg.

- [ ] **Step 3: Simulate a keg layout to test both flows' dry-runs**

```bash
mkdir -p tmp/fake-keg/bin && cp Scripts/brew-install.sh tmp/fake-keg/bin/claude-island-install
cp -R dist/ClaudeIsland.app tmp/fake-keg/
tmp/fake-keg/bin/claude-island-install --dry-run
tmp/fake-keg/bin/claude-island-install --dry-run --uninstall
```
Expected: install dry-run prints the would-quit/copy/swap/launch lines targeting /Applications and "Dry run complete"; uninstall dry-run finds `/Applications/ClaudeIsland.app`, prints would-remove lines and the `brew uninstall` reminder. Nothing on disk changes (check: `ls /Applications | grep -i claudeisland` still shows the app; running copy still alive via `pgrep -x ClaudeIsland`).

- [ ] **Step 4: Commit**

```bash
git add Scripts/brew-install.sh && git commit -m "Add the finish step a Homebrew install runs"
```

### Task 3: README Homebrew section

**Files:**
- Modify: `README.md` (inside `## Install`, after the `### 1. Run the installer` block ends at the `-s --` note, before `### 2.`)

- [ ] **Step 1: Insert the section** (match the README's explanatory voice):

```markdown
### Or: Homebrew

```bash
brew install vishwam-chepuri/tap/claude-island
claude-island-install
```

Two commands rather than one, because Homebrew sandboxes builds away from
`/Applications`: `brew install` compiles the app from source — same reasoning
as the installer, locally built code is never quarantined — and
`claude-island-install` finishes what the sandbox can't, swapping the app into
`/Applications` and making the same hooks offer as step 2 below. Re-run it
after every `brew upgrade claude-island`; skipping that leaves the previous
version installed and working, just stale.

To remove everything:

```bash
claude-island-install --uninstall && brew uninstall claude-island
```
```

- [ ] **Step 2: Verify and commit**

Skim the rendered section for fence balance (nested fences: use 4-backtick outer or adjust), then:
```bash
git add README.md && git commit -m "Offer Homebrew as a second install path"
```

### Task 4: Formula, iterated locally against a file:// tarball

**Files:**
- Create (outside this repo): `$(brew --repository vishwam-chepuri/tap)/Formula/claude-island.rb`

**Interfaces:**
- Consumes: `Scripts/bundle.sh release` honoring both env vars (Task 1); `Scripts/brew-install.sh` (Task 2); tarball unpacking to `claude-island-0.7.0/`.
- Produces: keg `<keg>/ClaudeIsland.app` + `bin/claude-island-install` — exactly what Task 2's script expects.

- [ ] **Step 1: Create the local tap and identity-guard it**

```bash
brew tap-new vishwam-chepuri/tap --no-git
TAP="$(brew --repository vishwam-chepuri/tap)"
git -C "$TAP" init 2>/dev/null || true   # tap-new --no-git leaves no repo; we want one eventually
git -C "$TAP" config user.name "Vishwam Chepuri"
git -C "$TAP" config user.email "42149544+vishwam-chepuri@users.noreply.github.com"
rm -rf "$TAP/.github"                     # bottling workflows; source-only tap doesn't want them
```

- [ ] **Step 2: Build a test tarball matching GitHub's layout**

```bash
cd "/Users/vishwam/personal projects/claude dynamic island"
git archive --format=tar.gz --prefix=claude-island-0.7.0/ -o tmp/claude-island-0.7.0.tar.gz HEAD
shasum -a 256 tmp/claude-island-0.7.0.tar.gz
```

- [ ] **Step 3: Write the formula** at `$TAP/Formula/claude-island.rb`, first with the file:// url:

```ruby
class ClaudeIsland < Formula
  desc "Dynamic Island-style HUD for Claude Code sessions"
  homepage "https://github.com/vishwam-chepuri/claude-island"
  url "file:///Users/vishwam/personal projects/claude dynamic island/tmp/claude-island-0.7.0.tar.gz"
  version "0.7.0"
  sha256 "SHA_FROM_STEP_2"
  license "Apache-2.0"

  depends_on macos: :sonoma

  def install
    # A tag tarball has no .git for `git describe`, and SwiftPM's own sandbox
    # cannot nest inside Homebrew's build sandbox.
    ENV["CLAUDE_ISLAND_VERSION"] = version.to_s
    ENV["CLAUDE_ISLAND_SWIFT_FLAGS"] = "--disable-sandbox"
    system "./Scripts/bundle.sh", "release"
    prefix.install "dist/ClaudeIsland.app"
    bin.install "Scripts/brew-install.sh" => "claude-island-install"
  end

  def caveats
    <<~EOS
      The app is built but not yet installed. Finish with:

        claude-island-install

      It copies ClaudeIsland.app into /Applications and offers to wire up the
      Claude Code hooks. Re-run it after every `brew upgrade claude-island`.

      To remove everything:
        claude-island-install --uninstall && brew uninstall claude-island
    EOS
  end

  test do
    assert_match "ClaudeIsland", shell_output("#{prefix}/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --help")
  end
end
```

- [ ] **Step 4: Install from the local tap and verify the keg**

```bash
brew install --build-from-source --verbose vishwam-chepuri/tap/claude-island
OPT="$(brew --prefix)/opt/claude-island"
ls "$OPT"                                                    # ClaudeIsland.app, bin
"$OPT/ClaudeIsland.app/Contents/MacOS/ClaudeIsland" --help   # usage text, exit 0
defaults read "$OPT/ClaudeIsland.app/Contents/Info.plist" CFBundleShortVersionString  # 0.7.0
codesign --verify --verbose=1 "$OPT/ClaudeIsland.app"        # valid ad-hoc signature
claude-island-install --dry-run                              # resolves keg, prints would-lines
brew test claude-island
brew style vishwam-chepuri/tap
```
Iterate on failures (likely suspects: SwiftPM sandbox/caches under superenv, codesign in sandbox). Fixes that touch repo scripts get amended into their task's commit before the tag in Task 5.

- [ ] **Step 5: One real finish run — this swaps the live installed app, which is the point**

The Bash tool has no tty, so the hooks prompt auto-answers "no" and the existing hooks (already pointing at the identical /Applications path) keep working untouched.

```bash
claude-island-install
pgrep -x ClaudeIsland                          # relaunched
defaults read /Applications/ClaudeIsland.app/Contents/Info.plist CFBundleShortVersionString  # 0.7.0
ls /Applications | grep .ClaudeIsland.app.new  # no staging leftover (expect no match)
```

- [ ] **Step 6: Uninstall dry-run against the real install** (no state change):

```bash
claude-island-install --uninstall --dry-run
```
Expected: finds /Applications copy, would-remove lines only; `pgrep -x ClaudeIsland` still alive afterwards? No — dry-run must not kill it: verify the quit is also printed as would-only.

### Task 5: Push main and tag v0.7.0

**Files:** none (git state only).

- [ ] **Step 1: Confirm main is clean and ahead only by this work**

```bash
git status --short && git log --oneline origin/main..main
```

- [ ] **Step 2: Push and tag** (a tag on the pushed tip is what stops installs saying 0.0.0-dev, and the formula builds exactly what the tag contains):

```bash
git push origin main
git tag v0.7.0
git push origin v0.7.0
```

### Task 6: Publish the tap and verify end to end

**Files:**
- Modify: `$TAP/Formula/claude-island.rb` (real url + sha256, drop `version` line)
- Create: `$TAP/README.md`

- [ ] **Step 1: Point the formula at the real tarball**

```bash
curl -fsSL https://github.com/vishwam-chepuri/claude-island/archive/refs/tags/v0.7.0.tar.gz -o tmp/v0.7.0.tar.gz
shasum -a 256 tmp/v0.7.0.tar.gz
```
In the formula: `url "https://github.com/vishwam-chepuri/claude-island/archive/refs/tags/v0.7.0.tar.gz"`, new sha256, delete the `version "0.7.0"` line (inferred from the tag url).

- [ ] **Step 2: Write `$TAP/README.md`**

```markdown
# homebrew-tap

Personal tap. Currently one formula:
[claude-island](https://github.com/vishwam-chepuri/claude-island), a Dynamic
Island-style HUD for Claude Code sessions.

## Install

```bash
brew install vishwam-chepuri/tap/claude-island
claude-island-install
```

Built from source on your machine (there is no Developer ID to sign with, and
locally compiled code is never quarantined). `claude-island-install` finishes
the install into /Applications — re-run it after every upgrade.

## Cutting a release (maintainer notes)

1. In claude-island: `git tag vX.Y.Z && git push origin main vX.Y.Z`
2. Here: bump the tag in `Formula/claude-island.rb`'s `url`, refresh `sha256`
   (`curl -fsSL <tarball-url> | shasum -a 256`), commit, push.
```

- [ ] **Step 3: Reinstall from the real tarball and audit**

```bash
brew reinstall --build-from-source vishwam-chepuri/tap/claude-island
brew audit --strict --online vishwam-chepuri/tap/claude-island
claude-island-install --dry-run
```

- [ ] **Step 4: Commit the tap and publish**

```bash
cd "$(brew --repository vishwam-chepuri/tap)"
git add -A && git commit -m "Add the claude-island formula"
gh repo create vishwam-chepuri/homebrew-tap --public --description "Homebrew tap for claude-island" --source . --push
```
If `gh repo create` cannot create under vishwam-chepuri, stop and surface it rather than creating under another account.

- [ ] **Step 5: True end-to-end from GitHub**

```bash
brew uninstall claude-island && brew untap vishwam-chepuri/tap
brew install vishwam-chepuri/tap/claude-island     # now fetched from GitHub
claude-island-install                              # final real run
"$(brew --prefix)/opt/claude-island/ClaudeIsland.app/Contents/MacOS/ClaudeIsland" --help
defaults read /Applications/ClaudeIsland.app/Contents/Info.plist CFBundleShortVersionString  # 0.7.0
pgrep -x ClaudeIsland
```

- [ ] **Step 6: Clean up test artifacts**

```bash
rm -f tmp/claude-island-0.7.0.tar.gz tmp/v0.7.0.tar.gz && rm -rf tmp/fake-keg
```
Commit the plan checkbox updates if any doc changes accrued.
