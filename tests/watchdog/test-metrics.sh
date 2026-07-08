#!/usr/bin/env bash
# Behavior tests for observe-only watchdog metric collection.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-metrics-tests)
FIXTURE_DIR="$ROOT/tests/watchdog/fixtures"
CLAUDE_FIXTURE="$FIXTURE_DIR/token-optimizer-checkpoint.json"

test_claude_checkpoint_metrics() {
  local out context expected session
  session=$(jq -r '.session_id' "$CLAUDE_FIXTURE")
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/state" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$FIXTURE_DIR" \
    bash -c '. "$1"; fm_watchdog_collect_metrics claude "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$session")
  jq -e '
    has("harness")
    and has("context_pct")
    and has("five_hr_pct")
    and has("seven_day_pct")
    and has("tool_calls")
    and has("collected_at")
    and has("parser_version")
  ' "$out" >/dev/null || fail "metrics JSON should include every watchdog data key"
  context=$(jq -r '.context_pct' "$out")
  expected=$(jq -r '.fill_pct' "$CLAUDE_FIXTURE")
  [ "$context" = "$expected" ] || fail "context_pct should match fixture fill_pct, got: $context"
  [ "$(jq -r '.harness' "$out")" = claude ] || fail "harness should be claude"
  [ "$(jq -r '.parser_version' "$out")" = 1 ] || fail "parser_version should be 1"
  pass "claude checkpoint metrics are written from a real token-optimizer fixture"
}

test_claude_checkpoint_selection_matches_session() {
  local dir out target other session
  dir="$TMP_ROOT/claude-selection"
  mkdir -p "$dir"
  target="$dir/target.json"
  other="$dir/other.json"
  session='target-session'
  jq --arg session "$session" '.session_id = $session | .fill_pct = 41 | .quality.tool_calls = 101' \
    "$CLAUDE_FIXTURE" > "$target"
  jq --arg session other-session '.session_id = $session | .fill_pct = 99 | .quality.tool_calls = 999' \
    "$CLAUDE_FIXTURE" > "$other"
  touch -t 202607080101 "$target"
  touch -t 202607080202 "$other"
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/claude-selection-state" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$dir" \
    bash -c '. "$1"; fm_watchdog_collect_metrics claude "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$session")
  [ "$(jq -r '.context_pct' "$out")" = 41 ] || fail "claude metrics should come from the requested session"
  [ "$(jq -r '.tool_calls' "$out")" = 101 ] || fail "claude metrics should ignore newer checkpoints for other sessions"
  pass "claude checkpoint selection is scoped to the requested session"
}

test_meta_backed_claude_checkpoint_accepts_session_id_alias() {
  local home session_dir checkpoint_dir target_wt key session out
  home="$TMP_ROOT/claude-alias-home"
  session_dir="$TMP_ROOT/claude-alias-sessions"
  checkpoint_dir="$TMP_ROOT/claude-alias-checkpoints"
  target_wt="$TMP_ROOT/worktrees/.no-mistakes/claude.alias-target"
  session='claude-alias-session'
  mkdir -p "$home/state" "$target_wt" "$checkpoint_dir"
  key=$(cd "$target_wt" && pwd -P | sed 's#[^A-Za-z0-9]#-#g')
  mkdir -p "$session_dir/$key"
  fm_write_meta "$home/state/demo.meta" "worktree=$target_wt" "harness=claude"
  printf '{}\n' > "$session_dir/$key/$session.jsonl"
  jq --arg session "$session" 'del(.session_id) | .sessionId = $session | .fill_pct = 43' \
    "$CLAUDE_FIXTURE" > "$checkpoint_dir/target.json"

  out=$(FM_HOME="$home" \
    FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" \
    bash -c '. "$1"; fm_watchdog_collect_metrics claude demo' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(jq -r '.context_pct' "$out")" = 43 ] || fail "meta-backed claude metrics should accept sessionId checkpoints"
  pass "meta-backed claude checkpoint selection accepts sessionId"
}

