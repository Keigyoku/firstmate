#!/usr/bin/env bash
# Behavior tests for backend-aware watchdog steering.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-steer-tests)

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

write_config() {
  local dir=$1 retries=$2
  mkdir -p "$dir"
  jq --argjson retries "$retries" '.steer_retries = $retries' "$ROOT/docs/examples/watchdog.json" > "$dir/watchdog.json"
}

write_fast_threshold_config() {
  local dir=$1
  mkdir -p "$dir"
  jq '.thresholds.compact_at_context_pct = 1 | .steer_retries = 1 | .steer_timeout_sec = 5 | .poll_interval_sec = 30' \
    "$ROOT/docs/examples/watchdog.json" > "$dir/watchdog.json"
}

write_codex_rollout() {
  local path=$1 cwd=$2 total=${3:-900} session_id=${4:-watcher-sid}
  mkdir -p "$(dirname "$path")"
  jq -cn --arg cwd "$cwd" --arg session_id "$session_id" '{type:"session_meta",payload:{session_id:$session_id,cwd:$cwd}}' > "$path"
  jq -cn --argjson total "$total" \
    '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:$total},model_context_window:1000},rate_limits:{primary:{used_percent:11},secondary:{used_percent:22}}}}' >> "$path"
}

append_codex_compaction() {
  local path=$1 generation=$2
  jq -cn --arg generation "$generation" '{type:"compacted",payload:{message:$generation,replacement_history:[]}}' >> "$path"
  jq -cn '{type:"event_msg",payload:{type:"context_compacted"}}' >> "$path"
}

write_claude_jsonl() {
  local path=$1 session_id=$2 compact_uuid=${3:-}
  mkdir -p "$(dirname "$path")"
  jq -cn --arg sid "$session_id" '{type:"user",sessionId:$sid,message:{role:"user",content:"fixture"}}' > "$path"
  if [ -n "$compact_uuid" ]; then
    jq -cn --arg sid "$session_id" --arg uuid "$compact_uuid" \
      '{type:"assistant",sessionId:$sid,isCompactSummary:true,uuid:$uuid,message:{role:"assistant",content:[]}}' >> "$path"
  fi
}

write_claude_checkpoint() {
  local dir=$1 session_id=$2 pct=${3:-50}
  mkdir -p "$dir"
  jq -cn --arg sid "$session_id" --argjson pct "$pct" \
    '{version:1,session_id:$sid,fill_pct:$pct,quality:{tool_calls:2}}' > "$dir/$session_id.json"
}

make_success_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
if [ "${FM_STEER_ASSERT_ACK_EVENT_ABSENT:-}" = 1 ] && [ "$3" = /compact ] \
  && grep -q '"type":"compact_wrap_acknowledged"' "$FM_HOME/fm-state/watchdog.events"; then
  exit 9
fi
exit 0
SH
  chmod +x "$path"
  : > "$log"
}

make_failure_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
exit 9
SH
  chmod +x "$path"
  : > "$log"
}

make_compact_failure_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
[ "$3" != /compact ]
SH
  chmod +x "$path"
  : > "$log"
}

make_sleep_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
sleep 5
exit 0
SH
  chmod +x "$path"
  : > "$log"
}

make_no_timeout_toolbin() {
  local dir=$1 toolbin=$1/notimeoutbin tool real
  mkdir -p "$toolbin"
  for tool in bash env dirname pwd jq grep sed cut tail cat date mktemp mkdir rm readlink rmdir perl sleep basename uname stat ln; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$toolbin/$tool"
  done
  printf '%s\n' "$toolbin"
}

make_missing_tmux_toolbin() {
  local dir=$1 toolbin=$1/missing-tmux-bin real tool
  mkdir -p "$toolbin"
  cat > "$toolbin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_STEER_TMUX_LOG:?}"
exit 1
SH
  chmod +x "$toolbin/tmux"
  for tool in bash env dirname pwd jq grep sed cut tail cat date mktemp mkdir rm readlink rmdir sleep basename uname stat ln; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for target-exists path: $tool"
    ln -s "$real" "$toolbin/$tool"
  done
  printf '%s\n' "$toolbin"
}

make_zellij_label_toolbin() {
  local dir=$1 toolbin=$1/zellij-label-bin
  mkdir -p "$toolbin"
  cat > "$toolbin/zellij" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_STEER_ZELLIJ_LOG:?}"
case "$1" in
  list-sessions) printf 'firstmate\n'; exit 0 ;;
  --session)
    shift 2
    case "$*" in
      "action list-clients") printf '[{"session_name":"firstmate"}]\n'; exit 0 ;;
      "action list-panes --json") printf '[{"id":7,"tab_id":3,"is_plugin":false}]\n'; exit 0 ;;
      "action list-tabs --json") printf '[{"tab_id":3,"name":"fm-demo"}]\n'; exit 0 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$toolbin/zellij"
  printf '%s\n' "$toolbin"
}

test_success_delivers_exact_text_and_event() {
  local home config double log event
  home="$TMP_ROOT/success-home"
  config="$TMP_ROOT/success-config"
  double="$TMP_ROOT/success-double"
  log="$TMP_ROOT/success.log"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "backend=herdr" "harness=claude"
  write_config "$config" 3
  make_success_double "$double" "$log"

  FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" "$ROOT/bin/fm-steer.sh" demo 'complete current task, then /compact' \
    || fail "successful steer should exit 0"

  [ "$(cat "$log")" = "herdr|target-pane|complete current task, then /compact" ] \
    || fail "backend double should receive exact steer text"
  event="$home/fm-state/watchdog.events"
  assert_present "$event" "steer event file should be created under fm-state"
  [ "$(jq -r '.type' "$event")" = steer ] || fail "event type should be steer"
  [ "$(jq -r '.sid' "$event")" = demo ] || fail "event sid should be demo"
  [ "$(jq -r '.status' "$event")" = delivered ] || fail "event status should be delivered"
  pass "steer delivers exact text and writes an append-only event"
}

test_require_target_exists_blocks_delivery() {
  local home config double log tmux_log toolbin status event
  home="$TMP_ROOT/missing-target-home"
  config="$TMP_ROOT/missing-target-config"
  double="$TMP_ROOT/missing-target-double"
  log="$TMP_ROOT/missing-target.log"
  tmux_log="$TMP_ROOT/missing-target-tmux.log"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/demo.meta" "window=missing-pane" "backend=tmux" "harness=claude"
  write_config "$config" 1
  make_success_double "$double" "$log"
  : > "$tmux_log"
  toolbin=$(make_missing_tmux_toolbin "$TMP_ROOT/missing-target-tools")

  PATH="$toolbin" FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_STEER_TMUX_LOG="$tmux_log" FM_STEER_REQUIRE_TARGET_EXISTS=1 \
    "$ROOT/bin/fm-steer.sh" demo 'must not send' >/dev/null 2>&1
  status=$?
  expect_code 4 "$status" "missing scoped target should exit rc 4"
  [ ! -s "$log" ] || fail "delivery double must not run when the target-exists guard fails"
  assert_contains "$(cat "$tmux_log")" 'display-message -p -t missing-pane #{pane_id}' "guard should probe the resolved pane before delivery"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"status":"undeliverable"' "missing target should write an undeliverable steer event"
  assert_contains "$(cat "$event")" 'target_missing=missing-pane' "missing target event should name the target"
  pass "steer target-exists guard blocks delivery before send"
}

