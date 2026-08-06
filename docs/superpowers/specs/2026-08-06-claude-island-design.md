# ClaudeIsland — Design

Date: 2026-08-06
Status: approved

A native macOS Dynamic Island-style HUD pinned to the notch that shows, in real
time, what running Claude Code sessions are doing.

## Targets

- Swift 6, SwiftUI, macOS 14+.
- `LSUIElement = true`. A menu bar extra is the only chrome.
- No third-party dependencies. SwiftPM, buildable entirely from the CLI with
  Command Line Tools — no Xcode, no `.xcodeproj`.
- Unsandboxed. See README for what sandboxing would require.

## Verified environment facts

Measured on the development machine, 2026-08-06:

```
Built-in Retina  1800x1169   safeAreaInsets.top 38
  auxTopLeft  (0, 1131, 790, 38)     auxTopRight (1010, 1131, 790, 38)
  -> notch = x 790..1010, y 1131..1169  =  220 x 38, centered (screen mid = 900)
DELL P3223QE     2560x1440   safeAreaInsets 0, aux areas nil  -> pill fallback
```

The external display sits *above* the laptop in the arrangement, so the menu bar
moving between displays is a case that must work, not a hypothetical.

Transcript JSONL schema (`~/.claude/projects/<slug>/<session-id>.jsonl`):
`type: "assistant"` lines carry `message.model` and
`message.usage.{input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens}`.
Observed values skew heavily to cache: `input_tokens: 2` against
`cache_read_input_tokens: 50211`.

`~/.claude/sessions/*.json` maps `sessionId` to a user-set session `name` (set
via `/session`). Used as the primary session label, with `basename(cwd)` as
fallback.

The developer already has hooks installed pointing at an HTTP receiver on
`127.0.0.1:19847`. The installer must merge, never overwrite.

## Package layout

```
Package.swift                      swift-tools 6.0, platforms: [.macOS(.v14)]
Sources/
  ClaudeIslandCore/     zero AppKit. types, state machine, store, watcher,
                        redaction, log, socket server
  ClaudeIslandApp/      AppKit/SwiftUI executable; also hosts --replay
  claude-island-notify/ hook client; imports Darwin only, not Foundation
Tests/ClaudeIslandCoreTests/
Fixtures/*.jsonl
Scripts/bundle.sh     -> ClaudeIsland.app + Info.plist + ad-hoc codesign
```

Core carrying no AppKit dependency is what makes `swift test` headless and fast,
and is what lets `--replay` exercise the whole pipeline with no `NSApplication`.

## Hook payload types

One tolerant envelope rather than per-event structs. Unrecognized events decode
to `.unknown` and are logged, never dropped.

```swift
struct HookEnvelope: Sendable {
    let sessionID: String            // session_id - the only required field
    let event: HookEvent             // hook_event_name
    let cwd: String?
    let transcriptPath: String?
    let toolName: String?
    let toolInput: JSONValue?        // untyped tree - no per-tool structs
    let message: String?             // Notification
    let trigger: String?             // PreCompact: manual|auto
    let source: String?              // SessionStart: startup|resume|clear|compact
    let reason: String?              // Stop / SessionEnd
    let receivedAt: ContinuousClock.Instant
}
```

`toolInput` stays a `JSONValue` enum deliberately: `Bash.command`,
`Edit.file_path`, `WebFetch.url` become key lookups, and a tool added in a future
Claude Code release cannot break decoding.

`HookEvent` covers the nine requested events plus two additions:

- **`PermissionRequest`** — a precise `awaitingPermission` signal carrying the
  exact tool and input, rather than inferring from notification text.
- **`PostToolUseFailure`** — already present in the developer's settings, and the
  only clean path to the `error` state.

Our `PermissionRequest` hook sits in the allow/deny decision path. It exits 0
with no output, which is "no decision" / passthrough.

## Session state machine

```swift
enum SessionState {
    case idle                        // incl. notification-idle ("waiting for your input")
    case prompting                   // ~1s flash, auto-advances
    case thinking
    case running(ToolActivity)       // tool, target, startedAt
    case awaitingPermission(Ask)     // tool, target, since
    case compacting
    case done
    case error(String)               // auto-decays -> .thinking after 4s
}
```

| Event | New state | Note |
|---|---|---|
| `SessionStart` | `.idle` | reset counters, arm TranscriptWatcher |
| `UserPromptSubmit` | `.prompting` | 1s timer -> `.thinking` |
| `PreToolUse` | `.running(tool)` | start op timer |
| `PermissionRequest` | `.awaitingPermission` | loud |
| `Notification` (permission-shaped) | `.awaitingPermission` | text-matched fallback |
| `Notification` (idle-shaped) | `.idle` | soft |
| `PostToolUse` | `.thinking` | |
| `PostToolUseFailure` | `.error` | decays to `.thinking` |
| `PreCompact` | `.compacting` | |
| `Stop` | `.done` | |
| `SubagentStop` | pop subagent frame | see below |
| `SessionEnd` | remove after 5s fade | |

Four consequential subtleties:

**`.thinking` has no hook.** There is no "assistant started responding" event. It
is inferred — entered on `PostToolUse` and on the `prompting` timer expiring. It
is a gap-filler, not an observed state.

