# Verification harnesses

These exist because the permission-answering path cannot be verified by unit
tests alone. It depends on a contract with Claude Code that is not documented
anywhere citable, and which will change: whether `PermissionRequest` still
accepts a decision, whether it still races the terminal dialog rather than
replacing it, and whether the JSON shape still holds. When it changes, the
symptom will be a button that quietly stops working — so re-verify with these
rather than reasoning about it.

Everything here writes scratch output to `tmp/` and touches nothing else. None
of it modifies `~/.claude/settings.json`.

## `drive-interactive.py` — does the contract still hold?

Drives a real interactive Claude Code session over a pty, with a hook block you
control via `--settings`, so a hook can answer a real prompt and the result can
be read back out of the TUI.

**`PermissionRequest` only fires on the interactive path.** A headless `claude -p`
run never fires it — the tool is simply denied for want of a TTY — so it cannot
be tested that way. Hence the pty.

Two things that cost an hour each to discover: type the prompt and send the `\r`
as **separate** writes, or the TUI swallows the submit; and the island draws pure
black to read as the cutout, so it is invisible in a screenshot unless you know
where to look.

```bash
python3 Scripts/verify/drive-interactive.py "Use the Write tool to create tmp/x.txt containing: hi" 100
```

Look for `Allowed by PermissionRequest hook` / `Denied by PermissionRequest hook`
in `tmp/tui.log` — that is Claude Code confirming a hook settled the prompt.

## `press.swift` — talk to the HUD without guessing coordinates

Walks the running HUD's accessibility tree and presses a control by title.

Coordinate clicking is not usable for verification: the answer block moves down
as sessions come and go, so a point measured from a screenshot is stale seconds
later. This asks the app what it is showing.

```bash
swift Scripts/verify/press.swift dump          # what the card is showing
swift Scripts/verify/press.swift press Allow   # settle a prompt
```

The card only exists at peek or expanded, and the panel ignores mouse events
until the cursor is inside it, so hover first:

```bash
swift Scripts/verify/warp.swift 900 20         # also prints AXIsProcessTrusted
```

## `corner-cases.sh` — the synthetic suite

Drives the real app over the real socket with the real hook client. Covers deny
with a note, redaction, whole-path display for file tools, prompts that offer no
controls (fire-and-forget, notification-derived), withdrawal when a client dies,
two sessions resolving independently, and the HUD dying mid-prompt.

```bash
./Scripts/verify/corner-cases.sh
```

## `real-session.py` — the whole loop, for real

A real session, the installed hooks, and the island answering it.

```bash
python3 Scripts/verify/real-session.py allow      # press Allow, expect the tool to run
python3 Scripts/verify/real-session.py deny       # press Deny, expect it blocked
python3 Scripts/verify/real-session.py terminal   # answer in the terminal instead
```

`terminal` mode records something worth re-checking whenever Claude Code updates:
answering in the terminal does **not** reap the waiting hook — measured still
alive 10s later — so there is no signal that a prompt was settled elsewhere. The
card relies on the session's next event to retire it.

## Caveats

- Requires Accessibility permission for whatever runs `press.swift`; it prints
  `AXIsProcessTrusted` so a silent no-op is distinguishable from a real failure.
- These observe the *displayed* session. If another session is primary at that
  moment, a check can read as a failure when nothing is wrong — verify by hand
  before believing a single red result.
- A held prompt needs a client that waits. A fire-and-forget synthetic event
  produces a prompt with no decision token and therefore no controls; pose one
  with `claude-island-notify --await-decision`.
