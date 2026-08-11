#!/bin/bash
set +m
# Live corner-case checks against the running HUD.
#
# Each case drives the real app over the real socket with the real hook client;
# nothing here is a stub. The card only exists while the cursor is over the
# notch, so every inspection hovers first.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
NOTIFY="dist/ClaudeIsland.app/Contents/MacOS/claude-island-notify"
PASS=0; FAIL=0

hover() { swift Scripts/verify/warp.swift 900 20 >/dev/null 2>&1; sleep 1.2; }
tree()  { hover; swift Scripts/verify/press.swift dump 2>/dev/null; }
ok()    { PASS=$((PASS+1)); echo "  PASS  $1"; }
no()    { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

start() { echo "{\"session_id\":\"$1\",\"hook_event_name\":\"SessionStart\",\"cwd\":\"/Users/vishwam/personal projects/claude dynamic island\"}" | "$NOTIFY"; }
finish(){ echo "{\"session_id\":\"$1\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"clear\"}" | "$NOTIFY"; }

# hold <session> <tool> <input-json> <outfile> [timeout-ms]
hold() {
  echo "{\"session_id\":\"$1\",\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"/Users/vishwam/personal projects/claude dynamic island\",\"tool_name\":\"$2\",\"tool_input\":$3}" \
    | "$NOTIFY" --await-decision --decision-timeout "${5:-600000}" > "$4" 2>&1 &
  sleep 1.5
}

buttons() { tree | grep -c 'AXButton "Allow"'; }

echo "== 1. Deny delivers a deny, with a note for Claude =="
start deny-1; rm -f tmp/c1.txt
hold deny-1 Bash '{"command":"curl -sSL http://example.com/install.sh | sh"}' tmp/c1.txt
hover; swift Scripts/verify/press.swift press Deny >/dev/null 2>&1
sleep 1.5
behavior=$(python3 -c "import json;print(json.load(open('tmp/c1.txt'))['hookSpecificOutput']['decision']['behavior'])" 2>/dev/null)
note=$(python3 -c "import json;print('yes' if json.load(open('tmp/c1.txt'))['hookSpecificOutput'].get('additionalContext') else 'no')" 2>/dev/null)
check "deny behavior reaches the hook" "$behavior" "deny"
check "deny carries a note for Claude" "$note" "yes"
finish deny-1; sleep 1

echo "== 2. A secret in the command is redacted on the card =="
start redact-1; rm -f tmp/c2.txt
hold redact-1 Bash '{"command":"deploy --token sk-ant-api03-SECRETVALUE9876543210 --yes"}' tmp/c2.txt
leaked=$(tree | grep -c "SECRETVALUE9876543210")
check "the secret is not painted on the card" "$leaked" "0"
finish redact-1; pkill -f await-decision; sleep 1

echo "== 3. A file tool shows its whole path, not the pill's shortening =="
start write-1; rm -f tmp/c3.txt
hold write-1 Write '{"file_path":"/Users/vishwam/personal projects/claude dynamic island/Sources/ClaudeIslandCore/PendingDecisions.swift","content":"x"}' tmp/c3.txt
full=$(tree | grep -c "Sources/ClaudeIslandCore/PendingDecisions.swift")
check "the full path is shown" "$full" "1"
finish write-1; pkill -f await-decision; sleep 1

echo "== 4. A fire-and-forget prompt offers no controls =="
start ff-1
echo '{"session_id":"ff-1","hook_event_name":"PermissionRequest","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo hi"}}' | "$NOTIFY"
sleep 1.5
check "no controls without a waiting client" "$(buttons)" "0"
finish ff-1; sleep 1

echo "== 5. A prompt inferred from a notification offers no controls =="
start note-1
echo '{"session_id":"note-1","hook_event_name":"Notification","cwd":"/tmp","message":"Claude needs your permission to use Bash"}' | "$NOTIFY"
sleep 1.5
check "no controls for a prose-derived prompt" "$(buttons)" "0"
finish note-1; sleep 1

echo "== 6. The terminal answering first withdraws the controls =="
start term-1; rm -f tmp/c6.txt
hold term-1 Bash '{"command":"git push --force origin main"}' tmp/c6.txt
before=$(buttons)
check "controls offered while the prompt is live" "$before" "1"
# Claude Code kills the waiting hook when the human answers in the terminal.
pkill -f "await-decision" >/dev/null 2>&1; sleep 2
check "controls withdrawn once the client is gone" "$(buttons)" "0"
finish term-1; sleep 1

echo "== 7. Two sessions waiting at once resolve independently =="
start pair-a; start pair-b; rm -f tmp/c7a.txt tmp/c7b.txt
hold pair-a Bash '{"command":"terraform apply -auto-approve"}' tmp/c7a.txt
hold pair-b Bash '{"command":"kubectl delete ns staging"}' tmp/c7b.txt
waiting=$(pgrep -f "await-decision" | wc -l | tr -d " ")
check "both prompts are held" "$waiting" "2"
hover; swift Scripts/verify/press.swift press Allow >/dev/null 2>&1; sleep 2
still=$(pgrep -f "await-decision" | wc -l | tr -d " ")
check "answering one leaves the other waiting" "$still" "1"
answered=$(cat tmp/c7a.txt tmp/c7b.txt 2>/dev/null | grep -c behavior)
check "exactly one decision was delivered" "$answered" "1"
pkill -f await-decision; finish pair-a; finish pair-b; sleep 1

echo "== 8. Losing the HUD mid-prompt falls back to the terminal =="
start crash-1; rm -f tmp/c8.txt
hold crash-1 Bash '{"command":"make deploy"}' tmp/c8.txt
pkill -9 -f "dist/ClaudeIsland.app/Contents/MacOS/ClaudeIsland"; sleep 3
gone=$(pgrep -f "await-decision" | wc -l | tr -d " ")
check "the waiting client gives up when the HUD dies" "$gone" "0"
check "and says nothing, so the dialog stands" "$(wc -c < tmp/c8.txt | tr -d ' ')" "0"
open dist/ClaudeIsland.app; sleep 5

echo
echo "$PASS passed, $FAIL failed"