test_claude_checkpoint_missing_session_is_loud() {
  local dir out err status
  dir="$TMP_ROOT/claude-missing"
  mkdir -p "$dir"
  jq --arg session other-session '.session_id = $session' "$CLAUDE_FIXTURE" > "$dir/other.json"
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/claude-missing-state" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$dir" \
    bash -c '. "$1"; fm_watchdog_collect_metrics claude missing-session' _ "$ROOT/bin/fm-watchdog-lib.sh" 2>"$TMP_ROOT/claude-missing.err")
  status=$?
  err=$(cat "$TMP_ROOT/claude-missing.err")
  expect_code 3 "$status" "missing claude session should exit with parser mismatch code"
  [ -z "$out" ] || fail "missing claude session should not print a metrics path"
  assert_contains "$err" "missing-session" "missing claude session error should name the requested session"
  pass "claude checkpoint selection fails loudly without a matching session"
}

test_corrupt_claude_checkpoint_is_loud() {
  local corrupt out err status
  corrupt="$TMP_ROOT/corrupt"
  mkdir -p "$corrupt"
  jq 'del(.fill_pct)' "$CLAUDE_FIXTURE" > "$corrupt/corrupt.json"
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/bad-state" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$corrupt" \
    bash -c '. "$1"; fm_watchdog_collect_metrics claude corrupt-session' _ "$ROOT/bin/fm-watchdog-lib.sh" 2>"$TMP_ROOT/corrupt.err")
  status=$?
  err=$(cat "$TMP_ROOT/corrupt.err")
  expect_code 3 "$status" "corrupt checkpoint should exit with parser mismatch code"
  [ -z "$out" ] || fail "corrupt checkpoint should not print a metrics path"
  assert_contains "$err" "WATCHDOG_PARSER_MISMATCH" "corrupt checkpoint should fail loudly"
  pass "corrupt checkpoint cannot silently produce metrics"
}

write_codex_rollout_for_cwd() {
  local path=$1 cwd=$2 total=$3 limit=$4
  mkdir -p "$(dirname "$path")"
  jq -cn --arg cwd "$cwd" '{type:"session_meta",payload:{session_id:"sid-" + ($cwd | gsub("[^A-Za-z0-9]"; "-")),cwd:$cwd}}' > "$path"
  jq -cn --argjson total "$total" --argjson limit "$limit" \
    '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:$total},model_context_window:$limit},rate_limits:{primary:{used_percent:11},secondary:{used_percent:22}}}}' >> "$path"
}

write_codex_rollout() {
  local file=$1 session=$2 total=$3 primary=$4 secondary=$5
  printf '%s\n' \
    "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"$session\",\"id\":\"$session\"}}" \
    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":$total},\"model_context_window\":1000},\"rate_limits\":{\"primary\":{\"used_percent\":$primary},\"secondary\":{\"used_percent\":$secondary}}}}" \
    > "$file"
}

write_codex_rollout_root_session() {
  local file=$1 session=$2 cwd=$3 total=$4 primary=$5 secondary=$6
  mkdir -p "$(dirname "$file")"
  jq -cn --arg session "$session" --arg cwd "$cwd" \
    '{type:"session_meta",session_id:$session,payload:{cwd:$cwd}}' > "$file"
  jq -cn --argjson total "$total" --argjson primary "$primary" --argjson secondary "$secondary" \
    '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:$total},model_context_window:1000},rate_limits:{primary:{used_percent:$primary},secondary:{used_percent:$secondary}}}}' >> "$file"
}