test_require_target_exists_uses_task_label_for_zellij() {
  local home config double log zellij_log toolbin
  home="$TMP_ROOT/zellij-label-home"
  config="$TMP_ROOT/zellij-label-config"
  double="$TMP_ROOT/zellij-label-double"
  log="$TMP_ROOT/zellij-label.log"
  zellij_log="$TMP_ROOT/zellij-label-zellij.log"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/demo.meta" "window=firstmate:7" "backend=zellij" "harness=claude"
  write_config "$config" 1
  make_success_double "$double" "$log"
  : > "$zellij_log"
  toolbin=$(make_zellij_label_toolbin "$TMP_ROOT/zellij-label-tools")

  PATH="$toolbin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_STEER_ZELLIJ_LOG="$zellij_log" FM_STEER_REQUIRE_TARGET_EXISTS=1 \
    "$ROOT/bin/fm-steer.sh" demo 'send through zellij' >/dev/null \
    || fail "zellij task-id target-exists guard should accept the matching fm-task label"

  [ "$(cat "$log")" = "zellij|firstmate:7|send through zellij" ] \
    || fail "backend double should receive zellij steer after label-verified guard"
  assert_contains "$(cat "$zellij_log")" "action list-tabs" "zellij guard should verify the tab label"
  pass "steer target-exists guard uses fm-task labels for zellij"
}

test_failure_retries_three_then_rc4() {
  local home config double log status count event
  home="$TMP_ROOT/fail-home"
  config="$TMP_ROOT/fail-config"
  double="$TMP_ROOT/failure-double"
  log="$TMP_ROOT/fail.log"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "backend=tmux" "harness=claude"
  write_config "$config" 3
  make_failure_double "$double" "$log"

  FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_STEER_BACKOFF_SEC=0 \
    "$ROOT/bin/fm-steer.sh" demo 'retry me' >/dev/null 2>&1
  status=$?
  expect_code 4 "$status" "failing steer should exit 4 after configured retries"
  count=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$count" = 3 ] || fail "failing steer should attempt exactly 3 times, got $count"
  event="$home/fm-state/watchdog.events"
  [ "$(jq -r '.status' "$event")" = undeliverable ] || fail "failure event status should be undeliverable"
  pass "steer retries three times before rc 4"
}

test_timeout_bounds_each_attempt() {
  local home config double log status elapsed start finish event
  home="$TMP_ROOT/timeout-home"
  config="$TMP_ROOT/timeout-config"
  double="$TMP_ROOT/timeout-double"
  log="$TMP_ROOT/timeout.log"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "backend=tmux" "harness=claude"
  write_config "$config" 1
  jq '.steer_timeout_sec = 1' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  make_sleep_double "$double" "$log"

  start=$(date +%s)
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_STEER_BACKOFF_SEC=0 \
    "$ROOT/bin/fm-steer.sh" demo 'timeout me' >/dev/null 2>&1
  status=$?
  finish=$(date +%s)
  elapsed=$((finish - start))
  expect_code 4 "$status" "timed-out steer should exit 4"
  [ "$elapsed" -lt 5 ] || fail "steer timeout should stop the sleeping backend command, elapsed ${elapsed}s"
  event="$home/fm-state/watchdog.events"
  [ "$(jq -r '.status' "$event")" = undeliverable ] || fail "timeout event status should be undeliverable"
  pass "steer timeout bounds a stuck backend attempt"
}

test_timeout_uses_perl_when_timeout_tools_are_absent() {
  local home config double log status elapsed start finish event toolbin
  home="$TMP_ROOT/perl-timeout-home"
  config="$TMP_ROOT/perl-timeout-config"
  double="$TMP_ROOT/perl-timeout-double"
  log="$TMP_ROOT/perl-timeout.log"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "backend=tmux" "harness=claude"
  write_config "$config" 1
  jq '.steer_timeout_sec = 1' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  make_sleep_double "$double" "$log"
  toolbin=$(make_no_timeout_toolbin "$TMP_ROOT/perl-timeout")

  start=$SECONDS
  PATH="$toolbin" FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_STEER_BACKOFF_SEC=0 \
    "$ROOT/bin/fm-steer.sh" demo 'timeout me without timeout tools' >/dev/null 2>&1
  status=$?
  finish=$SECONDS
  elapsed=$((finish - start))
  expect_code 4 "$status" "timed-out steer should exit 4 without timeout tools"
  [ "$elapsed" -lt 5 ] || fail "perl fallback did not bound steer delivery (elapsed ${elapsed}s)"
  event="$home/fm-state/watchdog.events"
  [ "$(jq -r '.status' "$event")" = undeliverable ] || fail "perl timeout event status should be undeliverable"
  pass "steer timeout uses perl when timeout tools are absent"
}

test_watcher_starts_compact_steer_without_blocking() {
  local home config session_dir worktree double log status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping watcher async steer coverage"
    return
  fi
  home="$TMP_ROOT/watch-home"
  config="$TMP_ROOT/watch-config"
  session_dir="$TMP_ROOT/watch-sessions"
  worktree="$TMP_ROOT/watch-worktree"
  double="$TMP_ROOT/watch-sleep-double"
  log="$TMP_ROOT/watch-sleep.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree"
  make_sleep_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial watcher pass should arm the discovered session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "watcher should still be sleeping its normal poll when the test timeout stops it"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_wrap_started"' "watcher should record async wrap start before the backend send completes"
  sleep 5
  pass "watcher starts compact steer asynchronously"
}

test_unarmed_session_is_not_steered_on_first_discovery() {
  local home config session_dir worktree double log status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping unarmed-session guard coverage"
    return
  fi
  home="$TMP_ROOT/unarmed-home"
  config="$TMP_ROOT/unarmed-config"
  session_dir="$TMP_ROOT/unarmed-sessions"
  worktree="$TMP_ROOT/unarmed-worktree"
  double="$TMP_ROOT/unarmed-double"
  log="$TMP_ROOT/unarmed.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree"
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "unarmed watcher pass should be stopped by test timeout"
  [ ! -s "$log" ] || fail "unarmed session must not be steered on first discovery"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"watchdog_session_armed"' "unarmed first pass should only arm the session"
  assert_present "$home/state/watchdog/armed-demo" "armed marker should be written for the discovered sid"
  pass "unarmed session is not steered on first discovery"
}

