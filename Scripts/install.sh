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

# A heredoc rather than extracting the header comment above: piped into bash
# ($0 is /bin/bash), reading "$0" for --help reads the bash executable
# itself, not this script.
usage() {
    cat <<'EOF'
One-line installer for ClaudeIsland.

  curl -fsSL https://raw.githubusercontent.com/vishwam-chepuri/claude-island/main/Scripts/install.sh | bash

It builds from source rather than downloading a binary, and that is the whole
point: there is no Developer ID to sign with, so a downloaded .app would
arrive quarantined and Sequoia removed the Control-click bypass. Code compiled
on the machine it runs on is never quarantined.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        --help|-h)
            usage
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
# either hangs or races the user. Goes through `run` so --dry-run doesn't
# actually pop the installer.
if ! xcode-select -p >/dev/null 2>&1; then
    say "Command Line Tools are required. Opening Apple's installer."
    run xcode-select --install || true
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
# A depth-1 clone carries no tag history, so bundle.sh's `git describe` would
# fall back to 0.0.0-dev even on a tagged main. Fetching tags is enough when
# the tag is the cloned commit itself; an untagged branch still falls back.
# Best-effort: a flaky network here would otherwise trade a working install
# for a cosmetic version string, which is backwards — 0.0.0-dev is fine.
run git -C "$TMP/src" fetch --quiet --tags --depth 1 origin || true

say "Building (this takes a minute)"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "    would: $TMP/src/Scripts/bundle.sh release"
else
    ( cd "$TMP/src" && ./Scripts/bundle.sh release >/dev/null )
fi

# --- Install ---------------------------------------------------------------

# Copying over a live bundle produces a half-replaced app. pgrep and pkill are
# a TOCTOU pair — if the process exits in between, pkill finds nothing and
# returns 1, which would otherwise abort the script here, after the clone and
# the multi-minute build, with no explanation.
if pgrep -x ClaudeIsland >/dev/null 2>&1; then
    say "Quitting the running copy"
    run pkill -x ClaudeIsland || true
    run sleep 1
fi

say "Installing to $DEST"
run rm -rf "$DEST/$APP_NAME"
run cp -R "$TMP/src/dist/$APP_NAME" "$DEST/"

APP="$DEST/$APP_NAME"
BIN="$APP/Contents/MacOS/ClaudeIsland"

# --- Hooks -----------------------------------------------------------------

# Piped into bash, stdin *is this script* — a prompt that reads stdin would
# consume its own source. /dev/tty reaches the user's terminal regardless,
# but /dev/tty is world-readable (crw-rw-rw-), so `[ -r /dev/tty ]` is true on
# every machine whether or not a terminal is attached — actually opening it is
# the only real test. An unanswerable prompt (no controlling terminal, or
# Ctrl-D at a live one) defaults to "no": --yes already covers unattended
# consent, so failing open here would only rewrite ~/.claude/settings.json
# with nobody having answered.
if [ "$ASSUME_YES" -eq 1 ]; then
    answer=y
elif { exec 3</dev/tty; } 2>/dev/null; then
    printf '==> Install Claude Code hooks into ~/.claude/settings.json? [Y/n] '
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

# --- Launch ----------------------------------------------------------------

say "Launching"
run open "$APP" || true

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete: nothing was installed."
else
    echo "Installed $APP"
    # Say what actually happened to the hooks, not what was hoped for — a
    # user told to "restart sessions to pick up the hooks" after a failed or
    # declined install would be looking for hooks that don't exist.
    case "$HOOKS_STATUS" in
        installed) echo "Restart any running Claude Code sessions to pick up the hooks." ;;
        failed)    echo "Hooks were not installed — run '$BIN --install-hooks' by hand." ;;
        skipped)   echo "Hooks were not installed. Run '$BIN --install-hooks' when you're ready." ;;
    esac
    echo "Enable 'Launch at Login' from the menu bar extra to keep it across reboots."
fi
