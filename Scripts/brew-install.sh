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
# Scripts/install.sh's install half, deliberately duplicated from it —
# install.sh must stay one standalone curl-pipeable file.

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

# Installed at <keg>/bin/claude-island-install and reached through brew's opt
# and bin symlinks — resolve back to the real keg, where the .app sits.
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