test_rotation_rearms_new_session() {
  local home config session_dir worktree double log pending handled new_sig status event threshold_count timeout_cmd compact_count
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping watcher rotation coverage"
    return
  fi
  home="$TMP_ROOT/rotation-home"
  config="$TMP_ROOT/rotation-config"
  session_dir="$TMP_ROOT/rotation-sessions"
  worktree="$TMP_ROOT/rotation-worktree"
  double="$TMP_ROOT/rotation-double"
  log="$TMP_ROOT/rotation.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  make_success_double "$double" "$log"
  write_codex_rollout "$session_dir/rollout-old.jsonl" "$worktree" 900 old-sid

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial rotation watcher pass should arm the old session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial watcher run should be stopped by test timeout"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "successful compact steer should leave a pending old-session marker"
  [ "$(sed -n '2p' "$pending")" = old-sid ] || fail "pending marker should record the old session id"

  sleep 1
  write_codex_rollout "$session_dir/rollout-new-low.jsonl" "$worktree" 0 new-sid
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "rotation watcher run should be stopped by test timeout"
  handled="$home/state/watchdog/.compact-handled-demo"
  assert_present "$handled" "rotation should move the old session into handled markers"
  [ "$(sed -n '2p' "$handled")" = old-sid ] || fail "handled marker should preserve the old session id"
  new_sig=$(FM_HOME="$home" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    bash -c '. "$1"; file=$(fm_watchdog_session_file codex demo); fm_watchdog_file_identity "$file"' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(sed -n '1p' "$handled")" != "$new_sig" ] || fail "rotation must not mark the new session as handled"
  [ ! -e "$pending" ] || fail "rotation should clear the old pending marker"
  compact_count=$(grep -cF 'tmux|target-pane|/compact' "$log" || true)
  [ "$compact_count" = 0 ] || fail "transcript rotation must cancel pending compact delivery"

  sleep 1
  write_codex_rollout "$session_dir/rollout-new-low.jsonl" "$worktree" 900 new-sid
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "rearmed watcher run should be stopped by test timeout"
  event="$home/fm-state/watchdog.events"
  threshold_count=$(grep -c '"type":"compact_threshold"' "$event")
  [ "$threshold_count" = 2 ] || fail "new session should trigger its own compact threshold, got $threshold_count"
  assert_contains "$(tail -n 1 "$log")" "WATCHDOG WRAP REQUEST" "new session threshold should deliver a second wrap request"
  pass "watcher re-arms compact threshold after transcript rotation"
}

test_same_file_claude_compact_summary_rearms_session() {
  local home config session_dir checkpoint_dir worktree project_dir session_file double log pending handled status event timeout_cmd project_key threshold_count send_count
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping same-file compact rotation coverage"
    return
  fi
  home="$TMP_ROOT/claude-same-file-home"
  config="$TMP_ROOT/claude-same-file-config"
  session_dir="$TMP_ROOT/claude-same-file-sessions"
  checkpoint_dir="$TMP_ROOT/claude-same-file-checkpoints"
  worktree="$TMP_ROOT/claude-same-file-worktree"
  double="$TMP_ROOT/claude-same-file-double"
  log="$TMP_ROOT/claude-same-file.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=claude"
  write_fast_threshold_config "$config"
  project_key=$(bash -c '. "$1"; fm_watchdog_claude_project_key "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$worktree")
  project_dir="$session_dir/$project_key"
  session_file="$project_dir/claude-sid.jsonl"
  write_claude_jsonl "$session_file" claude-sid compact-before
  write_claude_checkpoint "$checkpoint_dir" claude-sid 50
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial same-file watcher pass should arm the Claude session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "same-file watcher pass should steer compact"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "successful compact steer should leave pending marker with compact generation"
  assert_contains "$(cat "$pending")" "compact-before" "pending marker should record the pre-compact summary generation"

  write_claude_jsonl "$session_file" claude-sid compact-after
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "same-file compact summary should be detected on the next pass"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_rotated"' "same-file compact summary should log compact_rotated"
  assert_contains "$(cat "$event")" 'compact_generation=compact-after' "rotation event should name the new compact generation"
  handled="$home/state/watchdog/.compact-handled-demo"
  assert_present "$handled" "same-file compact rotation should write handled marker"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "same generation watcher pass should be stopped by test timeout"
  send_count=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$send_count" = 1 ] || fail "handled same-file compact generation should not steer again, got $send_count sends"
  [ "$(grep -cF 'tmux|target-pane|/compact' "$log" || true)" = 0 ] || fail "auto-compact generation change must cancel pending compact delivery"

  write_claude_checkpoint "$checkpoint_dir" claude-sid 0
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "below-threshold same-file compact pass should be stopped by test timeout"
  [ ! -e "$handled" ] || fail "below-threshold pass should clear handled compact marker"

  write_claude_checkpoint "$checkpoint_dir" claude-sid 50
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$double" \
    FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "same generation after recovery should be stopped by test timeout"
  threshold_count=$(grep -c '"type":"compact_threshold"' "$event")
  [ "$threshold_count" = 2 ] || fail "same compact generation after recovery should trigger another threshold, got $threshold_count"
  send_count=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$send_count" = 2 ] || fail "same compact generation after recovery should steer again, got $send_count sends"
  pass "watcher re-arms after same-file Claude compact summary"
}

test_same_file_codex_compaction_cancels_wrap() {
  local home config session_dir worktree rollout double log pending status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping same-file Codex compact coverage"
    return
  fi
  home="$TMP_ROOT/codex-same-file-home"
  config="$TMP_ROOT/codex-same-file-config"
  session_dir="$TMP_ROOT/codex-same-file-sessions"
  worktree="$TMP_ROOT/codex-same-file-worktree"
  rollout="$session_dir/rollout-demo.jsonl"
  double="$TMP_ROOT/codex-same-file-double"
  log="$TMP_ROOT/codex-same-file.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$rollout" "$worktree" 900 same-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial same-file Codex pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "same-file Codex request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "same-file Codex test should create a pending wrap"
  [ "$(sed -n '3p' "$pending")" = codex:0 ] || fail "pending wrap should record the initial Codex compact generation"
  append_codex_compaction "$rollout" compact-one

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "same-file Codex compaction cancellation should keep polling"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_rotated"' "same-rollout Codex compaction should cancel the pending wrap"
  assert_contains "$(cat "$event")" 'compact_generation=codex:1' "same-rollout Codex event should record the new generation"
  [ "$(grep -cF 'tmux|target-pane|/compact' "$log" || true)" = 0 ] || fail "same-rollout Codex compaction must prevent compact delivery"
  pass "watcher detects same-rollout Codex compaction"
}

test_wrap_ack_delivers_compact() {
  local home config session_dir worktree double log pending ack request message marker_command status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping wrap acknowledgement coverage"
    return
  fi
  home="$TMP_ROOT/wrap-ack-home's"
  config="$TMP_ROOT/wrap-ack-config"
  session_dir="$TMP_ROOT/wrap-ack-sessions"
  worktree="$TMP_ROOT/wrap-ack-worktree"
  double="$TMP_ROOT/wrap-ack-double"
  log="$TMP_ROOT/wrap-ack.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  make_success_double "$double" "$log"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 900 same-sid

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial wrap-ack watcher pass should arm the session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "wrap-request watcher run should be stopped by test timeout"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "successful wrap request should leave a pending marker"
  [ "$(sed -n '6p' "$pending")" = wrap_requested ] || fail "pending marker should wait for wrap acknowledgement"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  message=$(cut -d'|' -f3- "$log")
  assert_contains "$message" "WATCHDOG WRAP REQUEST $request" "delivered wrap should contain its pending token"
  assert_contains "$message" "Complete and land the current unit of work." "delivered wrap should require complete-and-land"
  assert_contains "$message" "Do not run /compact yourself." "delivered wrap should forbid crew-driven compact"
  marker_command=${message#*atomically by running: }
  bash -c "$marker_command" || fail "delivered wrap marker command should execute successfully"
  [ "$(cat "$ack")" = "$request" ] || fail "delivered wrap marker command should atomically write the exact token"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_STEER_ASSERT_ACK_EVENT_ABSENT=1 FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "acknowledged watcher run should be stopped by test timeout"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_wrap_acknowledged"' "matching acknowledgement should be accepted"
  [ "$(tail -n 1 "$log")" = "tmux|target-pane|/compact" ] || fail "matching acknowledgement should deliver only the compact command"
  [ "$(sed -n '6p' "$pending")" = compact_sent ] || fail "pending marker should wait for transcript rotation after compact delivery"
  pass "watcher walks threshold through wrap acknowledgement to compact delivery"
}

test_wrap_ack_timeout_starts_successor() {
  local home config session_dir worktree double log successor successor_log pending ack request status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then timeout_cmd=timeout; elif command -v gtimeout >/dev/null 2>&1; then timeout_cmd=gtimeout; else pass "timeout helper unavailable; skipping wrap timeout coverage"; return; fi
  home="$TMP_ROOT/wrap-timeout-home"
  config="$TMP_ROOT/wrap-timeout-config"
  session_dir="$TMP_ROOT/wrap-timeout-sessions"
  worktree="$TMP_ROOT/wrap-timeout-worktree"
  double="$TMP_ROOT/wrap-timeout-double"
  log="$TMP_ROOT/wrap-timeout.log"
  successor="$TMP_ROOT/wrap-timeout-successor"
  successor_log="$TMP_ROOT/wrap-timeout-successor.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.compact_wrap_ack_timeout_sec = 1' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 900 same-sid
  make_success_double "$double" "$log"
  cat > "$successor" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_SUCCESSOR_LOG"
SH
  chmod +x "$successor"
  : > "$successor_log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial wrap-timeout pass should arm the session"
  "$timeout_cmd" 2 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "wrap-timeout request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "wrap timeout test should create a pending request"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  sleep 2
  printf '%s\n' "$request" > "$ack"
  rm -f "$session_dir/rollout-demo.jsonl"
  fm_write_meta "$home/state/demo.meta" "window=missing-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  jq '.thresholds |= with_entries(.value = null)' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_WATCHDOG_SUCCESSOR_CMD="$successor" FM_SUCCESSOR_LOG="$successor_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "wrap-timeout escalation should keep the watcher polling after successor handoff"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_wrap_timeout"' "expired wrap request should record a timeout"
  [ -s "$successor_log" ] || fail "expired wrap request should enter the successor path"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = 1 ] || fail "expired wrap request must not deliver compact"
  pass "disabled thresholds still expire wrap acknowledgement without blind compact"
}

test_wrap_ack_deadline_starts_after_delivery() {
  local home config session_dir worktree double log pending requested_at delivery_started status timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping wrap delivery deadline coverage"
    return
  fi
  home="$TMP_ROOT/wrap-delivery-deadline-home"
  config="$TMP_ROOT/wrap-delivery-deadline-config"
  session_dir="$TMP_ROOT/wrap-delivery-deadline-sessions"
  worktree="$TMP_ROOT/wrap-delivery-deadline-worktree"
  double="$TMP_ROOT/wrap-delivery-deadline-double"
  log="$TMP_ROOT/wrap-delivery-deadline.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.compact_wrap_ack_timeout_sec = 1' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 900 same-sid
  cat > "$double" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
case "$3" in WATCHDOG\ WRAP\ REQUEST*) sleep 2 ;; esac
exit 0
SH
  chmod +x "$double"
  : > "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial wrap delivery deadline pass should arm the session"
  delivery_started=$(date -u +%s)
  "$timeout_cmd" 4 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "slow wrap delivery should keep polling after delivery"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "slow successful wrap delivery should create a pending request"
  requested_at=$(sed -n '5p' "$pending")
  [ "$requested_at" -ge $((delivery_started + 2)) ] || fail "acknowledgement deadline should start after slow wrap delivery succeeds"
  pass "wrap acknowledgement deadline starts after delivery"
}

test_compact_delivery_does_not_retry_across_rotation() {
  local home config session_dir worktree double log pending ack request successor successor_log status event compact_count timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping compact retry rotation coverage"
    return
  fi
  home="$TMP_ROOT/compact-retry-rotation-home"
  config="$TMP_ROOT/compact-retry-rotation-config"
  session_dir="$TMP_ROOT/compact-retry-rotation-sessions"
  worktree="$TMP_ROOT/compact-retry-rotation-worktree"
  double="$TMP_ROOT/compact-retry-rotation-double"
  log="$TMP_ROOT/compact-retry-rotation.log"
  successor="$TMP_ROOT/compact-retry-rotation-successor"
  successor_log="$TMP_ROOT/compact-retry-rotation-successor.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.steer_retries = 3' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  write_codex_rollout "$session_dir/rollout-old.jsonl" "$worktree" 900 old-sid
  cat > "$double" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
if [ "$3" = /compact ]; then
  sleep 1
  jq -cn --arg cwd "$FM_RETRY_WORKTREE" '{type:"session_meta",payload:{session_id:"new-sid",cwd:$cwd}}' > "$FM_RETRY_SESSION_DIR/rollout-new.jsonl"
  jq -cn '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:0},model_context_window:1000}}}' >> "$FM_RETRY_SESSION_DIR/rollout-new.jsonl"
  exit 9
fi
exit 0
SH
  chmod +x "$double"
  : > "$log"
  cat > "$successor" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_SUCCESSOR_LOG"
SH
  chmod +x "$successor"
  : > "$successor_log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial compact retry rotation pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "compact retry rotation request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  printf '%s\n' "$request" > "$ack"

  "$timeout_cmd" 4 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_STEER_BACKOFF_SEC=0 FM_WATCHDOG_SUCCESSOR_CMD="$successor" FM_SUCCESSOR_LOG="$successor_log" FM_RETRY_SESSION_DIR="$session_dir" FM_RETRY_WORKTREE="$worktree" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "ambiguous compact delivery should keep polling after rotation cancellation"
  compact_count=$(grep -cF 'tmux|target-pane|/compact' "$log" || true)
  [ "$compact_count" = 1 ] || fail "compact delivery must make exactly one attempt across rotation, got $compact_count"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_rotated"' "rotation after an ambiguous compact attempt should cancel delivery"
  [ ! -s "$successor_log" ] || fail "rotation after an ambiguous compact attempt should not start a successor"
  pass "compact delivery does not retry across rotation"
}

test_wrap_rotation_wins_expired_deadline() {
  local home config session_dir worktree double log successor successor_log pending status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping expired rotation coverage"
    return
  fi
  home="$TMP_ROOT/wrap-expired-rotation-home"
  config="$TMP_ROOT/wrap-expired-rotation-config"
  session_dir="$TMP_ROOT/wrap-expired-rotation-sessions"
  worktree="$TMP_ROOT/wrap-expired-rotation-worktree"
  double="$TMP_ROOT/wrap-expired-rotation-double"
  log="$TMP_ROOT/wrap-expired-rotation.log"
  successor="$TMP_ROOT/wrap-expired-rotation-successor"
  successor_log="$TMP_ROOT/wrap-expired-rotation-successor.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.compact_wrap_ack_timeout_sec = 1' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  write_codex_rollout "$session_dir/rollout-old.jsonl" "$worktree" 900 old-sid
  make_success_double "$double" "$log"
  cat > "$successor" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_SUCCESSOR_LOG"
SH
  chmod +x "$successor"
  : > "$successor_log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial expired rotation pass should arm the session"
  "$timeout_cmd" 2 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "expired rotation request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "expired rotation test should create a pending request"
  sleep 2
  write_codex_rollout "$session_dir/rollout-new.jsonl" "$worktree" 0 new-sid

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_WATCHDOG_SUCCESSOR_CMD="$successor" FM_SUCCESSOR_LOG="$successor_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "expired rotation cancellation should keep polling"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_rotated"' "observable rotation should cancel an expired wrap"
  [ "$(grep -c '"type":"compact_wrap_timeout"' "$event" || true)" = 0 ] || fail "observable rotation should win over timeout escalation"
  [ ! -s "$successor_log" ] || fail "observable rotation should not start a successor for the stale request"
  [ "$(grep -cF 'tmux|target-pane|/compact' "$log" || true)" = 0 ] || fail "observable rotation should not deliver compact"
  pass "transcript rotation wins over an expired wrap deadline"
}

test_wrap_ack_revalidates_at_backend_send() {
  local home config session_dir worktree rollout double log pending ack request compact status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping pre-delivery rotation coverage"
    return
  fi
  home="$TMP_ROOT/wrap-race-home"
  config="$TMP_ROOT/wrap-race-config"
  session_dir="$TMP_ROOT/wrap-race-sessions"
  worktree="$TMP_ROOT/wrap-race-worktree"
  double="$TMP_ROOT/wrap-race-double"
  log="$TMP_ROOT/wrap-race.log"
  rollout="$session_dir/rollout-demo.jsonl"
  compact="$TMP_ROOT/wrap-race-compact"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  make_success_double "$double" "$log"
  write_codex_rollout "$rollout" "$worktree" 900 old-sid
  cat > "$compact" <<'SH'
#!/usr/bin/env bash
jq -cn '{type:"compacted",payload:{message:"setup-gap",replacement_history:[]}}' >> "$FM_RACE_ROLLOUT"
jq -cn '{type:"event_msg",payload:{type:"context_compacted"}}' >> "$FM_RACE_ROLLOUT"
SH
  chmod +x "$compact"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial pre-delivery rotation pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "pre-delivery rotation request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  printf '%s\n' "$request" > "$ack"

  "$timeout_cmd" 3 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_STEER_BEFORE_DELIVERY_ATTEMPT_CMD="$compact" FM_RACE_ROLLOUT="$rollout" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "pre-delivery rotation cancellation should keep polling"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_rotated"' "same-rollout compaction during steer setup should cancel the pending compact"
  [ "$(grep -cF 'tmux|target-pane|/compact' "$log" || true)" = 0 ] || fail "backend-send guard must prevent compact after setup-gap compaction"
  pass "watcher revalidates Codex generation at backend send"
}

test_wrap_ack_partial_codex_tail_fails_closed() {
  local home config session_dir worktree rollout double log pending ack request partial status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping partial Codex tail coverage"
    return
  fi
  home="$TMP_ROOT/wrap-partial-tail-home"
  config="$TMP_ROOT/wrap-partial-tail-config"
  session_dir="$TMP_ROOT/wrap-partial-tail-sessions"
  worktree="$TMP_ROOT/wrap-partial-tail-worktree"
  rollout="$session_dir/rollout-demo.jsonl"
  double="$TMP_ROOT/wrap-partial-tail-double"
  log="$TMP_ROOT/wrap-partial-tail.log"
  partial="$TMP_ROOT/wrap-partial-tail-append"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  make_success_double "$double" "$log"
  write_codex_rollout "$rollout" "$worktree" 900 old-sid
  cat > "$partial" <<'SH'
#!/usr/bin/env bash
printf '%s' '{"type":"compacted"' >> "$FM_PARTIAL_ROLLOUT"
SH
  chmod +x "$partial"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial partial-tail pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "partial-tail request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  printf '%s\n' "$request" > "$ack"

  "$timeout_cmd" 3 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_STEER_BEFORE_DELIVERY_ATTEMPT_CMD="$partial" FM_PARTIAL_ROLLOUT="$rollout" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "partial-tail guarded delivery should keep polling"
  [ "$(grep -cF 'tmux|target-pane|/compact' "$log" || true)" = 0 ] || fail "partial Codex tail must prevent compact delivery"
  [ "$(sed -n '6p' "$pending")" = wrap_requested ] || fail "partial Codex tail should leave the wrap pending"
  [ "$(cat "$ack")" = "$request" ] || fail "partial Codex tail should preserve the matching acknowledgement"
  event="$home/fm-state/watchdog.events"
  [ "$(grep -c '"type":"compact_wrap_acknowledged"' "$event" || true)" = 0 ] || fail "partial Codex tail must not acknowledge compact delivery"
  pass "partial Codex rollout tails fail closed"
}

test_transient_generation_unavailable_restores_bounded_wrap() {
  local home config session_dir worktree rollout double log pending ack request fakebin jq_count successor successor_log status event timeout_cmd real_jq
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping transient generation coverage"
    return
  fi
  home="$TMP_ROOT/transient-generation-home"
  config="$TMP_ROOT/transient-generation-config"
  session_dir="$TMP_ROOT/transient-generation-sessions"
  worktree="$TMP_ROOT/transient-generation-worktree"
  rollout="$session_dir/rollout-demo.jsonl"
  double="$TMP_ROOT/transient-generation-double"
  log="$TMP_ROOT/transient-generation.log"
  fakebin="$TMP_ROOT/transient-generation-fakebin"
  jq_count="$TMP_ROOT/transient-generation-jq-count"
  successor="$TMP_ROOT/transient-generation-successor"
  successor_log="$TMP_ROOT/transient-generation-successor.log"
  mkdir -p "$home/state" "$worktree" "$fakebin"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.compact_wrap_ack_timeout_sec = 5' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  write_codex_rollout "$rollout" "$worktree" 900 same-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial transient generation pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "transient generation request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  printf '%s\n' "$request" > "$ack"
  jq '.thresholds |= with_entries(.value = null)' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"

  real_jq=$(command -v jq)
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TRANSIENT_ROLLOUT" ]; then
  case "$*" in
    *'select(.type == "compacted")'*)
      count=$(cat "$FM_TRANSIENT_JQ_COUNT" 2>/dev/null || printf '0\n')
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_TRANSIENT_JQ_COUNT"
      if [ "$count" -eq 2 ]; then
        output=$("$FM_REAL_JQ" "$@")
        rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
        printf '%s' '{"type":"compacted"' >> "$FM_TRANSIENT_ROLLOUT"
        printf '%s\n' "$output"
        exit 0
      fi
      ;;
  esac
fi
exec "$FM_REAL_JQ" "$@"
SH
  chmod +x "$fakebin/jq"
  cat > "$successor" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_SUCCESSOR_LOG"
SH
  chmod +x "$successor"
  : > "$successor_log"

  "$timeout_cmd" 1 env PATH="$fakebin:$PATH" FM_REAL_JQ="$real_jq" FM_TRANSIENT_ROLLOUT="$rollout" FM_TRANSIENT_JQ_COUNT="$jq_count" FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 bash -e "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "transient generation failure should keep polling"
  [ "$(sed -n '6p' "$pending")" = wrap_requested ] || fail "transient generation failure should restore the bounded wrap phase"
  [ "$(cat "$ack")" = "$request" ] || fail "transient generation failure should preserve the matching acknowledgement"
  [ "$(grep -cF 'tmux|target-pane|/compact' "$log" || true)" = 0 ] || fail "transient generation failure must prevent compact delivery"
  sleep 6

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_WATCHDOG_SUCCESSOR_CMD="$successor" FM_SUCCESSOR_LOG="$successor_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "transient generation timeout should keep polling after successor handoff"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_wrap_timeout"' "restored wrap should retain bounded timeout handling"
  [ -s "$successor_log" ] || fail "restored wrap should enter the successor path after expiry"
  pass "transient unavailable generation restores bounded wrap recovery"
}