test_codex_rollout_selection_matches_session() {
  local dir out
  dir="$TMP_ROOT/codex-selection"
  mkdir -p "$dir"
  write_codex_rollout "$dir/rollout-target.jsonl" codex-target 500 12 34
  write_codex_rollout "$dir/rollout-other.jsonl" codex-other 900 56 78
  touch -t 202607080101 "$dir/rollout-target.jsonl"
  touch -t 202607080202 "$dir/rollout-other.jsonl"
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/codex-selection-state" \
    FM_WATCHDOG_CODEX_SESSION_DIR="$dir" \
    bash -c '. "$1"; fm_watchdog_collect_metrics codex codex-target' _ "$ROOT/bin/fm-watchdog-lib.sh")
  jq -e '.context_pct == 50 and .five_hr_pct == 12 and .seven_day_pct == 34' "$out" >/dev/null \
    || fail "codex metrics should come from the requested session"
  pass "codex rollout selection is scoped to the requested session"
}

test_meta_backed_codex_rollout_accepts_root_session_id() {
  local home session_dir target_wt out
  home="$TMP_ROOT/codex-root-session-home"
  session_dir="$TMP_ROOT/codex-root-session-sessions"
  target_wt="$TMP_ROOT/worktrees/codex-root-session-target"
  mkdir -p "$home/state" "$target_wt"
  fm_write_meta "$home/state/demo.meta" "worktree=$target_wt" "harness=codex"
  write_codex_rollout_root_session "$session_dir/2026/07/08/rollout-target.jsonl" codex-root-session "$target_wt" 420 21 31

  out=$(FM_HOME="$home" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    bash -c '. "$1"; fm_watchdog_collect_metrics codex demo' _ "$ROOT/bin/fm-watchdog-lib.sh")
  jq -e '.context_pct == 42 and .five_hr_pct == 21 and .seven_day_pct == 31' "$out" >/dev/null \
    || fail "meta-backed codex metrics should accept root session_id rollouts"
  pass "meta-backed codex rollout selection accepts root session_id"
}

test_codex_rollout_missing_session_is_loud() {
  local dir out err status
  dir="$TMP_ROOT/codex-missing"
  mkdir -p "$dir"
  write_codex_rollout "$dir/rollout-other.jsonl" codex-other 900 56 78
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/codex-missing-state" \
    FM_WATCHDOG_CODEX_SESSION_DIR="$dir" \
    bash -c '. "$1"; fm_watchdog_collect_metrics codex missing-codex' _ "$ROOT/bin/fm-watchdog-lib.sh" 2>"$TMP_ROOT/codex-missing.err")
  status=$?
  err=$(cat "$TMP_ROOT/codex-missing.err")
  expect_code 3 "$status" "missing codex session should exit with parser mismatch code"
  [ -z "$out" ] || fail "missing codex session should not print a metrics path"
  assert_contains "$err" "missing-codex" "missing codex session error should name the requested session"
  pass "codex rollout selection fails loudly without a matching session"
}

