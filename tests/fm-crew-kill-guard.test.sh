#!/usr/bin/env bash
# Behavior and spawn-wiring tests for docs/crew-kill-guard.md.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-crew-kill-guard.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-kill-guard.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

expect_allow() {
  local command=$1 status
  "$CHECK" --command "$command" >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "expected allow: $command"
}

expect_deny() {
  local command=$1 out status
  out=$("$CHECK" --command "$command" 2>&1)
  status=$?
  expect_code 2 "$status" "expected deny: $command"
  assert_contains "$out" 'individually verified explicit numeric PIDs owned by this task' "deny omitted ownership rule: $command"
  assert_contains "$out" 'live app, desktop session, and herdr processes are untouchable' "deny omitted protected-process rule: $command"
}

expect_deny 'pkill -9 -f "launch-webdriver"'
expect_deny '/usr/bin/pkill -f tauri-driver'
expect_deny 'sudo killall gamescope'
expect_deny 'fuser -k 8080/tcp'
expect_deny 'fuser -km 8080/tcp'
expect_deny 'bash -lc "/usr/bin/pkill -f app"'
expect_deny '/usr/bin/env /usr/bin/pkill -f app'
expect_deny 'bash -lc "kill $(pgrep app)"'
expect_deny 'eval "/usr/bin/pkill -f app"'
expect_deny 'ps ax | grep gamescope | xargs kill -9'
expect_deny 'kill "$(pgrep -f tauri-driver)"'
expect_deny 'p=$(ps ax | grep app); kill $p'
expect_deny 'for p in $(pgrep foo); do kill "$p"; done'
expect_deny 'kill $PID'
expect_deny 'kill 123 456x'
expect_deny 'kill -9 -1'
expect_deny 'kill -- -123'
expect_deny 'kill -TERM -9 123'
expect_deny 'kill -9 123 -456'

expect_allow 'kill 123'
expect_allow 'kill -9 123 456'
expect_allow 'command kill -TERM -- 789'
expect_allow 'printf "%s\n" "pkill is documented here"'
pass 'command policy denies sweeps and allows only explicit numeric PID kills'

claude_out=$(printf '{"tool_input":{"command":"pkill -f tauri-driver"}}' | "$CHECK" --claude 2>"$TMP_ROOT/claude.err")
claude_status=$?
expect_code 2 "$claude_status" 'Claude transport did not deny'
[ -z "$claude_out" ] || fail 'Claude deny wrote stdout; Claude Code would ignore it'
assert_grep 'permissionDecision":"deny' "$TMP_ROOT/claude.err" 'Claude deny object missing'
pass 'Claude transport denies with empty stdout'

shim="$TMP_ROOT/pkill"
install -m 0700 "$ROOT/bin/fm-crew-kill-shim.sh" "$shim"
shim_out=$(PATH="$TMP_ROOT:$PATH" pkill -f harmless 2>&1)
shim_status=$?
expect_code 126 "$shim_status" 'PATH shim did not refuse'
assert_contains "$shim_out" 'process signaling by pattern or sweep is denied' 'PATH shim refusal was not explanatory'
pass 'PATH shim refuses pattern kill'

spawn=$(cat "$ROOT/bin/fm-spawn.sh")
for needle in \
  'KILL_SHIMS="$TASK_TMP/killguard-bin"' \
  'PreToolUse' \
  '"tool.execute.before"' \
  'pi.on("tool_call"' \
  'fm-kill-guard.d' \
  'PATH=$KILL_SHIMS:\$PATH'; do
  assert_contains "$spawn" "$needle" "spawn wiring missing: $needle"
done
pass 'spawn structurally wires every hook-capable adapter and PATH defense'