test_ambiguous_compact_tracks_delayed_generation() {
  local home config session_dir worktree rollout double log pending ack request status event compact_count wrap_count timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping delayed compact generation coverage"
    return
  fi
  home="$TMP_ROOT/compact-delayed-generation-home"
  config="$TMP_ROOT/compact-delayed-generation-config"
  session_dir="$TMP_ROOT/compact-delayed-generation-sessions"
  worktree="$TMP_ROOT/compact-delayed-generation-worktree"
  rollout="$session_dir/rollout-demo.jsonl"
  double="$TMP_ROOT/compact-delayed-generation-double"
  log="$TMP_ROOT/compact-delayed-generation.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$rollout" "$worktree" 900 same-sid
  make_compact_failure_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial delayed generation pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "delayed generation request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  printf '%s\n' "$request" > "$ack"

  "$timeout_cmd" 2 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "ambiguous compact attempt should keep polling"
  [ "$(sed -n '6p' "$pending")" = compact_ambiguous ] || fail "ambiguous compact attempt should preserve pending rotation proof"
  assert_present "$ack" "ambiguous compact attempt should preserve its acknowledgement"
  append_codex_compaction "$rollout" delayed-generation

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "delayed compact generation should be marked handled"
  [ ! -e "$pending" ] || fail "delayed compact generation should clear ambiguous pending state"
  [ ! -e "$ack" ] || fail "delayed compact generation should clear its acknowledgement"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" 'compact_generation=codex:1' "delayed compact generation should be recorded as handled"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "handled delayed generation should keep polling without another wrap"
  compact_count=$(grep -cF 'tmux|target-pane|/compact' "$log" || true)
  wrap_count=$(grep -c 'WATCHDOG WRAP REQUEST' "$log" || true)
  [ "$compact_count" = 1 ] || fail "delayed compact generation must not trigger a second compact, got $compact_count"
  [ "$wrap_count" = 1 ] || fail "delayed compact generation must not trigger another wrap, got $wrap_count"
  pass "ambiguous compact tracks and handles delayed generation"
}

