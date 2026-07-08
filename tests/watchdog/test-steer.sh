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
  local path=$1 cwd=$2 total=${3:-900} session_id=${4:-watcher-sid}
  mkdir -p "$(dirname "$path")"
  jq -cn --arg cwd "$cwd" --arg session_id "$session_id" '{type:"session_meta",payload:{session_id:$session_id,cwd:$cwd}}' > "$path"
  jq -cn --argjson total "$total" \
    '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:$total},model_context_window:1000},rate_limits:{primary:{used_percent:11},secondary:{used_percent:22}}}}' >> "$path"
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
  assert_contains "$(cat "$event")" '"type":"compact_steer_started"' "watcher should record async steer start before the backend send completes"
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
  local home config session_dir worktree double log pending handled new_sig status event threshold_count timeout_cmd
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
  [ "$(tail -n 1 "$log")" = "tmux|target-pane|/compact complete current task, then /compact" ] \
    || fail "new session threshold should deliver a second compact steer"
  pass "watcher re-arms compact threshold after transcript rotation"
}

test_stale_pending_retries_without_rotation() {
  local home config session_dir worktree double log pending status event threshold_count send_count timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping stale pending retry coverage"
    return
  fi
  home="$TMP_ROOT/pending-retry-home"
  config="$TMP_ROOT/pending-retry-config"
  session_dir="$TMP_ROOT/pending-retry-sessions"
  worktree="$TMP_ROOT/pending-retry-worktree"
  double="$TMP_ROOT/pending-retry-double"
  log="$TMP_ROOT/pending-retry.log"
  mkdir -p "$home/state" "$worktree"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_fast_threshold_config "$config"
  jq '.compact_pending_retry_sec = 1' "$config/watchdog.json" > "$config/watchdog.json.tmp"
  mv "$config/watchdog.json.tmp" "$config/watchdog.json"
  make_success_double "$double" "$log"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 900 same-sid

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial pending-retry watcher pass should arm the session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial pending-retry watcher run should be stopped by test timeout"
  pending="$home/state/watchdog/.compact-pending-demo"
  assert_present "$pending" "successful compact steer should leave a pending marker"

  sleep 2
  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_STEER_BACKEND_CMD="$double" FM_STEER_DOUBLE_LOG="$log" FM_POLL=30 \
    "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "retry watcher run should be stopped by test timeout"
  event="$home/fm-state/watchdog.events"
  assert_contains "$(cat "$event")" '"type":"compact_pending_expired"' "stale pending marker should be reported before retry"
  threshold_count=$(grep -c '"type":"compact_threshold"' "$event")
  [ "$threshold_count" = 2 ] || fail "stale pending session should trigger a second compact threshold, got $threshold_count"
  send_count=$(wc -l < "$log" | tr -d '[:space:]')
  [ "$send_count" = 2 ] || fail "stale pending session should retry delivery exactly once, got $send_count sends"
  pass "watcher retries stale compact pending markers"
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

test_success_delivers_exact_text_and_event
test_require_target_exists_blocks_delivery
test_failure_retries_three_then_rc4
test_timeout_bounds_each_attempt
test_timeout_uses_perl_when_timeout_tools_are_absent
test_watcher_starts_compact_steer_without_blocking
test_unarmed_session_is_not_steered_on_first_discovery
test_rotation_rearms_new_session
test_stale_pending_retries_without_rotation
test_metrics_collection_failure_is_visible_and_throttled

echo "# all watchdog steer tests passed"