**Permission clears on any subsequent event,** not a specific one. Approve ->
run -> `PostToolUse` and deny -> `UserPromptSubmit` are both just "something else
happened." This is robust against denial paths not enumerated here.

**Subagents share the parent `session_id`.** A running `Task` interleaves its
`Bash`/`Read` events into the parent's stream. Rather than filter them, treat it
as a stack: `PreToolUse(Task)` pushes a subagent frame, `SubagentStop` pops.
While depth > 0 the leading glyph is the subagent glyph and the label shows the
inner tool — so the HUD shows what the subagent is doing, which is the useful
thing.

**Selection is not purely most-recent.** `awaitingPermission` sorts above
recency. Otherwise a permission prompt in worktree B is hidden the instant
worktree A runs a `Read` — exactly when it most needs to be seen.

Sessions self-expire after 30 minutes with no events. The sweep timer runs only
while sessions exist.

## IPC

4-byte little-endian `UInt32` length prefix followed by raw JSON bytes. One
payload per connection; the client closes immediately. 16 MiB server-side cap —
a `Write` tool_input carries an entire file body, so this is not theoretical.

Socket at `~/.claude-island/island.sock`, unlinked and recreated on launch,
chmod 0600.

Client path: `read(0,...)` -> `socket` -> non-blocking `connect` + 50 ms `poll`
-> `write` -> `_exit(0)`. No Foundation import; wall time is dyld-dominated at
roughly 3-5 ms. Every failure path is a silent `exit(0)`. A dead HUD must never
break or slow a Claude session.

## Redaction

Applied at the `SessionStore` boundary, not in the view. Truncation to 60
characters and secret-stripping (`sk-`, `ghp_`, `AKIA`, `Bearer`, JWT `eyJ...`,
`password=`, high-entropy hex/base64 runs) happen when the envelope enters the
store, so the redacted form is the only form the UI can ever see — and it is
unit-testable without a window.

## TranscriptWatcher

FSEvents on `~/.claude/projects` (not polling). Per-session stored byte offset;
seek, read the tail, parse only the last complete `type: "assistant"` line. Never
re-read the whole file.

Token reporting:

- **Context** — last message's `input + cache_read + cache_creation`, the live
  window occupancy.
- **Session** — cumulative `output`, cumulative `cache_creation`, and cache reads
  as a hit ratio rather than a raw sum.

Summing `input_tokens` across a session is near-meaningless when it reads 2
against a 50,211 cache read; summing cache reads produces a millions-scale
number that misreads at a glance. Hence the split.

## HUD

`NSPanel` subclass: borderless, `.nonactivatingPanel`, `isFloatingPanel = true`,
`level = .statusBar + 1`, `hidesOnDeactivate = false`, `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`. The panel
must never take key or main. Clicking it must never steal focus from the
terminal; this is the single most important behavioral requirement.

The panel stays at expanded size permanently with a transparent background; the
island shape is drawn inside it.

**Click-through.** `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)`
drives `ignoresMouseEvents` by shape containment. A global monitor is required
because the `NSTrackingArea` approach is circular: once `ignoresMouseEvents` is
true the panel receives no mouse events at all, so a tracking area can never fire
`mouseEntered` to turn it back off. Mouse-only global monitors do not require
Accessibility permission. The monitor is torn down entirely when dormant, which
is also how idle CPU reaches zero.

**Geometry.** Notch bounds = `auxiliaryTopLeftArea.maxX ... auxiliaryTopRightArea.minX`
horizontally, `safeAreaInsets.top` for height. Nil aux areas -> centered pill
under the menu bar, same visual language. Recompute on
`NSApplication.didChangeScreenParametersNotification`.

## Visual states

1. `dormant` — invisible / exactly notch-shaped. No sessions active.
2. `compact` — pill: leading tool glyph (Bash, Edit, Read, Grep, WebFetch,
   Task), trailing animated indicator, elapsed timer for the current operation.
3. `alert` — permission request. Distinct accent, subtle pulse, tool name plus
   target.
4. `expanded` — card on hover or click: repo/session name, model, session
   elapsed, tokens with cache split, last 3 tool calls, other active sessions.

Animation: SwiftUI springs only, no duration easing. `matchedGeometryEffect` for
the shape morph. `RoundedRectangle(cornerRadius:style: .continuous)` so corners
animate continuously and never snap. Pure `#000` fill so it reads as the physical
cutout. Respect Reduce Motion.

## Constraints

- Idle CPU under 0.1%. No perpetual redraw loop: the spinner stops and the
  global mouse monitor is removed when no session is active.
- No network calls, ever. All data is local.
- Never render more than 60 chars of a command; strip secrets before display.
- Log to `~/.claude-island/log`, size-capped with single rotation, off by
  default.

## Headless testability

`--replay <file>` feeds a JSONL event log through the full pipeline with no UI
and emits a deterministic state-transition trace to stdout, suitable for
golden-file tests. `--record <file>` on the live app captures real fixtures.

## Hook installation

The menu bar extra's "Install hooks" merges into `~/.claude/settings.json`,
preserving existing hook entries (the developer already runs an unrelated HTTP
hook receiver), writing a timestamped backup first, and is idempotent — entries
are keyed by the `claude-island-notify` command path.