test_ambiguous_compact_timeout_starts_successor() {
  local home config session_dir worktree double log pending ack request successor successor_log status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping ambiguous compact timeout coverage"
    return
  fi
  home="$TMP_ROOT/compact-ambiguous-timeout-home"
  config="$TMP_ROOT/compact-ambiguous-timeout-config"
  session_dir="$TMP_ROOT/compact-ambiguous-timeout-sessions"
  worktree="$TMP_ROOT/compact-ambiguous-timeout-worktree"
  double="$TMP_ROOT/compact-ambiguous-timeout-double"
  log="$TMP_ROOT/compact-ambiguous-timeout.log"
  successor="$TMP_ROOT/compact-ambiguous-timeout-successor"
  successor_log="$TMP_ROOT/compact-ambiguous-timeout-successor.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.compact_wrap_ack_timeout_sec = 3' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 900 same-sid
  make_compact_failure_double "$double" "$log"
  cat > "$successor" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_SUCCESSOR_LOG"
SH
  chmod +x "$successor"
  : > "$successor_log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial ambiguous timeout pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "ambiguous timeout request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  printf '%s\n' "$request" > "$ack"
  "$timeout_cmd" 2 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "ambiguous timeout attempt should keep polling"
  [ "$(sed -n '6p' "$pending")" = compact_ambiguous ] || fail "failed compact should enter ambiguous recovery"
  sleep 4

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_WATCHDOG_SUCCESSOR_CMD="$successor" FM_SUCCESSOR_LOG="$successor_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "ambiguous compact timeout should keep polling after successor handoff"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_ambiguous_timeout"' "ambiguous compact should record bounded timeout"
  [ -s "$successor_log" ] || fail "ambiguous compact timeout should start successor handoff"
  [ "$(grep -cF 'tmux|target-pane|/compact' "$log" || true)" = 1 ] || fail "ambiguous recovery must never retry compact"
  pass "ambiguous compact recovery expires into successor"
}

