#!/usr/bin/env bash
# Behavior tests for watchdog successor spawning and halt discipline.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-successor-tests)

make_live_tmux_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "display-message -p -t target-pane #{pane_id}") printf '%%1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

LIVE_TMUX_FAKEBIN=$(make_live_tmux_fakebin "$TMP_ROOT/live-tmux")
PATH="$LIVE_TMUX_FAKEBIN:$PATH"
export PATH

write_successor_config() {
  local dir=$1 compact=${2:-90} successor=${3:-95}
  mkdir -p "$dir"
  jq --argjson compact "$compact" --argjson successor "$successor" \
    '.thresholds.compact_at_context_pct = $compact | .thresholds.successor_at_context_pct = $successor | .steer_retries = 1 | .steer_timeout_sec = 5 | .poll_interval_sec = 30' \
    "$ROOT/docs/examples/watchdog.json" > "$dir/watchdog.json"
}

write_codex_rollout() {
  local path=$1 cwd=$2 total=${3:-960} session_id=${4:-watcher-sid}
  mkdir -p "$(dirname "$path")"
  jq -cn --arg cwd "$cwd" --arg session_id "$session_id" '{type:"session_meta",payload:{session_id:$session_id,cwd:$cwd}}' > "$path"
  jq -cn --argjson total "$total" \
    '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:$total},model_context_window:1000},rate_limits:{primary:{used_percent:11},secondary:{used_percent:22}}}}' >> "$path"
}

make_spawn_double() {
  local path=$1 log=$2 status=${3:-0}
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_SUCCESSOR_SPAWN_LOG"
if [ "${FM_SUCCESSOR_DOUBLE_CREATE_META:-0}" = 1 ] && [ "${FM_SUCCESSOR_SPAWN_STATUS:-0}" = 0 ]; then
  mkdir -p "$FM_HOME/state"
  {
    printf 'window=%s\n' "fm-$1"
    printf 'worktree=%s\n' "$2"
    printf 'project=%s\n' "$2"
    printf 'harness=%s\n' "codex"
  } > "$FM_HOME/state/$1.meta"
fi
exit "${FM_SUCCESSOR_SPAWN_STATUS:-0}"
SH
  chmod +x "$path"
  : > "$log"
  export FM_SUCCESSOR_SPAWN_STATUS=$status
}

make_retire_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_SUCCESSOR_RETIRE_LOG"
SH
  chmod +x "$path"
  : > "$log"
}

make_steer_failure_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
exit 9
SH
  chmod +x "$path"
  : > "$log"
}

make_steer_success_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
exit 0
SH
  chmod +x "$path"
  : > "$log"
}

test_successor_spawns_with_handoff_brief_and_retires_predecessor() {
  local home spawn_log retire_log spawn_double retire_double handoff brief event
  home="$TMP_ROOT/success-home"
  spawn_log="$TMP_ROOT/success-spawn.log"
  retire_log="$TMP_ROOT/success-retire.log"
  spawn_double="$TMP_ROOT/success-spawn-double"
  retire_double="$TMP_ROOT/success-retire-double"
  mkdir -p "$home/state" "$home/fm-state"
  handoff="$home/fm-state/handoff-latest.md"
  printf 'Continue from W3 HANDOFF MARKER.\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$home" "worktree=$home" "backend=tmux" "harness=claude" "model=default" "effort=default"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_RETIRE_CMD="$retire_double" \
    FM_SUCCESSOR_RETIRE_LOG="$retire_log" "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null \
    || fail "successor spawn should succeed"

  brief="$home/data/demo-next/brief.md"
  assert_present "$brief" "successor brief should be generated"
  assert_grep "$handoff" "$brief" "successor brief should include handoff path"
  assert_grep "W3 HANDOFF MARKER" "$brief" "successor brief should include handoff content"
  assert_grep "demo-next $home --adopt-worktree --harness claude --backend tmux" "$spawn_log" "spawn double should receive successor args"
  [ "$(cat "$retire_log")" = "tmux|target-pane" ] || fail "predecessor should be retired through backend target"
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"successor_spawn","sid":"demo","status":"started"' "$event" "spawn start event should be logged"
  assert_grep '"type":"predecessor_retired","sid":"demo","status":"closed"' "$event" "retire event should be logged"
  pass "successor spawns with handoff brief and retires predecessor"
}

