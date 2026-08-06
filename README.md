# ClaudeIsland

A Dynamic Island-style HUD pinned to the notch that shows, in real time, what
your running Claude Code sessions are doing.

Swift 6 · SwiftUI · macOS 14+ · no third-party dependencies · builds from the
CLI with Command Line Tools (no Xcode required).

```
┌─────────────────────────────────────────────┐
│  ⌘ Bash  swift build           0:12   ● ● ● │   compact
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│  ✋ Allow Write? · claude-island   0:07   ②  │   alert
│     ~/notch/Sources/IslandPanel.swift        │
└─────────────────────────────────────────────┘
```

## Build

```bash
swift build -c release          # binaries
./Scripts/bundle.sh             # -> dist/ClaudeIsland.app (ad-hoc signed)
open dist/ClaudeIsland.app
```

Then install the hooks, from the menu bar extra or the CLI:

```bash
dist/ClaudeIsland.app/Contents/MacOS/ClaudeIsland --install-hooks
```

This **merges** into `~/.claude/settings.json`, writes a timestamped backup
first, preserves hook entries belonging to other tools, and is idempotent.
`--print-hooks` prints the block to paste by hand instead. Restart any running
Claude Code sessions afterwards.

## Architecture

Three pieces.

**`claude-island-notify`** — the hook client. Claude Code invokes it on every
hook; it reads the payload from stdin and writes it to a Unix socket at
`~/.claude-island/island.sock` with a 4-byte little-endian length prefix.

Hooks block Claude Code, so this binary is fire-and-forget by construction:
non-blocking connect with a 50 ms budget, write, `_exit(0)`. Every failure path
is a silent `exit(0)` — a dead HUD must never break or slow a session. It
imports `Darwin` and nothing else, not even Foundation, because Foundation
alone adds milliseconds of dyld work per invocation.

*Measured, release build, no listener: 2.49 ms median, 4.67 ms p95.*

**`ClaudeIslandCore`** — everything below the UI, with no AppKit dependency at
all. That is what lets the whole pipeline run headlessly.

- `SocketServer` — unlinks any stale socket, binds, `chmod 0600`, one
  connection per hook, decodes to an async stream. Connection handling is
  capped at 8 in flight so a burst across several worktrees cannot spawn a
  thread per connection.
- `SessionReducer` — a pure function from `(envelope, session)` to
  `(session, timed follow-ups)`. The entire transition table is testable with
  no async and no clock.
- `SessionStore` — an actor keyed by `session_id`, publishing snapshots.
- `TranscriptWatcher` — FSEvents (never polling) on each tracked transcript's
  directory; seeks to a stored byte offset and reads only what was appended.
- `TaskProgress` — replays the session's plan from the transcript. `TodoWrite`
  writes snapshots, `TaskCreate`/`TaskUpdate` write deltas; both fold into one
  list so the HUD does not care which a session uses.

**The HUD** — an `NSPanel`, not a `Window`. Borderless, `.nonactivatingPanel`,
`level = .statusBar + 1`, refusing both key and main. The panel stays at
expanded size permanently with a transparent background; the island shape is
drawn inside it, so the morph never resizes a window.

## Things worth knowing

**Two hook events beyond the obvious nine.** `PermissionRequest` gives the
exact tool and input for a permission prompt instead of pattern-matching
notification prose, and `PostToolUseFailure` is the only clean signal for the
error state. `Notification` is still handled as a fallback, conservatively:
text it does not recognise leaves the state alone rather than guessing.

**`thinking` is inferred, not observed.** Claude Code has no "assistant started
responding" hook. It is entered on `PostToolUse` and when the `prompting` flash
expires.

**A permission clears on any subsequent event.** Approve leads to `PostToolUse`,
deny leads to `UserPromptSubmit`; rather than enumerate every resolution path,
anything else happening counts as resolution.

**Alerts outrank recency.** A session awaiting permission stays on screen even
if another worktree is more recently active — otherwise the prompt vanishes
exactly when you need it.

**Subagents share the parent's `session_id`.** A running `Task` interleaves its
own `Bash`/`Read` events into the parent's stream. Rather than filter them out,
depth is tracked as a stack and the HUD shows the inner tool with a subagent
badge, because what the subagent is *doing* is the useful part.

