# Getting it onto other people's machines

## The problem

The app builds, runs, and is already public under Apache 2.0 at
`github.com/vishwam-chepuri/claude-island`. Nobody can practically install it.
There is no release, no install path shorter than "clone the repo and read the
architecture section first", and the app dies on reboot.

Underneath that sits one hard constraint.

**There is no code-signing identity.** `security find-identity -v -p codesigning`
reports zero. `bundle.sh` ad-hoc signs, which is all Command Line Tools can do
without a Developer ID. So any `.app` a user *downloads* arrives quarantined,
and since Sequoia the Control-click→Open escape hatch is gone — the user has to
walk into System Settings → Privacy & Security → Open Anyway. On an app whose
first action is editing `~/.claude/settings.json`, that dialog reads exactly
like the thing you should refuse.

Notarization would remove it. Notarization needs the $99/yr Apple Developer
Program, and paying before knowing whether anyone wants this is the wrong order.
Both `notarytool` and `stapler` are already present in Command Line Tools, so
the day that decision flips, the pipeline is a certificate and about thirty
lines — no Xcode. That is a later document.

**Code compiled locally is never quarantined.** That is the whole design. The
goal is not to ship a binary; it is to make building from source feel like
installing.

## The design

### One line

```
curl -fsSL https://raw.githubusercontent.com/vishwam-chepuri/claude-island/main/Scripts/install.sh | bash
```

`Scripts/install.sh` lives in the repo, so the thing being piped into a shell is
readable at the URL being piped from, and reviewable by running it with
`--dry-run`.

Seven steps:

1. **macOS ≥ 14**, matching `LSMinimumSystemVersion`. Refuse below it rather
   than fail obscurely inside `swift build`.
2. **Command Line Tools.** If `xcode-select -p` fails, fire `xcode-select
   --install` and *exit with instructions*. That installer is an asynchronous
   GUI; a script that waits on it either hangs or races.
3. **Clone to a temp dir.** Not a permanent one. A repo left in a surprise
   location is state that goes stale and that nobody knows to delete. Updates
   are re-running this line, so there is nothing to keep.
4. **Build via `Scripts/bundle.sh`.** One code path for both source and script
   installs; the script must not grow its own copy of the bundle layout.
5. **Quit any running instance, then copy to `/Applications`.** Copying over a
   live bundle produces a half-replaced app.
6. **Offer `--install-hooks`.** Already idempotent, already backs up first.
7. **Launch, and delete the temp dir.**

Two details that decide whether this works at all:

**The prompt cannot read stdin.** Piped into `bash`, stdin *is the script*. A
`[Y/n]` that reads stdin consumes its own source and behaves unpredictably. The
hook prompt reads from `/dev/tty`, and `--yes` skips it for non-interactive use.
This is the most common way one-liners break and it is invisible until piped.

**`--dry-run` prints the plan and touches nothing.** It is how a cautious user
audits a `curl | bash` without reading shell.

Building locally also disposes of the architecture question. `bundle.sh`
currently produces arm64 because that is what this machine is; an Intel Mac
running Sonoma compiles x86_64 on its own. No universal binary, no lipo, no
decision.

### Surviving a reboot

An always-on HUD that vanishes on restart is indistinguishable from one that
broke. `SMAppService.mainApp.register()` — macOS 13+, below the app's own floor,
no plist, no dependency, and it appears correctly in System Settings → General →
Login Items. A **Launch at Login** item joins the menu bar extra beside Show
Debug Tint, persisted the same way the existing toggles are.

**This carries the one real risk in this document.** `SMAppService` is stricter
about code signatures than the API it replaced, and every install here is
ad-hoc signed by construction. Whether it accepts an ad-hoc bundle must be
settled by a throwaway spike *before* any of the toggle is built.

If it refuses, the fallback is a `~/Library/LaunchAgents` plist written by
`install.sh`. That works with any signature, and it is worse: the control moves
out of the app into a file, and turning it off means editing or deleting the
plist rather than clicking a menu item. Take it only if the spike fails.

### Supporting changes

**`bundle.sh` version.** `VERSION` is hardcoded `0.1.0`. It becomes `git
describe --tags --abbrev=0`, falling back to `0.0.0-dev` outside a tagged
checkout. `CFBundleVersion` keeps the short SHA it already uses.

**README.** The current one is a good engineering document and a bad landing
page — it opens with build instructions and reaches architecture by line 40. It
gains a hero section: what it is, the screenshot, the one-liner, requirements.
Everything below stays as written. This is a prepend, not a rewrite.

## Non-goals

Each of these is a separate, later, independent piece. Naming them is how they
stay out of this one.

- **Notarization, Developer ID, `.dmg`.** Deferred until traction justifies $99.
- **Homebrew.** A cask ships prebuilts, which is the quarantine path again. A
  formula builds from source but has no `app` stanza, so `/Applications`
  placement is manual. Worth revisiting *after* notarization, when a cask
  becomes clean.
- **Auto-update.** The app makes no network calls, and that claim is worth more
  to a tool that reads your transcripts than automatic updates are. Updating is
  re-running the one-liner — a fetch the user initiates, not one the app makes.
- **Claude Code plugin distribution.** The best-targeted discovery channel that
  exists for this app, and unverified. Its own document.
- **The launch itself** — demo GIF, Show HN, r/ClaudeAI.

## Release mechanics

**The `gh` CLI is authenticated as `Vishwam10`. The repository belongs to
`vishwam-chepuri`.** Per the tree's CLAUDE.md, which account owns a `gh` write
must be settled explicitly before any of them. This blocks `gh release create`
and nothing else, so it can be resolved at the end — but it must be resolved,
not discovered.

Sequencing: `permission-decisions-from-the-island` merges or is set aside first.
It carries three commits that are not on `main`, and `v0.1.0` should describe
what ships rather than what happened to be merged that afternoon. Then the tag
on `main`, which `bundle.sh` now reads.

## Verification

The project's rule is that anything unit tests cannot reach goes in `--selftest`.
This follows it.

| What | How |
|---|---|
| `install.sh` plan | `--dry-run`, read the output |
| `install.sh` for real | Full run; app in `/Applications`, hooks merged, temp dir gone |
| CLT-missing path | Force the branch; confirm it exits with instructions, does not hang |
| Piped-stdin prompt | Actually `curl \| bash` it — this cannot be tested any other way |
| Launch at login | New `--selftest` check: register, read `SMAppService.status` back, expect `.enabled` |
| Hook installation | Already covered by `HookInstallerTests` |

The self-test check is the one that matters long-term: registration silently
failing is exactly the failure this feature exists to prevent, and it would
otherwise only surface on someone else's reboot.
