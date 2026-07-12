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
expect_deny '>/tmp/out pkill -f app'
expect_deny '2>/tmp/e kill -9 -1'
expect_deny '10>/tmp/out pkill -f app'
expect_deny '12>/tmp/e kill -9 -1'
expect_deny '</dev/null killall app'
expect_deny '>/tmp/out sudo pkill -f app'
expect_deny 'sudo killall gamescope'
expect_deny 'sudo -uroot pkill -f app'
expect_deny 'sudo -groot pkill -f app'
expect_deny 'fuser -k 8080/tcp'
expect_deny 'fuser -km 8080/tcp'
expect_deny 'fuser -4k 8080/tcp'
expect_deny 'fuser -6k 8080/tcp'
expect_deny '/usr/bin/time /usr/bin/pkill -f app'
expect_deny 'nice killall app'
expect_deny 'time fuser -km 8080/tcp'
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
expect_deny 'kill 0'
expect_deny 'kill -- 0'
expect_deny 'bash -lc "kill $PID"'
expect_deny '/usr/bin/env kill -9 -1'
expect_deny '/usr/bin/env kill 123'
expect_deny 'exec kill 123'
expect_deny 'exec -a x kill -9 -1'
expect_deny 'exec -afoo kill -9 -1'
expect_deny 'exec -a x pkill -f app'
expect_deny 'builtin kill -9 -1'
expect_deny 'builtin kill -- 0'
expect_deny 'builtin -- kill -9 -1'
expect_deny 'command -p pkill -f app'
expect_deny 'command -p kill -9 -1'
expect_deny 'busybox killall app'
expect_deny 'busybox kill -9 -1'
expect_deny 'busybox fuser -k 8080/tcp'
expect_deny 'toybox killall app'
expect_deny 'toybox kill -9 -1'
expect_deny '/bin/busybox pkill -f app'
expect_deny 'busybox sh -c "pkill -f app"'
expect_deny 'p{kill,} -f app'
expect_deny '{pkill,echo} -f app'
expect_deny '{kill,echo} -9 -1'
expect_deny 'time kill -9 -1'
expect_deny '/usr/bin/time kill -9 -1'
expect_deny 'nohup kill -9 -1'
expect_deny 'setsid kill -9 -1'
expect_deny 'timeout 1 kill -9 -1'
expect_deny 'nice kill -9 -1'
expect_deny '/usr/bin/nice kill -9 -1'
expect_deny 'command nice kill -9 -1'
expect_deny 'sudo nice kill -9 -1'
expect_deny 'if true;then kill -9 -1;fi'
expect_deny 'coproc kill -9 -1'
expect_deny 'coproc /usr/bin/pkill -f app'
expect_deny '{ kill -9 -1; }'
expect_deny '! kill -9 -1'
expect_deny '(kill -9 -1)'
expect_deny $'echo ok\nkill -9 -1'
expect_deny $'echo ok\n/usr/bin/time /usr/bin/pkill -f app'
expect_deny "bash -lc \$'pkill -f app'"
expect_deny "bash -lc \$'\\x70kill -f app'"
expect_deny "bash -lc \$'kill -9 -1'"
expect_deny "bash -lc \$'echo ok\\nkill -9 -1'"
expect_deny 'bash -lc $"pkill -f app"'
expect_deny 'cmd=pkill; $cmd -f app'
expect_deny 'cmd=kill; $cmd -9 -1'
expect_deny '$(printf pkill) -f app'
expect_deny 'printf "pkill -f app" | bash'
expect_deny "printf 'kill -9 -1' | bash"
expect_deny 'bash <<< "kill -9 -1"'
expect_deny 'bash<<<"kill -9 -1"'
expect_deny "0<<<'pkill -f app' bash"
expect_deny 'bash <<EOF
pkill -f app
EOF'
expect_deny '0<<EOF bash
pkill -f app
EOF'
expect_deny 'bash <<EOF; cat
pkill -f app
EOF'
expect_deny '<<EOF bash
pkill -f app
EOF'
expect_deny 'bash <<EOF
echo "$(pkill -f app)"
EOF'
expect_deny 'if true; then bash <<EOF
pkill -f app
EOF
fi'
expect_deny 'if true; then bash <<EOF
echo "$(pkill -f app)"
EOF
fi'
expect_deny "bash -c'kill -9 -1'"
expect_deny "bash -lc'pkill -f app'"
expect_deny "bash --norc -c 'kill -9 -1'"
expect_deny "bash --rcfile /tmp/no-such-rc -c 'pkill -f app'"
expect_deny "bash -O extglob -c 'pkill -f app'"
expect_deny "bash -o pipefail -c 'kill -9 -1'"
expect_deny "bash +O extglob -c 'pkill -f app'"
expect_deny "bash +o pipefail -c 'kill -9 -1'"
expect_deny "/usr/bin/env -S \"bash -c 'kill -9 -1'\""
expect_deny "/usr/bin/env -iS \"bash -c 'pkill -f app'\""
expect_deny "/usr/bin/env --split-string=\"bash -c 'pkill -f app'\""
expect_deny "/usr/bin/env -Sbash -c 'kill -9 -1'"
expect_deny 'echo "$(pkill -f app)"'
expect_deny 'x="$(kill -9 -1)"'
expect_deny 'echo `pkill -f app`'
expect_deny 'printf "%s\n" "`kill -9 -1`"'
expect_deny 'cat <<\EOF
data
EOF
pkill -f app'
expect_deny 'cat <<$'"'EOF'"'
data
EOF
pkill -f app'
expect_deny 'cat <<$"EOF"
data
EOF
pkill -f app'
expect_deny 'bash <<\EOF
pkill -f app
EOF'
expect_deny 'bash <<$'"'EOF'"'
pkill -f app
EOF'
expect_deny 'ps ax | grep gamescope | xargs -0 kill -9'
expect_deny 'printf "%s\0" 123 | xargs -0 kill'
expect_deny 'printf "%s\n" 123 | xargs -I{} kill -9 {}'
expect_deny 'xargs -a /tmp/pids kill -9'
expect_deny 'xargs --arg-file=/tmp/pids kill'

