# Getting you back to the session that needs you

## The problem

The HUD's whole job is answering "which of my sessions needs me?" — and then it
stops one step short. It names the session, colours it amber, holds the prompt
open, and leaves you to find the window yourself. With four sessions in three
repos across two Spaces, that last step is the expensive one, and it is the one
the app currently does nothing about.

The gap is already documented in the codebase, as an apology. `TerminalApps.swift`
exists solely to decide whether to skip a chime, and its header explains why it
cannot do more:

> macOS can say which app is frontmost. Nothing says which app a given session
> belongs to: the hook client posts a session id, a cwd and a transcript path,
> not a terminal window, and there is no supported way back from a process to
> the window it was launched in.

That is true of the *payload*. It is not true of the *process*. The hook client
runs as a descendant of the terminal that launched the session, and process
ancestry is readable. Closing this gap therefore fixes two things with one pipe:
it adds the jump, and it upgrades the mute heuristic from "*a* terminal is in
front" to "*this session's* terminal is in front", which is the caveat that
whole file apologises for.

## What was measured first

Three findings from a spike, because two of them invalidate the obvious design.

**The pid walk works.** From a live `claude` process the chain is
`claude → zsh → Code Helper → Visual Studio Code`: four hops to an app that
`NSRunningApplication(processIdentifier:)` resolves directly. `Code Helper` is
*not* in `NSWorkspace.runningApplications` as a regular app, so walking to the
first ancestor with `activationPolicy == .regular` skips helper processes and
lands on the bundle root without needing to recognise the app by name. That
matters: it works for terminals nobody has added to a hardcoded list.

**Not every session has a terminal.** The same machine was running both kinds at
once — four interactive sessions on ttys, and a `claude daemon run` host with
parent pid 1 and no controlling tty, spawning background jobs. Those have no
terminal ancestor and never will. The feature needs an honest answer for them,
not a silent no-op.

**Three activation APIs return success and do nothing.** This is the expensive
one. From an accessory app that is not itself frontmost, targeting a running app:

| Call | Result |
|---|---|
| `NSRunningApplication.activate()` | returns `true`, frontmost unchanged |
| `NSRunningApplication.activate(from:options:)` | frontmost unchanged |
| `NSWorkspace.openApplication(at:configuration:)` with `activates = true` | completes with no error, frontmost unchanged |
| `/usr/bin/open -b <bundleID>` | **activates** |

macOS 14's cooperative activation rules stop a background app from raising
another app in-process, and the API reports success anyway. Spawning `open` —
a trusted LaunchServices helper — is honoured. It also needs no TCC prompt of
any kind, which preserves the app's current property of requiring **no
permissions at all**.

A fourth check: raising an app that already has windows does not create another
one (VS Code held at four windows across the call). An app with *zero* open
windows may well gain one; see non-goals.

## The design

### Capturing the ancestry

`claude-island-notify` walks `getppid()` upward via
`sysctl(KERN_PROC, KERN_PROC_PID, …)` → `kinfo_proc.kp_eproc.e_ppid`, capped at
8 hops and stopping at pid 1. That is at most 8 syscalls of a few microseconds
each, against a 2.49 ms median budget. It stays `Darwin`-only — no Foundation,
which is the constraint that keeps this binary fast enough to run on every tool
call.

The pids reach the HUD by **splicing bytes into the payload, not parsing it**.
The client's most important property is that it forwards the hook payload
verbatim and never becomes a JSON parser. So it finds the leading `{` and
rewrites it as `{"_island_pids":[…],`, leaving every other byte untouched. Cost
is roughly 40–80 bytes. Existing decoders ignore the unknown field, and the
replay fixtures stay valid JSON.

Two edges that must be tested, because both produce corrupt output if missed:

- **An empty object.** `{}` spliced naively becomes `{"_island_pids":[…],}` —
  a trailing comma, and invalid JSON. When the next non-whitespace byte after
  `{` is `}`, the comma must be omitted.
- **A payload that does not start with `{`.** Send it verbatim, unmodified. The
  client must never be able to corrupt a payload it did not understand;
  degrading to "no ancestry" is free, and a mangled payload is not.

### Resolving the owner

Split for testability, following the precedent `AppController.rings(_:under:frontmost:)`
already sets by taking the frontmost bundle id as a parameter rather than
reading `NSWorkspace` itself.

The pure walk lives in Core and takes an injectable lookup:

```
OwnerResolution.first(in: [Int32], lookup: (Int32) -> AppInfo?) -> AppInfo?
```

returning the first ancestor whose lookup yields `activationPolicy == .regular`.
The AppKit binding in `Sources/ClaudeIslandApp/SessionOwner.swift` supplies
`NSRunningApplication(processIdentifier:)`. Core stays AppKit-free, and the
walk is unit-testable with no window server.

Resolution happens **at click time, not at capture time**. Pids go stale when a
terminal quits; resolving late means a dead pid simply fails to resolve and the
button disables itself. The ancestry is also re-stamped on every hook event, so
a resumed session self-heals without any explicit invalidation.

One ordering trap: **only overwrite a session's ancestry when an envelope
actually carries it.** Status-line payloads interleave with hook payloads for
the same session and carry no pids; treating absent as empty would wipe a good
ancestry several times a second.

### The button

It lives in the expanded card's detail pane. Row click keeps selecting, so
browsing sessions still works and there is no gesture that yanks you to another
app by accident.

