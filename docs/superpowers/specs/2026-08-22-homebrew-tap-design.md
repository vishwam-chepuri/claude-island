# Homebrew install channel

Approved 2026-08-22. Make ClaudeIsland installable with:

```bash
brew install vishwam-chepuri/tap/claude-island
claude-island-install
```

## Constraints that shaped the design

- **No Developer ID.** A downloaded .app arrives quarantined and Sequoia removed
  the Control-click bypass, so a prebuilt cask would wall every first launch
  behind System Settings → Open Anyway. The formula therefore builds from
  source, exactly like `Scripts/install.sh` — locally compiled code is never
  quarantined.
- **Absolute paths are load-bearing.** `--install-hooks` bakes the path of
  `claude-island-notify` into `~/.claude/settings.json` (symlinks resolved),
  and Launch at login registers the running bundle's real path via
  `SMAppService.mainApp`. A keg-only install would break both on every
  `brew upgrade` when the versioned keg path dies, so the app must end up
  physically in `/Applications`. Homebrew sandboxes `post_install`, so the
  formula cannot write there itself — a user-run finish command does it.
- **Tag tarballs have no `.git`.** `bundle.sh`'s `git describe` would stamp
  `0.0.0-dev`; the formula passes the version in.
- **SwiftPM sandboxes its own manifest compile.** Nested inside Homebrew's
  build sandbox that fails, so the formula must pass `--disable-sandbox` to
  `swift build` (standard practice for Swift formulae).

## Changes in this repo

1. `Scripts/bundle.sh` — honor `CLAUDE_ISLAND_VERSION` (overrides
   `git describe`) and `CLAUDE_ISLAND_SWIFT_FLAGS` (extra `swift build`
   arguments). No behavior change when unset.
2. `Scripts/brew-install.sh` (new) — installed by the formula as
   `bin/claude-island-install`. Locates `ClaudeIsland.app` relative to its own
   resolved keg path, then reuses install.sh's install half: quit the running
   copy with a bounded poll, staged copy + rename swap into `/Applications`
   (falling back to `~/Applications`), offer `--install-hooks` over `/dev/tty`
   (with `-y` and `--dry-run` flags), launch. Adds `--uninstall`: quit,
   `--uninstall-hooks`, remove the installed app. `install.sh` stays untouched —
   it must remain one standalone curl-pipeable file, so the shared ~50 lines
   are deliberately duplicated.
3. `README.md` — a Homebrew subsection in Install, alongside the curl
   one-liner: the two commands, the re-run-after-upgrade note, and
   `claude-island-install --uninstall && brew uninstall claude-island`.

## New repo: `vishwam-chepuri/homebrew-tap`

- `Formula/claude-island.rb` — `url` is the release tag tarball (first:
  `v0.7.0`, cut after these changes land, since the formula builds whatever
  the tag contains), `sha256`, `depends_on macos: :sonoma`, build via
  `Scripts/bundle.sh release` with the env overrides,
  `prefix.install "dist/ClaudeIsland.app"`, `bin.install` the helper as
  `claude-island-install`, caveats naming the finish command, and a `test do`
  running the app binary's `--help`.
- `README.md` — install instructions and the per-release bump procedure
  (update the tag in `url`, refresh `sha256`).

Each release now has one extra step: bump the formula in the tap.

## Upgrade and failure behavior

- `brew upgrade` rebuilds the new tag; caveats reprint the finish command. A
  user who forgets keeps a working older `/Applications` copy — stale, not
  broken, because its hooks still point at `/Applications`.
- The keg keeps its own copy of the .app. `/Applications` wins `open -a`
  resolution in practice, and the README already tells users to launch by
  path; accepted, documented risk.

## Verification

Iterate locally before anything is published: `git archive` tarball via a
`file://` url, `brew install --build-from-source`, `claude-island-install
--dry-run`, then one real run (equivalent to a normal reinstall of the
installed app). Only then: push main, tag `v0.7.0`, create the tap repo, point
the formula at the real tarball, and verify the true one-liner end to end.

## Rejected alternatives

- **Prebuilt cask** — Gatekeeper wall (above), plus per-release artifact
  builds. Revisit only with a Developer ID + notarization.
- **Keg-only formula** — breaks hooks and Launch at login on every upgrade.
- **homebrew-core** — notability thresholds aside, core policy pushes GUI
  apps to casks, which circles back to signing.
- **Formula inside this repo** — saves a repo but costs every user an extra
  explicit-URL `brew tap` command; the standard `user/tap/name` one-liner wins.