**Token counts are split, not summed.** Claude Code writes one JSONL line per
content block and repeats the same `usage` object on each: a real transcript
here had 55 assistant lines across 26 distinct `requestId`s, so naive summing
overcounts output tokens by roughly 2×. The parser dedupes by `requestId`.
Separately, summing `input_tokens` is close to meaningless when it reads 2
against a 50,211 cache read, so the card shows live **context** occupancy (last
message's input + cache read + cache creation), cumulative **output**, and cache
reads as a **hit ratio** rather than a millions-scale raw sum. Subagent
(`isSidechain`) messages count toward spend but not toward context, since they
run in their own window.

**Branch, effort and plan progress come from the transcript, not hooks.** Hook
payloads carry none of them; transcript lines carry `gitBranch` and `effort`,
and tool calls carry the plan. One trap: `tool_use` blocks arrive on assistant
lines that *share a requestId* with the response's text and thinking blocks, so
the usage dedupe has to be applied to token counting only — folding task parsing
into it silently drops any plan update that was not the first line of a
response.

**Redaction happens at the store boundary**, not in a view, so the redacted
string is the only string the UI can ever hold. Truncation to 60 characters
happens *after* redaction — truncating first could cut a secret in half and
leave the leading half on screen.

## The notch is a hole, not a region

The single most expensive lesson here. Content drawn inside the notch band is
not clipped by software — those pixels do not exist. A 44pt pill centred on the
cutout put its text at y≈22, inside the 38pt hole, and the text vanished at
exactly `auxiliaryTopLeftArea.maxX` (790 on this display) and reappeared past
`auxiliaryTopRightArea.minX` (1010). It looked exactly like a truncation bug and
survived two wrong fixes before the cut was measured and landed on 790.5.

So on a notched display every tier is `notchHeight + content`, with content
inset below the cutout. The shape still wraps the notch — that is what makes it
read as the island — but nothing informative is ever placed in the band.

## Two implementation notes that cost real work

**Click-through cannot use an `NSTrackingArea`.** The obvious design — toggle
`ignoresMouseEvents` from a tracking area — is circular: once the panel ignores
mouse events it receives none, so the tracking area can never fire
`mouseEntered` to switch it back. A global `NSEvent` monitor runs outside the
panel and sees the cursor regardless. Mouse-only global monitors need no
Accessibility permission (keyboard ones do). The monitor is installed only
while a session is active.

**Repeating animations run in Core Animation, not SwiftUI.** A
`withAnimation(....repeatForever())` re-runs the entire view graph every frame.
Profiling showed `CA::Transaction::flush` → `NSHostingView.layout()` → full
`ViewGraph` render at the display's 120 Hz, costing **4.5% CPU** for one pulsing
glyph — against a 0.1% idle budget. The same pulse as a `CABasicAnimation` is
handed to the render server once and costs the app process nothing per frame:
**0.33%**. The shape morph is still a SwiftUI spring; only the two perpetual
animations moved.

## Measured behaviour

| | |
|---|---|
| Idle CPU, no sessions | **0.000%** over 40 s |
| Compact, animating | 0.2% |
| Alert, pulsing | 0.33% |
| Hook client, no listener | 2.49 ms median / 4.67 ms p95 |
| Tests | 98 passing |
| Self-test | 41 checks passing |

## Interaction

Three levels of detail, each earning its own layout.

**Compact** — a single line, always. Glyph, session name, then the status word
and mark on the right. While a tool runs the name gives way to that tool's
target and returns when it finishes.

Every tracked session rests as one line, including `Done` and `Your turn`.
Those two used to collapse to dormant, which hid exactly the states you are most
likely to be waiting on. Only a HUD with no sessions at all goes dark.

The status vocabulary and mark follow the reference design: `Thinking` with a
spinning ring, `Your turn` with a completed ring that breathes, `Done` with a
solid ring and a check.

**Peek** (hover) — adds the identity line (branch, model, effort, elapsed),
context and output tokens, and plan progress with the task currently in flight.

**Expanded** (click) — a switcher. Every active session is listed and
clickable; selecting one shows its detail below. Click the island again, or
anywhere outside, to dismiss.

A permission request always takes over the view, even from an explicit
selection — missing a prompt is worse than losing your place. The selection is
kept rather than discarded, the takeover is labelled, and the view returns to
your session once the prompt is answered.

When no session is active the island is dormant and deliberately unreachable —
the mouse monitor is torn down entirely, which is what keeps idle CPU at
0.000% rather than merely low. Use the menu bar extra in that state.

## Verification

```bash
swift build && swift run ClaudeIslandTests      # 98 tests
./dist/.../ClaudeIsland --replay Fixtures/basic-session.jsonl
./dist/.../ClaudeIsland --selftest              # focus + click-through
./dist/.../ClaudeIsland --probe-screens         # notch geometry per display
```

`--replay` feeds a recorded JSONL log through the full pipeline with no UI, on a
virtual clock so timed transitions fire deterministically and traces are
byte-stable. Fixtures in `Fixtures/` cover a normal session, permissions and
failures, two concurrent sessions, subagents, and deliberately hostile input
(malformed lines, unknown future events, embedded secrets).

`--selftest` checks the two behaviours that unit tests cannot: that the panel
never takes focus, and that clicks land where they should. Click-through is
verified against the window server itself via `NSWindow.windowNumber(at:)`
rather than trusting our own flags. **Run it with the screen unlocked** — a lock
screen puts a full-screen `loginwindow` layer above everything and those three
checks are reported as skipped rather than silently passing.

### Known conflict: other notch HUDs

The panel sits at `.statusBar + 1` (level 26). Some notch apps use far higher
levels — "Claude Usage" on this machine holds the notch at level **1000** — and
will render above ClaudeIsland and win the hit test over the island shape. This
is by design rather than a defect: the level is deliberately conservative so the
HUD never floats above things it shouldn't.

`--selftest` detects this and names the offending app instead of reporting a
failure. Quit the other app to evaluate that check, or raise the level in
`IslandPanel.init` if you would rather ClaudeIsland win.

### Note on the test harness

Tests run via `swift run ClaudeIslandTests`, not `swift test`. Apple's Command
Line Tools ship swift-testing's module and macro plugin but not
`lib_TestingInterop.dylib`, so an `.xctest` bundle compiles and then fails to
`dlopen`; XCTest is Xcode-only. Since the project takes no third-party
dependencies, `Tests/ClaudeIslandCoreTests/TinyTest.swift` is a ~120-line
harness whose call shapes (`expect`, `require`, `fail`) mirror swift-testing, so
the suites port back with a mechanical find-and-replace if Xcode is installed.

## Configuration

Logging is **off by default**. Enable it from the menu bar, or:

```bash
touch ~/.claude-island/debug      # or CLAUDE_ISLAND_DEBUG=1
```

It writes to `~/.claude-island/log`, capped at 1 MiB with a single rotation.

No network calls are made, ever. All data is local.

## Sandboxing

Ships unsandboxed. The socket lives in `~/.claude-island/` and transcripts are
read from `~/.claude/projects/`, both outside any container. To sandbox it:

1. Move the socket into the container (`~/Library/Containers/<id>/Data/`) and
   teach the hook client to find it there — it currently hardcodes
   `$HOME/.claude-island/island.sock`, and `$HOME` differs inside a sandbox.
2. Obtain read access to `~/.claude/projects/` and `~/.claude/sessions/`, which
   means a user-selected security-scoped bookmark; there is no entitlement that
   grants another app's support directory.
3. Writing hooks into `~/.claude/settings.json` needs the same bookmark, or the
   installer becomes copy-and-paste only.
4. Add `com.apple.security.app-sandbox` plus `files.user-selected.read-write`,
   and sign with a real Developer ID rather than ad-hoc.

Step 2 is the awkward one: a sandboxed build would have to prompt for access to
`~/.claude` on first run and persist the bookmark.

## Layout

```
Sources/ClaudeIslandCore/     types, state machine, store, watcher, redaction, IPC
Sources/ClaudeIslandApp/      panel, views, menu bar, CLI entry points
Sources/claude-island-notify/ hook client (Darwin only)
Tests/ClaudeIslandCoreTests/  suites + TinyTest harness
Fixtures/                     replay logs
Scripts/bundle.sh             .app assembly + ad-hoc signing
docs/superpowers/specs/       design document
```