It reads **`Reveal in Visual Studio Code`** — naming the destination rather than
saying "Reveal", because the useful information is *where you are about to be
sent*, and at app-level granularity that name is the whole promise being made.

Clicking it dismisses the expanded card. A card left floating over the app you
just jumped to is in the way, with the thing you wanted to look at underneath it.

Four states, distinguished with no extra data by asking which ancestors are
still alive:

| Condition | Label |
|---|---|
| An ancestor resolves to a `.regular` app | `Reveal in <App>`, enabled |
| Some ancestors alive, none `.regular` | `Background job — no terminal`, disabled |
| No ancestor alive | `Terminal has quit`, disabled |
| No ancestry at all | `Terminal unknown`, disabled |

**The row is always rendered, never hidden**, and that is a hard requirement
rather than a style choice. The card is sized across *all* sessions so that
browsing the switcher never resizes it — `expandedChromeHeight` is a constant,
the permission answer block already reserves its height for exactly this
reason, and two `--selftest` checks guard the invariant. A row present for one
session and absent for another would reflow the whole HUD on every click, which
is the bug those checks exist to catch. Hence a fourth label instead of a
hidden state.

Disabled-with-a-reason rather than hidden, matching how the card already refuses
to answer two simultaneous prompts and says why. A hidden control and a broken
one look identical; a labelled one does not.

The fourth row is the replay and synthetic-event case, not a state a user
reaches — hooks bake an absolute path to a binary that is replaced wholesale on
upgrade, so a stale client that omits pids is not reachable in practice.

This falls out correctly for tmux and SSH without special-casing either: a tmux
server is a daemon with ppid 1, and an SSH session's ancestry is on the remote
host, so both resolve to no owner and get the honest message instead of a
confident jump to the wrong window.

### Raising

`/usr/bin/open -b <bundleID>`, spawned off the main thread with an argv array
and no shell. The bundle id comes from LaunchServices rather than from any
payload, so nothing user-controlled reaches the command — but the argv form
means that stays true even if that ever changes.

### The mute upgrade

`AppController.rings(_:under:frontmost:)` gains the session's resolved owner.

- Owner resolved → mute only when `frontmost == owner`.
- Owner unresolved → fall back to today's `TerminalApps.matches` heuristic.

Strictly better where it applies and behaviour-preserving where it does not.
`TerminalApps` survives as the fallback, and its header comment gets rewritten:
it is no longer the only thing standing between us and knowing which app a
session belongs to, and the apology should stop claiming otherwise.

## Non-goals

- **Tab or window selection.** `open -b` reaches the app, not the tab. Going
  further means AppleScript per terminal and an Automation TCC prompt, which
  would cost the app its zero-permission property. It also cannot help the
  primary setup here: sessions run in VS Code's integrated terminal, which
  exposes no tab API at all.
- **Unbundled apps.** No bundle id, no `open -b`. Disabled.
- **Anything on the peek card.** Peek is hover-driven and transient; a control
  that leaves the machine's focus does not belong on a surface you can open by
  crossing the screen.

## Known edges

- An app running with **zero open windows** may gain one when raised. Accepted:
  it is the same thing `open` does everywhere else on the system, and the
  alternative is a jump that appears to do nothing.
- Two sessions in the same terminal app both reveal to that app. Expected at
  app-level granularity, and stated by the button naming the app.

## Verification

Unit tests, in Core, with no window server:

- The splice: normal object, `{}`, leading whitespace, and a non-`{` payload.
  Also a payload that already carries an `_island_pids` key — the spliced copy
  goes in first, so Foundation's decoder takes the later one and the payload's
  own value wins. That is acceptable rather than desirable: the key is
  namespaced and Claude Code does not emit it. The test exists to pin that the
  collision produces valid JSON and a defined winner rather than a crash.
- `OwnerResolution.first` against a fake lookup: helper-then-app chains, chains
  with no regular app, empty chains, and dead pids.
- The mute matrix: resolved-and-matching, resolved-and-not, unresolved-falls-back.
- Envelope decoding with the field present, absent, and malformed.
- Ancestry is not cleared by an envelope that omits it.

A replay fixture carrying `_island_pids`, so the field survives the full
pipeline headlessly.

`--selftest` gains checks for which of the four button states renders for a
given session shape. It deliberately does **not** fire a real activation:
`open` yanks focus, and a harness that moves the frontmost app mid-run would
break the focus checks that run beside it. The activation path itself is
verified by the spike recorded above and by manual check in `Scripts/verify/`.

## Supporting changes

- `Sources/claude-island-notify/main.swift` — ancestry walk and splice.
- `Sources/ClaudeIslandCore/HookEnvelope.swift` — decode `_island_pids`.
- `Sources/ClaudeIslandCore/Session.swift` — hold the ancestry.
- `Sources/ClaudeIslandCore/OwnerResolution.swift` — new, pure walk.
- `Sources/ClaudeIslandCore/TerminalApps.swift` — rewrite the header comment.
- `Sources/ClaudeIslandApp/SessionOwner.swift` — new, AppKit binding + raise.
- `Sources/ClaudeIslandApp/IslandContentViews.swift` — the button.
- `Sources/ClaudeIslandApp/AppController.swift` — mute rule.
- `README.md` — the activation finding belongs under "Things worth knowing";
  three APIs that return success and do nothing is exactly the kind of lesson
  that section exists to record.