test_successor_carries_x_followup_link() {
  local home spawn_log retire_log spawn_double retire_double handoff successor_meta
  home="$TMP_ROOT/xlink-home"
  spawn_log="$TMP_ROOT/xlink-spawn.log"
  retire_log="$TMP_ROOT/xlink-retire.log"
  spawn_double="$TMP_ROOT/xlink-spawn-double"
  retire_double="$TMP_ROOT/xlink-retire-double"
  mkdir -p "$home/state" "$home/fm-state"
  handoff="$home/fm-state/handoff-x.md"
  printf 'handoff for X-linked successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" \
    "window=target-pane" "project=$home" "worktree=$home" "backend=tmux" "harness=codex" \
    "x_request=req-123" "x_request_ts=1770000000" "x_followups=2"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-x-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null \
    || fail "X-linked successor spawn should succeed"

  successor_meta="$home/state/demo-x-next.meta"
  assert_grep 'x_request=req-123' "$successor_meta" "successor meta should carry X request id"
  assert_grep 'x_request_ts=1770000000' "$successor_meta" "successor meta should carry original X timestamp"
  assert_grep 'x_followups=2' "$successor_meta" "successor meta should carry consumed follow-up count"
  [ "$(cat "$retire_log")" = "tmux|target-pane" ] || fail "X-linked predecessor should retire after relink"
  pass "successor carries X follow-up link before retiring predecessor"
}

test_spawn_failure_writes_halt_flag_and_failure_artifact() {
  local home spawn_log spawn_double handoff status halt artifact
  home="$TMP_ROOT/failure-home"
  spawn_log="$TMP_ROOT/failure-spawn.log"
  spawn_double="$TMP_ROOT/failure-spawn-double"
  mkdir -p "$home/state" "$home/fm-state"
  handoff="$home/fm-state/handoff-latest.md"
  printf 'handoff for failing spawn\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$home" "worktree=$home" "backend=tmux" "harness=claude"
  make_spawn_double "$spawn_double" "$spawn_log" 23

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-fails FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "failed successor spawn should exit 1"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "failed successor spawn should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_present "$artifact" "failed successor spawn should write failure artifact"
  assert_grep "spawn failed" "$artifact" "failure artifact should explain spawn failure"
  assert_grep '"type":"successor_spawn_failed","sid":"demo","status":"halted"' "$home/fm-state/watchdog.events" "halt event should be logged"
  pass "spawn failure writes halt flag and loud failure artifact"
}

test_watch_loop_clear_rotation_starts_successor_and_exits_when_halted() {
  local home config session_dir worktree steer_log steer_double spawn_log spawn_double handoff generated_handoff pending status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping watcher successor coverage"
    return
  fi
  home="$TMP_ROOT/watch-threshold-home"
  config="$TMP_ROOT/watch-threshold-config"
  session_dir="$TMP_ROOT/watch-threshold-sessions"
  worktree="$TMP_ROOT/watch-threshold-worktree"
  steer_log="$TMP_ROOT/watch-threshold-steer.log"
  steer_double="$TMP_ROOT/watch-threshold-steer-double"
  spawn_log="$TMP_ROOT/watch-threshold-spawn.log"
  spawn_double="$TMP_ROOT/watch-threshold-spawn-double"
  mkdir -p "$home/state" "$home/fm-state" "$worktree"
  handoff="$home/fm-state/handoff-latest.md"
  printf 'threshold handoff\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$worktree" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_successor_config "$config" 90 95
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 960 old-sid
  make_steer_success_double "$steer_double" "$steer_log"
  make_spawn_double "$spawn_double" "$spawn_log" 23

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$steer_double" FM_STEER_DOUBLE_LOG="$steer_log" \
    FM_SUCCESSOR_ID=demo-threshold-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial clear-threshold watcher pass should arm the session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$steer_double" FM_STEER_DOUBLE_LOG="$steer_log" \
    FM_SUCCESSOR_ID=demo-threshold-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "first clear-threshold watcher pass should keep async steering behavior"
  pending="$home/state/watchdog/.clear-pending-demo"
  for _ in $(seq 1 20); do
    [ -s "$pending" ] && break
    sleep 0.1
  done
  assert_present "$pending" "successful clear steer should leave pending marker"
  [ "$(cat "$steer_log")" = "tmux|target-pane|/clear complete current task, then /clear" ] \
    || fail "clear threshold should deliver /clear text"

  sleep 1
  write_codex_rollout "$session_dir/rollout-new.jsonl" "$worktree" 100 new-sid
  "$timeout_cmd" 5 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$steer_double" FM_STEER_DOUBLE_LOG="$steer_log" \
    FM_SUCCESSOR_ID=demo-threshold-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "clear rotation should attempt successor and exit after halt"
  assert_present "$home/fm-state/watchdog.halt" "clear-rotation successor failure should set halt"
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"clear_threshold","sid":"demo","status":"triggered"' "$event" "clear threshold event should be logged"
  assert_grep '"type":"clear_steer_started","sid":"demo"' "$event" "clear steer start event should be logged"
  assert_grep '"type":"clear_rotated","sid":"demo","status":"successor_takeover"' "$event" "clear rotation should be logged"
  assert_grep '"type":"successor_spawn_failed","sid":"demo","status":"halted"' "$event" "spawn failure should halt through watch loop"
  generated_handoff=$(jq -r 'select(.type == "successor_threshold") | .detail | capture("handoff=(?<handoff>[^ ]+)").handoff' "$event" | tail -1)
  [ -n "$generated_handoff" ] || fail "successor threshold event should record the generated handoff"
  [ "$generated_handoff" != "$handoff" ] || fail "successor spawn should consume a unique handoff, not handoff-latest"
  assert_present "$generated_handoff" "unique successor handoff should exist"
  assert_grep "handoff=$generated_handoff" "$home/fm-state/watchdog.halt" "halt flag should record the unique handoff consumed by successor spawn"
  assert_contains "$(cat "$generated_handoff")" "Reason: clear_rotated." "unique successor handoff should name the trigger reason"
  assert_contains "$(cat "$handoff")" "Reason: clear_rotated." "successor handoff should be refreshed for the current trigger"
  if grep -q 'threshold handoff' "$handoff"; then
    fail "successor handoff should not reuse stale content"
  fi
  pass "watch loop clear rotation starts successor and exits when halted"
}

