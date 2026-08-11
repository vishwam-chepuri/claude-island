#!/usr/bin/env python3
"""Drive a real interactive Claude Code session and answer its prompt from the HUD.

No --settings override: this uses the hooks actually installed in
~/.claude/settings.json, so it exercises exactly what a user gets.

  real_session.py allow      — press Allow on the island, expect the tool to run
  real_session.py deny       — press Deny, expect the tool to be blocked
  real_session.py terminal   — answer "no" in the terminal, expect the island to
                               withdraw its controls and the hook to be reaped
"""
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

CWD = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODE = sys.argv[1] if len(sys.argv) > 1 else "allow"
TARGET = f"tmp/real-{MODE}.txt"
DEADLINE = 180.0
ALLOW_BUTTON = 'AXButton "Allow"'

os.chdir(CWD)
for stale in (TARGET,):
    if os.path.exists(stale):
        os.unlink(stale)

PROMPT = (
    f"Use the Write tool to create the file {TARGET} containing exactly: "
    f"real-{MODE}. Do nothing else."
)


def island(*args):
    """Talk to the HUD through the accessibility helper."""
    return subprocess.run(
        ["swift", f"{CWD}/Scripts/verify/press.swift", *args],
        capture_output=True, text=True, timeout=120).stdout


def hover():
    subprocess.run(["swift", f"{CWD}/Scripts/verify/warp.swift", "900", "20"],
                   capture_output=True, timeout=120)
    time.sleep(1.0)


pid, fd = pty.fork()
if pid == 0:
    os.chdir(CWD)
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLUMNS"] = "100"
    os.environ["LINES"] = "40"
    os.execvp("claude", ["claude", "--permission-mode", "default"])

captured = bytearray()
start = time.time()
typed = submitted = acted = False
dialog_at = None
log = []

try:
    while time.time() - start < DEADLINE:
        r, _, _ = select.select([fd], [], [], 0.4)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            captured.extend(chunk)

        elapsed = time.time() - start
        if not typed and elapsed > 8:
            os.write(fd, PROMPT.encode())
            typed = True
        elif typed and not submitted and elapsed > 11:
            os.write(fd, b"\r")
            submitted = True
            log.append(f"submitted at {elapsed:.0f}s")

        if submitted and not acted and b"Do you want" in captured:
            if dialog_at is None:
                dialog_at = time.time()
                log.append(f"terminal dialog appeared at {elapsed:.0f}s")
            # Give the hook a moment to reach the HUD and the card to lay out.
            elif time.time() - dialog_at > 2.5:
                hover()
                tree = island("dump")
                has_allow = ALLOW_BUTTON in tree
                log.append(f"island offered controls: {has_allow}")
                if MODE == "terminal":
                    os.write(fd, b"3")           # "No" in the terminal.
                    log.append("answered 3 (No) in the terminal")
                    time.sleep(3)
                    hover()
                    # Whether the island can still offer an answer comes down to
                    # whether the hook client is still alive, so measure that
                    # rather than reading it off a card that may have moved on.
                    for t in range(0, 12, 2):
                        alive = subprocess.run(
                            ["pgrep", "-f", "await-decision"],
                            capture_output=True, text=True).stdout.split()
                        log.append(f"    +{t}s after terminal answer: {len(alive)} hook(s) waiting")
                        time.sleep(2)
                else:
                    log.append(island("press", "Allow" if MODE == "allow" else "Deny").strip())
                acted = True
finally:
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.5)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.close(fd)

clean = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", bytes(captured)).decode("utf-8", "replace")
clean = re.sub(r"\x1b\]8;[^\x1b]*\x1b\\\\", "", clean)

print(f"--- {MODE} ---")
for line in log:
    print("  " + line)
print(f"  file created: {os.path.exists(TARGET)}")
for marker in ("Allowed by PermissionRequest hook", "Denied by PermissionRequest hook",
               "User rejected", "Do you want"):
    n = clean.count(marker)
    if n:
        print(f"  transcript {marker!r}: {n}")