expect_allow 'kill 123'
expect_allow 'kill -9 123 456'
expect_allow 'command kill -TERM -- 789'
expect_allow 'command -p kill -TERM -- 789'
expect_allow 'command -v pkill'
expect_allow 'builtin kill -TERM -- 789'
expect_allow 'builtin -- kill -TERM -- 789'
expect_allow 'busybox kill 123'
expect_allow 'toybox kill -TERM -- 789'
expect_allow 'printf "%s\n" "pkill is documented here"'
expect_allow 'echo p{kill,}'
expect_allow 'printf "%s\n" {pkill,echo}'
expect_allow "printf '%s\n' \$'pkill -f app'"
expect_allow 'echo $"kill -9 -1"'
expect_allow 'echo $(pwd)'
expect_allow 'echo "`pwd`"'
expect_allow 'printf "%s\n" "$(git rev-parse --show-toplevel)"'
expect_allow "printf '%s\n' '\$(pkill -f app)'"
expect_allow 'echo \$\(pkill -f app\)'
expect_allow 'cat <<'"'EOF'"'
pkill -f app
EOF'
expect_allow 'cat <<'"'EOF'"'; bash -c "echo ok"
pkill -f app
EOF'
expect_allow '<<EOF cat
pkill -f app
EOF'
expect_allow '0<<EOF cat
pkill -f app
EOF'
expect_allow 'cat <<'"'EOF'"'
echo "$(pkill -f app)"
EOF'
expect_allow 'cat <<\EOF
pkill -f app
EOF'
expect_allow 'if true; then cat <<'"'EOF'"'
pkill -f app
EOF
fi'
expect_allow 'bash <<EOF
echo ok
EOF'
expect_allow "bash --norc -c 'echo ok'"
expect_allow "bash -O extglob -c 'echo ok'"
expect_allow "bash -o pipefail -c 'echo ok'"
expect_allow "bash +O extglob -c 'echo ok'"
expect_allow "bash +o pipefail -c 'echo ok'"
expect_allow 'git ls-files | xargs wc -l'
expect_allow 'find . -name "*.tmp" -print0 | xargs -0 rm'
expect_allow 'xargs -a /tmp/files wc -l'
expect_allow 'printf "%s\n" hello | xargs'
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
teardown=$(cat "$ROOT/bin/fm-teardown.sh")
for needle in \
  'KILL_SHIMS="$TASK_TMP/killguard-bin"' \
  'PreToolUse' \
  '--dangerously-bypass-hook-trust -c "notify=' \
  '-c __CODEXKILLHOOK__' \
  '"tool.execute.before"' \
  'pi.on("tool_call"' \
  'fm-kill-guard.d' \
  'PATH=$KILL_SHIMS:\$PATH'; do
  assert_contains "$spawn" "$needle" "spawn wiring missing: $needle"
done
assert_not_contains "$spawn" 'cat > "$WT/.codex/hooks.json"' 'codex spawn must not overwrite project hooks.json'
assert_not_contains "$teardown" '.codex/hooks.json' 'teardown must not remove project hooks.json'
pass 'spawn structurally wires every hook-capable adapter and PATH defense'