test_steer_rc4_escalates_to_successor() {
  local home config session_dir worktree steer_log steer_double spawn_log spawn_double handoff generated_handoff status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping steer rc4 successor coverage"
    return
  fi
  home="$TMP_ROOT/steer-fail-home"
  config="$TMP_ROOT/steer-fail-config"
  session_dir="$TMP_ROOT/steer-fail-sessions"
  worktree="$TMP_ROOT/steer-fail-worktree"
  steer_log="$TMP_ROOT/steer-fail.log"
  steer_double="$TMP_ROOT/steer-fail-double"
  spawn_log="$TMP_ROOT/steer-successor-spawn.log"
  spawn_double="$TMP_ROOT/steer-successor-spawn-double"
  mkdir -p "$home/state" "$home/fm-state" "$worktree"
  handoff="$home/fm-state/handoff-latest.md"
  printf 'stale successor handoff\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$worktree" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_successor_config "$config" 85 99
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 900 old-sid
  make_steer_failure_double "$steer_double" "$steer_log"
  make_spawn_double "$spawn_double" "$spawn_log" 23

  "$timeout_cmd" 2 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$steer_double" FM_STEER_DOUBLE_LOG="$steer_log" FM_STEER_BACKOFF_SEC=0 \
    FM_SUCCESSOR_ID=demo-steer-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial rc4 watcher pass should arm the session"

  "$timeout_cmd" 2 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$steer_double" FM_STEER_DOUBLE_LOG="$steer_log" FM_STEER_BACKOFF_SEC=0 \
    FM_SUCCESSOR_ID=demo-steer-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "first rc4 watcher pass should keep W2 async steering behavior"
  for _ in $(seq 1 20); do
    [ -s "$home/fm-state/watchdog.halt" ] && break
    sleep 0.1
  done
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"compact_steer_failed","sid":"demo","status":"rc=4"' "$event" "rc4 steer failure should be logged"
  assert_grep 'reason=steer_undeliverable' "$event" "successor event should record steer-undeliverable reason"
  generated_handoff=$(jq -r 'select(.type == "successor_threshold") | .detail | capture("handoff=(?<handoff>[^ ]+)").handoff' "$event" | tail -1)
  [ -n "$generated_handoff" ] || fail "successor threshold event should record the generated handoff"
  [ "$generated_handoff" != "$handoff" ] || fail "rc4 successor spawn should consume a unique handoff, not handoff-latest"
  assert_present "$generated_handoff" "rc4 successor path should create a unique handoff artifact"
  assert_grep "handoff=$generated_handoff" "$home/fm-state/watchdog.halt" "halt flag should record the unique handoff consumed by successor spawn"
  assert_contains "$(cat "$generated_handoff")" "Reason: steer_undeliverable." "unique generated handoff should name the successor reason"
  assert_present "$handoff" "rc4 successor path should create a handoff artifact"
  assert_contains "$(cat "$handoff")" "Reason: steer_undeliverable." "generated handoff should name the successor reason"
  if grep -q 'stale successor handoff' "$handoff"; then
    fail "rc4 successor path should not reuse stale handoff content"
  fi
  assert_present "$home/fm-state/watchdog.halt" "rc4 successor failure should halt the watcher"
  "$timeout_cmd" 2 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$steer_double" FM_STEER_DOUBLE_LOG="$steer_log" FM_STEER_BACKOFF_SEC=0 \
    FM_SUCCESSOR_ID=demo-steer-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "halted watcher pass should exit immediately without another retry"
  pass "steer rc4 escalates to successor and halts on spawn failure"
}

test_successor_spawns_with_handoff_brief_and_retires_predecessor
test_successor_carries_x_followup_link
test_spawn_failure_writes_halt_flag_and_failure_artifact
test_watch_loop_clear_rotation_starts_successor_and_exits_when_halted
test_steer_rc4_escalates_to_successor

echo "# all watchdog successor tests passed"
