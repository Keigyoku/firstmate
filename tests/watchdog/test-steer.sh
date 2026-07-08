#!/usr/bin/env bash
# Behavior tests for backend-aware watchdog steering.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-steer-tests)

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
  local path=$1 cwd=$2
  mkdir -p "$(dirname "$path")"
  jq -cn --arg cwd "$cwd" '{type:"session_meta",payload:{session_id:"watcher-sid",cwd:$cwd}}' > "$path"
  jq -cn '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:900},model_context_window:1000},rate_limits:{primary:{used_percent:11},secondary:{used_percent:22}}}}' >> "$path"
}

make_success_double() {
  local path=$1 log=$2
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FM_STEER_DOUBLE_LOG"
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
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    pass "timeout helper unavailable; skipping steer timeout coverage"
    return
  fi
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
  expect_code 124 "$status" "watcher should still be sleeping its normal poll when the test timeout stops it"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_steer_started"' "watcher should record async steer start before the backend send completes"
  sleep 5
  pass "watcher starts compact steer asynchronously"
}

test_success_delivers_exact_text_and_event
test_failure_retries_three_then_rc4
test_timeout_bounds_each_attempt
test_watcher_starts_compact_steer_without_blocking

echo "# all watchdog steer tests passed"