test_successful_compact_tracks_delayed_generation() {
  local home config session_dir worktree rollout double log pending ack request successor successor_log status event compact_count wrap_count timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping successful delayed generation coverage"
    return
  fi
  home="$TMP_ROOT/compact-success-delayed-generation-home"
  config="$TMP_ROOT/compact-success-delayed-generation-config"
  session_dir="$TMP_ROOT/compact-success-delayed-generation-sessions"
  worktree="$TMP_ROOT/compact-success-delayed-generation-worktree"
  rollout="$session_dir/rollout-demo.jsonl"
  double="$TMP_ROOT/compact-success-delayed-generation-double"
  log="$TMP_ROOT/compact-success-delayed-generation.log"
  successor="$TMP_ROOT/compact-success-delayed-generation-successor"
  successor_log="$TMP_ROOT/compact-success-delayed-generation-successor.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.compact_pending_retry_sec = 1 | .compact_wrap_ack_timeout_sec = 5' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  write_codex_rollout "$rollout" "$worktree" 900 same-sid
  make_success_double "$double" "$log"
  cat > "$successor" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$FM_SUCCESSOR_LOG"
SH
  chmod +x "$successor"
  : > "$successor_log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial successful delayed generation pass should arm the session"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "successful delayed generation request pass should keep polling"
  pending="$home/state/watchdog/.compact-pending-demo"
  request=$(sed -n '4p' "$pending")
  ack="$home/state/watchdog/.compact-wrap-ack-demo"
  printf '%s\n' "$request" > "$ack"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "successful compact attempt should keep polling"
  [ "$(sed -n '6p' "$pending")" = compact_sent ] || fail "successful compact should preserve pending rotation proof"
  sleep 3

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "successful compact proof should survive generic pending expiry"
  [ "$(sed -n '6p' "$pending")" = compact_sent ] || fail "successful compact proof must not use generic pending expiry"
  sleep 2

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_WATCHDOG_SUCCESSOR_CMD="$successor" FM_SUCCESSOR_LOG="$successor_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "successful compact recovery should enter successor handoff"
  [ "$(sed -n '6p' "$pending")" = compact_successor ] || fail "successful compact successor handoff should retain rotation proof"
  [ -s "$successor_log" ] || fail "successful compact recovery timeout should start successor handoff"
  append_codex_compaction "$rollout" delayed-success-generation

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "delayed successful compact generation should be marked handled"
  [ ! -e "$pending" ] || fail "delayed successful compact generation should clear pending proof"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" 'compact_generation=codex:1' "delayed successful compact generation should be recorded as handled"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "handled successful generation should keep polling without another wrap"
  compact_count=$(grep -cF 'tmux|target-pane|/compact' "$log" || true)
  wrap_count=$(grep -c 'WATCHDOG WRAP REQUEST' "$log" || true)
  [ "$compact_count" = 1 ] || fail "delayed successful generation must not trigger a second compact, got $compact_count"
  [ "$wrap_count" = 1 ] || fail "delayed successful generation must not trigger another wrap, got $wrap_count"
  pass "successful compact tracks and handles delayed generation"
}

test_metrics_collection_failure_is_visible_and_throttled() {
  local home config session_dir worktree status event failure_count timeout_cmd fakebin find_log real_find
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping metrics failure visibility coverage"
    return
  fi
  home="$TMP_ROOT/metrics-failure-home"
  config="$TMP_ROOT/metrics-failure-config"
  session_dir="$TMP_ROOT/metrics-failure-sessions"
  worktree="$TMP_ROOT/metrics-failure-worktree"
  fakebin="$TMP_ROOT/metrics-failure-fakebin"
  find_log="$TMP_ROOT/metrics-failure-find.log"
  real_find=$(command -v find)
  mkdir -p "$home/state" "$session_dir" "$worktree" "$fakebin"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.metrics_failure_event_interval_sec = 60' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "metrics failure watcher run should be stopped by test timeout"
  event="$home/fm-state/watchdog.events"
  assert_present "$event" "metrics collection failure should write a watchdog event"
  assert_contains "$(cat "$event")" '"type":"metrics_collect_failed"' "metrics failure event should name collection failure"
  assert_contains "$(cat "$event")" 'no codex session file found for demo' "metrics failure detail should include scoped session lookup stderr"

  cat > "$fakebin/find" <<'SH'
#!/usr/bin/env bash
printf 'find called\n' >> "$FM_FIND_LOG"
exec "$REAL_FIND" "$@"
SH
  chmod +x "$fakebin/find"
  "$timeout_cmd" 1 env PATH="$fakebin:$PATH" FM_FIND_LOG="$find_log" REAL_FIND="$real_find" \
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "throttled metrics failure watcher run should be stopped by test timeout"
  failure_count=$(grep -c '"type":"metrics_collect_failed"' "$event")
  [ "$failure_count" = 1 ] || fail "metrics failure event should be throttled, got $failure_count events"
  assert_absent "$find_log" "throttled metrics failure should skip repeated rollout scans"
  pass "watcher reports metrics collection failures with throttling"
}

