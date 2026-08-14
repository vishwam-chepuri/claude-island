# Switching off the walk back to the terminal

## The decision this rests on

`trackSessionApp` defaults to **`false`**. The feature ships off, and a settings
file that predates the key decodes as off, so **existing installs lose the
reveal row on upgrade and their frontmost-mute becomes less precise**. That is a
deliberate choice, not an oversight, and it is the second time that mute has
changed under people — the first is already apologised for in its own caption.

If the intent was the opposite reading — an opt-out flag named `disable…` that
defaults to `false` and therefore leaves the feature *on* — this is the one line
to change, and everything below follows from it unchanged.

## The problem

`docs/superpowers/specs/2026-08-13-reveal-terminal-design.md` shipped a control
that cannot be turned off. Three layers make that true, and all three have to
move:

- The row is **always rendered by design**. `expandedChromeHeight` is a constant
  that tallies `revealRowHeight + 5` into every card, so the card is sized as
  though the row exists whether or not it does. That is why a fourth label
  (`terminal unknown`) exists instead of a hidden state.
- The ancestry walk is **unconditional**. `claude-island-notify` takes no flag
  and reads no file that could stop it; `ancestorPIDs()` runs on every payload
  of every session.
- Settings has **no key for it**. The only mention of process ancestry in the UI
  is a caption under the mute toggle describing it as a mechanism.

Measured on the machine this was written on, the feature is also a no-op for its
primary user: both sessions resolve to the same VS Code process, and `open -b`
on an already-frontmost app exits 0 and moves nothing. A control that cannot
help and cannot be dismissed is worth being able to switch off.

## The design

### One setting, two consequences

`trackSessionApp: Bool`, default `false`, surfaced in **General** directly under
"Show the HUD" — a top-level behaviour switch rather than a diagnostic one,
because "I have no use for this" is a mainstream position.

Labelled **"Find the app each session is running in"**, naming the mechanism
rather than the button, because the button is only half of what it governs. Its
caption states both consequences and the file it rewrites.

### What "off" means in the app

The reveal row is not rendered, and the card shrinks by exactly its height.
`revealRowHeight + 5` moves out of the `expandedChromeHeight` constant and into
`expandedHeight` as a conditional block — the pattern `chipBlock` and
`taskBlock` already follow, and the comment on that constant already says
conditional blocks belong there.

`refreshOwners` is skipped, and `AppController.rings(_:under:frontmost:)` is
handed no owner, so the mute falls back to `TerminalApps.matches` — the rule
that predates the reveal work and still exists for sessions that resolve to
nothing. The Sounds caption gains a sentence when tracking is off, because it
currently promises a per-session exactness it would no longer deliver.

### What "off" means in the client

A `--no-ancestry` flag skips both `ancestorPIDs()` and the splice; the payload
is forwarded byte for byte, which is the same path a payload that does not start
with `{` already takes.

Argv, not a file and not a parse. The client's whole design is that it reads
stdin, connects, writes, exits — it links no Foundation and never becomes a JSON
parser. A sentinel file would cost a syscall on every tool call and would
reintroduce exactly what `IslandLog` records was deliberately replaced by
settings.json.

### Where the flag comes from

`HookInstaller.command(binaryPath:event:)` appends it when tracking is off.
Order is fixed — event flags first, then global ones, so `PermissionRequest`
reads `… --await-decision --no-ancestry` — because `isCurrent()` compares
command strings exactly and would otherwise report drift against itself.

### Keeping the two in step

Toggling rewrites the hook block immediately, **only when the installed hooks
are ours**. A hand-rolled or third-party hook is left alone.

The same reconciliation runs at launch: if the setting and the installed
commands disagree, the block is rewritten. Without it, every existing install
would flip to `false` on upgrade, find hooks that lack the flag, and sit in the
"Update Hooks" state until someone visited a pane they had no reason to visit.

A failed rewrite — permissions, a locked file — is surfaced, not swallowed.

### The safety net that makes the setting authoritative

**The app ignores `_island_pids` whenever the setting is off.**

This is what makes the flag an optimisation rather than the enforcement. Hooks
can be stale, hand-edited, or rewritten by another tool; the observable
behaviour still follows the setting the moment it changes. Without it, the
setting would be a request rather than a switch.

## Non-goals

- **Per-app or per-session granularity.** One toggle.
- **A separate privacy switch.** One toggle with two consequences, both stated.
- **Preserving the reveal row while stopping the capture.** That combination was
  considered and rejected: a row that can only ever say `terminal unknown` is
  worse than no row.

## Known edges

- Switching the setting while the card is open resizes the card. Accepted: the
  invariant that matters is that *browsing sessions* never resizes it, and a
  settings change is not browsing.
- Hooks that are not ours are never rewritten, so the walk continues for them.
  The app-side ignore still applies, so nothing is displayed or acted on.
- Replay fixtures carrying `_island_pids` decode as before and are ignored when
  the setting is off.

## Verification

Unit tests, in Core, through `swift run ClaudeIslandTests`:

- `HookInstaller.command` emits the flag when off and omits it when on;
  `isCurrent` detects both directions of drift; flag order is pinned.
- Settings decode: a file with no key yields `false`; a file with either value
  round-trips.
- `rings()` with tracking off falls back to `TerminalApps.matches` regardless of
  a resolvable owner.
- A payload carrying `_island_pids` resolves to no owner when tracking is off.
- The client forwards bytes unmodified under `--no-ancestry`, driven through the
  existing `--socket` seam.

`--selftest` gains the state it does not currently have. The two checks guarding
card sizing assume the row is always present; they become four — the card must
not resize while browsing sessions in **either** state, and the two states must
differ by exactly `revealRowHeight + 5`.

## Supporting changes

- `Sources/ClaudeIslandCore/IslandSettings.swift` — the key and its default.
- `Sources/ClaudeIslandCore/HookInstaller.swift` — flag emission and detection.
- `Sources/claude-island-notify/main.swift` — `--no-ancestry`.
- `Sources/ClaudeIslandApp/IslandViewModel.swift` — conditional height, skipped
  owner refresh, ignored ancestry.
- `Sources/ClaudeIslandApp/IslandContentViews.swift` — the row's absence.
- `Sources/ClaudeIslandApp/AppController.swift` — mute fallback.
- `Sources/ClaudeIslandApp/SettingsView.swift` — the toggle, its caption, and the
  amended Sounds caption.
- `Sources/ClaudeIslandApp/SettingsStore.swift` — rewrite on change, reconcile on
  launch.
- `Sources/ClaudeIslandApp/SelfTest.swift` — the four sizing checks.
- `README.md` — that the default is off, and what upgrading changes.
