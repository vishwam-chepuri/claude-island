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