test_unsupported_harness_skips_watchdog_metrics() {
  local home config worktree status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping unsupported harness coverage"
    return
  fi
  home="$TMP_ROOT/unsupported-harness-home"
  config="$TMP_ROOT/unsupported-harness-config"
  worktree="$TMP_ROOT/unsupported-harness-worktree"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=opencode"
  write_fast_threshold_config "$config"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "unsupported harness watcher run should be stopped by test timeout"
  event="$home/fm-state/watchdog.events"
  if [ -e "$event" ] && grep -q '"type":"metrics_collect_failed"' "$event"; then
    fail "unsupported harness should not emit metrics collection failures"
  fi
  pass "watcher skips unsupported harness metrics"
}

test_stale_meta_skips_watchdog_threshold_scan() {
  local home config session_dir worktree fakebin status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping stale-meta coverage"
    return
  fi
  home="$TMP_ROOT/stale-meta-home"
  config="$TMP_ROOT/stale-meta-config"
  session_dir="$TMP_ROOT/stale-meta-sessions"
  worktree="$TMP_ROOT/stale-meta-worktree"
  fakebin=$(fm_fakebin "$TMP_ROOT/stale-meta-fakebin")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tmux"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=retired-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 900 same-sid

  PATH="$fakebin:$PATH" "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "stale-meta watcher run should be stopped by test timeout"
  event="$home/fm-state/watchdog.events"
  if [ -e "$event" ] && grep -Eq '"type":"(watchdog_session_armed|compact_threshold|clear_threshold|metrics_collect_failed)"' "$event"; then
    fail "stale meta with a missing backend target should not reach metrics threshold processing"
  fi
  pass "watcher skips stale meta records with missing backend targets"
}

test_resident_rotation_lock_blocks_compact_steer() {
  local home config session_dir worktree double log status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping resident-rotation lock coverage"
    return
  fi
  home="$TMP_ROOT/resident-lock-home"
  config="$TMP_ROOT/resident-lock-config"
  session_dir="$TMP_ROOT/resident-lock-sessions"
  worktree="$TMP_ROOT/resident-lock-worktree"
  double="$TMP_ROOT/resident-lock-double"
  log="$TMP_ROOT/resident-lock.log"
  mkdir -p "$home/state/watchdog" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 0 armed-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial resident-lock watcher pass should arm the session"

  sleep 1
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 900 armed-sid
  mkdir "$home/state/watchdog/.resident-rotation-demo"
  printf '%s\n' "$$" > "$home/state/watchdog/.resident-rotation-demo/pid"
  printf 'manual\n' > "$home/state/watchdog/.resident-rotation-demo/owner"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "resident-lock watcher pass should keep polling"
  [ ! -s "$log" ] || fail "resident rotation lock should block compact steer delivery"
  event="$home/fm-state/watchdog.events"
  if [ -e "$event" ] && grep -q '"type":"compact_threshold"' "$event"; then
    fail "resident rotation lock should block compact threshold processing"
  fi
  pass "resident rotation lock blocks compact steer threshold work"
}

test_provisional_resident_rotation_lock_blocks_compact_steer() {
  local home config session_dir worktree double log status event timeout_cmd lock contents
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping provisional resident-rotation lock coverage"
    return
  fi
  home="$TMP_ROOT/provisional-resident-lock-home"
  config="$TMP_ROOT/provisional-resident-lock-config"
  session_dir="$TMP_ROOT/provisional-resident-lock-sessions"
  worktree="$TMP_ROOT/provisional-resident-lock-worktree"
  double="$TMP_ROOT/provisional-resident-lock-double"
  log="$TMP_ROOT/provisional-resident-lock.log"
  lock="$home/state/watchdog/.resident-rotation-demo"
  mkdir -p "$home/state/watchdog" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 0 armed-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial provisional resident-lock watcher pass should arm the session"

  sleep 1
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 900 armed-sid
  mkdir "$lock"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "provisional resident-lock watcher pass should keep polling"
  [ ! -s "$log" ] || fail "provisional resident rotation lock should block compact steer delivery"
  [ -d "$lock" ] || fail "provisional resident rotation lock should not be removed before stale age"
  contents=$(find "$lock" -mindepth 1 -maxdepth 1 -print)
  [ -z "$contents" ] || fail "provisional resident rotation lock should not be claimed by watcher"
  event="$home/fm-state/watchdog.events"
  if [ -e "$event" ] && grep -q '"type":"compact_threshold"' "$event"; then
    fail "provisional resident rotation lock should block compact threshold processing"
  fi
  pass "provisional resident rotation lock blocks compact steer threshold work"
}

test_resident_rotation_lock_blocks_compact_after_metrics() {
  local home config session_dir worktree double log status event timeout_cmd fakebin real_jq
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping resident-rotation recheck coverage"
    return
  fi
  real_jq=$(command -v jq)
  home="$TMP_ROOT/resident-lock-recheck-home"
  config="$TMP_ROOT/resident-lock-recheck-config"
  session_dir="$TMP_ROOT/resident-lock-recheck-sessions"
  worktree="$TMP_ROOT/resident-lock-recheck-worktree"
  double="$TMP_ROOT/resident-lock-recheck-double"
  log="$TMP_ROOT/resident-lock-recheck.log"
  fakebin=$(fm_fakebin "$TMP_ROOT/resident-lock-recheck-bin")
  mkdir -p "$home/state/watchdog" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 0 armed-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial resident-lock recheck watcher pass should arm the session"

  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'.context_pct // empty'*)
    mkdir -p "$home/state/watchdog"
    mkdir "$home/state/watchdog/.resident-rotation-demo" 2>/dev/null || true
    printf '%s\n' "$$" > "$home/state/watchdog/.resident-rotation-demo/pid"
    printf 'manual\n' > "$home/state/watchdog/.resident-rotation-demo/owner"
    ;;
esac
exec "$real_jq" "\$@"
SH
  chmod +x "$fakebin/jq"
  sleep 1
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 900 armed-sid
  PATH="$fakebin:$PATH" "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "resident-lock recheck watcher pass should keep polling"
  [ ! -s "$log" ] || fail "resident rotation lock created after metrics should block compact steer delivery"
  event="$home/fm-state/watchdog.events"
  if [ -e "$event" ] && grep -q '"type":"compact_threshold"' "$event"; then
    fail "resident rotation lock created after metrics should block compact threshold event"
  fi
  pass "resident rotation lock recheck blocks compact threshold work"
}