test_unknown_harness_is_observe_only_tolerant() {
  local out
  out=$(FM_STATE_OVERRIDE="$TMP_ROOT/unknown-state" \
    bash -c '. "$1"; fm_watchdog_collect_metrics mystery unknown-session' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(jq -r '.context_pct' "$out")" = null ] || fail "unknown harness should write null context_pct"
  [ "$(jq -r '.harness' "$out")" = mystery ] || fail "unknown harness name should be preserved"
  pass "unknown harness writes tolerant null metrics"
}

test_claude_project_key_matches_cli_normalization() {
  local out
  out=$(bash -c '. "$1"; fm_watchdog_claude_project_key "/var/home/mlight/.treehouse/firstmate-7bab20/1/firstmate"' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$out" = "-var-home-mlight--treehouse-firstmate-7bab20-1-firstmate" ] \
    || fail "claude project key should replace every non-alphanumeric byte, got $out"
  pass "claude project key matches Claude CLI normalization"
}

test_task_scoped_claude_lookup_requires_worktree() {
  local home session_dir latest status
  home="$TMP_ROOT/claude-no-worktree-home"
  session_dir="$TMP_ROOT/claude-no-worktree-sessions"
  mkdir -p "$home/state" "$session_dir/some-project"
  fm_write_meta "$home/state/demo.meta" "harness=claude"
  printf '{}\n' > "$session_dir/some-project/newest.jsonl"

  latest=$(FM_HOME="$home" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    bash -c '. "$1"; fm_watchdog_session_file claude demo' _ "$ROOT/bin/fm-watchdog-lib.sh")
  status=$?
  expect_code 1 "$status" "task-scoped claude lookup without worktree should fail"
  [ -z "$latest" ] || fail "task-scoped claude lookup must not fall back to global latest"
  pass "task-scoped claude lookup refuses unscoped global fallback"
}

test_codex_metrics_are_scoped_to_task_worktree() {
  local home session_dir target_wt other_wt out context
  home="$TMP_ROOT/codex-scope-home"
  session_dir="$TMP_ROOT/codex-sessions"
  target_wt="$TMP_ROOT/worktrees/target"
  other_wt="$TMP_ROOT/worktrees/other"
  mkdir -p "$home/state" "$target_wt" "$other_wt"
  fm_write_meta "$home/state/demo.meta" "worktree=$target_wt" "harness=codex"
  write_codex_rollout_for_cwd "$session_dir/2026/07/08/rollout-target.jsonl" "$target_wt" 100 1000
  write_codex_rollout_for_cwd "$session_dir/2026/07/08/rollout-other.jsonl" "$other_wt" 950 1000
  touch "$session_dir/2026/07/08/rollout-target.jsonl"
  sleep 1
  touch "$session_dir/2026/07/08/rollout-other.jsonl"

  out=$(FM_HOME="$home" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    bash -c '. "$1"; fm_watchdog_collect_metrics codex demo' _ "$ROOT/bin/fm-watchdog-lib.sh")
  context=$(jq -r '.context_pct' "$out")
  [ "$context" = 10 ] || fail "codex metrics should use the task worktree rollout, got context_pct=$context"
  pass "codex metrics are scoped to the task worktree"
}

test_codex_session_lookup_uses_task_cache() {
  local home session_dir target_wt other_wt fakebin out cached
  home="$TMP_ROOT/codex-cache-home"
  session_dir="$TMP_ROOT/codex-cache-sessions"
  target_wt="$TMP_ROOT/worktrees/cache-target"
  other_wt="$TMP_ROOT/worktrees/cache-other"
  fakebin="$TMP_ROOT/codex-cache-fakebin"
  mkdir -p "$home/state" "$target_wt" "$other_wt" "$fakebin"
  fm_write_meta "$home/state/demo.meta" "worktree=$target_wt" "harness=codex"
  write_codex_rollout_for_cwd "$session_dir/2026/07/07/rollout-target.jsonl" "$target_wt" 100 1000
  for n in 1 2 3 4 5; do
    write_codex_rollout_for_cwd "$session_dir/2026/07/07/rollout-other-$n.jsonl" "$other_wt" 950 1000
  done

  out=$(FM_HOME="$home" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    bash -c '. "$1"; fm_watchdog_session_file codex demo' _ "$ROOT/bin/fm-watchdog-lib.sh")
  cached="$home/state/watchdog/.codex-rollout-demo"
  assert_present "$cached" "codex session lookup should persist the matched rollout path"
  [ "$(sed -n '1p' "$cached")" = "$out" ] || fail "codex rollout cache should record the selected path"

  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf 'jq should not be called for a valid codex rollout cache\n' >&2
exit 99
SH
  chmod +x "$fakebin/jq"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    bash -c '. "$1"; fm_watchdog_session_file codex demo' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$out" = "$(sed -n '1p' "$cached")" ] || fail "cached codex rollout path should be reused without reparsing history"
  pass "codex session lookup reuses the task rollout cache"
}

test_threshold_defaults() {
  local out
  out=$(FM_HOME="$TMP_ROOT/no-config-home" bash -c '. "$1"; fm_watchdog_thresholds' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(printf '%s' "$out" | jq -r '.thresholds.compact_at_context_pct')" = 85 ] \
    || fail "default compact threshold should be 85"
  [ "$(printf '%s' "$out" | jq -r 'has("rotate_to")')" = false ] \
    || fail "default rotation should stay reserved for W4"
  pass "watchdog thresholds fall back to shipped defaults"
}

test_threshold_config_override() {
  local config out
  config="$TMP_ROOT/config-override"
  mkdir -p "$config"
  jq '.thresholds.compact_at_context_pct = 81' "$ROOT/docs/examples/watchdog.json" > "$config/watchdog.json"
  out=$(FM_HOME="$TMP_ROOT/ignored-home" FM_CONFIG_OVERRIDE="$config" \
    bash -c '. "$1"; fm_watchdog_thresholds' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(printf '%s' "$out" | jq -r '.thresholds.compact_at_context_pct')" = 81 ] \
    || fail "FM_CONFIG_OVERRIDE watchdog config should be read before FM_HOME/config"
  pass "watchdog thresholds honor FM_CONFIG_OVERRIDE"
}

test_malformed_threshold_config_falls_back_loudly() {
  local home config out event
  home="$TMP_ROOT/malformed-home"
  config="$TMP_ROOT/malformed-config"
  mkdir -p "$home" "$config"
  printf '{\n' > "$config/watchdog.json"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    bash -c '. "$1"; fm_watchdog_thresholds' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ "$(printf '%s' "$out" | jq -r '.thresholds.compact_at_context_pct')" = 85 ] \
    || fail "malformed config should fall back to default compact threshold"
  event="$home/fm-state/watchdog.events"
  assert_present "$event" "malformed config should write a visible watchdog event"
  assert_contains "$(cat "$event")" '"type":"watchdog_config"' "malformed config event should name the config failure"
  pass "malformed watchdog config falls back loudly"
}

test_watchdog_events_remain_jsonl_under_concurrency() {
  local home event detail pids pid count
  home="$TMP_ROOT/concurrent-events-home"
  event="$home/fm-state/watchdog.events"
  mkdir -p "$home/state"
  detail=$(printf 'payload-%06000d' 1)
  pids=
  for worker in 1 2 3 4; do
    FM_HOME="$home" DETAIL="$detail" bash -c '
      . "$1"
      for i in 1 2 3 4 5; do
        fm_watchdog_event concurrent "worker-$2" ok "$DETAIL-$i"
      done
    ' _ "$ROOT/bin/fm-watchdog-lib.sh" "$worker" &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent watchdog event writer failed"
  done
  count=$(wc -l < "$event" | tr -d '[:space:]')
  [ "$count" = 20 ] || fail "concurrent event log should contain 20 JSONL records, got $count"
  jq -e 'select(.type == "concurrent" and .status == "ok")' "$event" >/dev/null \
    || fail "concurrent event log should remain parseable JSONL"
  pass "watchdog events remain JSONL under concurrent writers"
}

test_claude_checkpoint_metrics
test_claude_checkpoint_selection_matches_session
test_meta_backed_claude_checkpoint_accepts_session_id_alias
test_claude_checkpoint_missing_session_is_loud
test_corrupt_claude_checkpoint_is_loud
test_codex_rollout_selection_matches_session
test_meta_backed_codex_rollout_accepts_root_session_id
test_codex_rollout_missing_session_is_loud
test_unknown_harness_is_observe_only_tolerant
test_claude_project_key_matches_cli_normalization
test_task_scoped_claude_lookup_requires_worktree
test_codex_metrics_are_scoped_to_task_worktree
test_codex_session_lookup_uses_task_cache
test_threshold_defaults
test_threshold_config_override
test_malformed_threshold_config_falls_back_loudly
test_watchdog_events_remain_jsonl_under_concurrency

echo "# all watchdog metrics tests passed"
