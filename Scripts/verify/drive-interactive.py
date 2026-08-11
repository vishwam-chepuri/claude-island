#!/usr/bin/env python3
"""Drive a real interactive Claude Code session over a pty.

The PermissionRequest hook only fires on the interactive prompt path, so a
headless `claude -p` run cannot exercise it. This spawns claude on a genuine
pty, types a prompt, and records everything the TUI paints — which is how we
can tell whether a permission dialog was ever shown.
"""
import os
import pty
import select
import signal
import sys
import time

CWD = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PROMPT = sys.argv[1] if len(sys.argv) > 1 else "Use the Write tool to create tmp/probe/target.txt containing exactly: probe-allowed. Do nothing else."
DEADLINE = float(sys.argv[2]) if len(sys.argv) > 2 else 90.0

argv = [
    "claude",
    "--settings", "tmp/probe/settings.json",
    "--permission-mode", "default",
]

pid, fd = pty.fork()
if pid == 0:
    os.chdir(CWD)
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLUMNS"] = "100"
    os.environ["LINES"] = "40"
    os.execvp(argv[0], argv)

captured = bytearray()
start = time.time()
typed = False
submitted = False
# Optional third arg: a key to press once the permission dialog is on screen,
# to race a terminal answer against a still-pending hook.
race_key = sys.argv[3].encode() if len(sys.argv) > 3 else None
dialog_seen_at = None
raced = False

try:
    while time.time() - start < DEADLINE:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            captured.extend(chunk)
        # Let the TUI finish its first paint before typing.
        if not typed and time.time() - start > 8:
            os.write(fd, PROMPT.encode())
            typed = True
        # Submit as a separate write: sending the newline in the same burst as
        # the text gets swallowed by the input handling.
        elif typed and not submitted and time.time() - start > 11:
            os.write(fd, b"\r")
            submitted = True

        if race_key and not raced:
            if dialog_seen_at is None and b"Do you want" in captured:
                dialog_seen_at = time.time()
            elif dialog_seen_at and time.time() - dialog_seen_at > 3:
                os.write(fd, race_key)
                with open(os.path.join(CWD, "tmp/probe/timing.log"), "a") as f:
                    f.write(f"terminal answered at {time.time():.6f}\n")
                raced = True
finally:
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.5)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.close(fd)

out = captured.decode("utf-8", "replace")
with open(os.path.join(CWD, "tmp/probe/tui.log"), "w") as f:
    f.write(out)
print(f"captured {len(out)} bytes of TUI output -> tmp/probe/tui.log")