test_fast_steer_completion_does_not_exit_watcher() {
  local home config session_dir worktree double log status event timeout_cmd hook pending
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping fast resident-rotation handoff coverage"
    return
  fi
  home="$TMP_ROOT/fast-steer-completion-home"
  config="$TMP_ROOT/fast-steer-completion-config"
  session_dir="$TMP_ROOT/fast-steer-completion-sessions"
  worktree="$TMP_ROOT/fast-steer-completion-worktree"
  double="$TMP_ROOT/fast-steer-completion-double"
  log="$TMP_ROOT/fast-steer-completion.log"
  hook="$TMP_ROOT/fast-steer-completion-hook"
  pending="$home/state/watchdog/.compact-pending-demo"
  mkdir -p "$home/state/watchdog" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 0 armed-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial fast-steer watcher pass should arm the session"

  cat > "$hook" <<'SH'
#!/usr/bin/env bash
lock="$FM_HOME/state/watchdog/.resident-rotation-demo"
i=0
while [ -d "$lock" ] && [ "$i" -lt 200 ]; do
  i=$((i + 1))
  sleep 0.01
done
exit 0
SH
  chmod +x "$hook"
  sleep 1
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 900 armed-sid
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_WATCHDOG_BEFORE_ROTATION_SET_PID="$hook" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "fast completed steer should not make watcher exit through set -e"
  [ -s "$pending" ] || fail "fast completed steer should still write compact pending marker"
  [ ! -e "$home/state/watchdog/.compact-steering-demo" ] || fail "fast completed steer should not leave a stale steering marker"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_threshold"' "fast completed steer should record threshold event"
  pass "fast completed compact steer handoff does not exit watcher"
}

test_fast_steer_handoff_does_not_corrupt_reacquired_lock() {
  local home config session_dir worktree double log status timeout_cmd hook hook_log lock child_pid
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping resident-rotation ABA coverage"
    return
  fi
  home="$TMP_ROOT/fast-steer-aba-home"
  config="$TMP_ROOT/fast-steer-aba-config"
  session_dir="$TMP_ROOT/fast-steer-aba-sessions"
  worktree="$TMP_ROOT/fast-steer-aba-worktree"
  double="$TMP_ROOT/fast-steer-aba-double"
  log="$TMP_ROOT/fast-steer-aba.log"
  hook="$TMP_ROOT/fast-steer-aba-hook"
  hook_log="$TMP_ROOT/fast-steer-aba-hook.log"
  lock="$home/state/watchdog/.resident-rotation-demo"
  mkdir -p "$home/state/watchdog" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 0 armed-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial ABA watcher pass should arm the session"

  cat > "$hook" <<'SH'
#!/usr/bin/env bash
lock="$FM_HOME/state/watchdog/.resident-rotation-demo"
printf '%s\n%s\n' "$2" "$3" > "$FM_TEST_ABA_HOOK_LOG"
i=0
while [ -d "$lock" ] && [ "$i" -lt 200 ]; do
  i=$((i + 1))
  sleep 0.01
done
mkdir "$lock"
printf '%s\n' "$$" > "$lock/pid"
printf 'manual\n' > "$lock/owner"
printf 'replacement-token\n' > "$lock/token"
date -u +%Y-%m-%dT%H:%M:%SZ > "$lock/created_at"
SH
  chmod +x "$hook"
  sleep 1
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 900 armed-sid
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_WATCHDOG_BEFORE_ROTATION_SET_PID="$hook" \
    FM_TEST_ABA_HOOK_LOG="$hook_log" FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "ABA watcher pass should keep polling"
  child_pid=$(sed -n '1p' "$hook_log")
  [ "$(sed -n '1p' "$lock/token")" = replacement-token ] || fail "old rotation claim corrupted replacement token"
  [ "$(sed -n '1p' "$lock/pid")" != "$child_pid" ] || fail "old rotation claim corrupted replacement pid"
  pass "fast steer handoff cannot corrupt a reacquired rotation lock"
}

test_stale_resident_rotation_lock_allows_compact_steer() {
  local home config session_dir worktree double log status event timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping stale resident-rotation lock coverage"
    return
  fi
  home="$TMP_ROOT/stale-resident-lock-home"
  config="$TMP_ROOT/stale-resident-lock-config"
  session_dir="$TMP_ROOT/stale-resident-lock-sessions"
  worktree="$TMP_ROOT/stale-resident-lock-worktree"
  double="$TMP_ROOT/stale-resident-lock-double"
  log="$TMP_ROOT/stale-resident-lock.log"
  mkdir -p "$home/state/watchdog" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 0 armed-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial stale-resident-lock watcher pass should arm the session"

  sleep 1
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 900 armed-sid
  mkdir "$home/state/watchdog/.resident-rotation-demo"
  printf '999999999\n' > "$home/state/watchdog/.resident-rotation-demo/pid"
  printf 'manual\n' > "$home/state/watchdog/.resident-rotation-demo/owner"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "stale resident-lock watcher pass should keep polling after steering"
  [ -s "$log" ] || fail "stale resident rotation lock should not block compact steer delivery"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_threshold"' "stale resident lock recovery should allow compact threshold processing"
  pass "stale resident rotation lock allows compact steer"
}

test_abandoned_provisional_resident_rotation_lock_allows_compact_steer() {
  local home config session_dir worktree double log status event timeout_cmd lock
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping abandoned provisional resident-rotation lock coverage"
    return
  fi
  home="$TMP_ROOT/abandoned-provisional-resident-lock-home"
  config="$TMP_ROOT/abandoned-provisional-resident-lock-config"
  session_dir="$TMP_ROOT/abandoned-provisional-resident-lock-sessions"
  worktree="$TMP_ROOT/abandoned-provisional-resident-lock-worktree"
  double="$TMP_ROOT/abandoned-provisional-resident-lock-double"
  log="$TMP_ROOT/abandoned-provisional-resident-lock.log"
  lock="$home/state/watchdog/.resident-rotation-demo"
  mkdir -p "$home/state/watchdog" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 0 armed-sid
  make_success_double "$double" "$log"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial abandoned-provisional watcher pass should arm the session"

  sleep 1
  write_codex_rollout "$session_dir/rollout-arm.jsonl" "$worktree" 900 armed-sid
  mkdir "$lock"
  touch -t 200001010000 "$lock"
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "abandoned provisional resident-lock watcher pass should keep polling after steering"
  [ -s "$log" ] || fail "abandoned provisional resident rotation lock should not block compact steer delivery"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_threshold"' "abandoned provisional resident lock recovery should allow compact threshold processing"
  pass "abandoned provisional resident rotation lock allows compact steer"
}

test_success_delivers_exact_text_and_event
test_require_target_exists_blocks_delivery
test_require_target_exists_uses_task_label_for_zellij
test_failure_retries_three_then_rc4
test_timeout_bounds_each_attempt
test_timeout_uses_perl_when_timeout_tools_are_absent
test_watcher_starts_compact_steer_without_blocking
test_unarmed_session_is_not_steered_on_first_discovery
test_rotation_rearms_new_session
test_same_file_claude_compact_summary_rearms_session
test_same_file_codex_compaction_cancels_wrap
test_wrap_ack_delivers_compact
test_wrap_ack_timeout_starts_successor
test_wrap_ack_deadline_starts_after_delivery
test_compact_delivery_does_not_retry_across_rotation
test_wrap_rotation_wins_expired_deadline
test_wrap_ack_revalidates_at_backend_send
test_wrap_ack_partial_codex_tail_fails_closed
test_transient_generation_unavailable_restores_bounded_wrap
test_ambiguous_compact_tracks_delayed_generation
test_ambiguous_compact_timeout_starts_successor
test_successful_compact_tracks_delayed_generation
test_metrics_collection_failure_is_visible_and_throttled
test_unsupported_harness_skips_watchdog_metrics
test_stale_meta_skips_watchdog_threshold_scan
test_resident_rotation_lock_blocks_compact_steer
test_provisional_resident_rotation_lock_blocks_compact_steer
test_resident_rotation_lock_blocks_compact_after_metrics
test_fast_steer_completion_does_not_exit_watcher
test_fast_steer_handoff_does_not_corrupt_reacquired_lock
test_stale_resident_rotation_lock_allows_compact_steer
test_abandoned_provisional_resident_rotation_lock_allows_compact_steer

echo "# all watchdog steer tests passed"
