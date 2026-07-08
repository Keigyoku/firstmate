#!/usr/bin/env bash
# Behavior tests for watchdog budget embargo, spawn gating, rotation, and lift.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-embargo-tests)

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

write_embargo_config() {
  local dir=$1
  mkdir -p "$dir"
  jq '.thresholds.compact_at_context_pct = 99
    | .thresholds.successor_at_context_pct = 100
    | .thresholds.embargo_at_5hr_pct = 85
    | .thresholds.embargo_at_7d_pct = 85
    | .rotate_to = ["codex", "opencode"]
    | .poll_interval_sec = 30' \
    "$ROOT/docs/examples/watchdog.json" > "$dir/watchdog.json"
}

write_codex_rollout() {
  local path=$1 cwd=$2 primary=${3:-86} secondary=${4:-22} reset=${5:-1893456000}
  mkdir -p "$(dirname "$path")"
  jq -cn --arg cwd "$cwd" '{type:"session_meta",payload:{session_id:"embargo-sid",cwd:$cwd}}' > "$path"
  jq -cn --argjson primary "$primary" --argjson secondary "$secondary" --argjson reset "$reset" \
    '{type:"event_msg",payload:{type:"token_count",info:{last_token_usage:{total_tokens:100},model_context_window:1000},rate_limits:{primary:{used_percent:$primary,reset_at:$reset},secondary:{used_percent:$secondary,reset_at:$reset}}}}' >> "$path"
}

test_budget_embargo_gate_rotation_and_lift() {
  local home config session_dir worktree status flag event out
  local timeout_cmd
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping budget embargo coverage"
    return
  fi
  home="$TMP_ROOT/embargo-home"
  config="$TMP_ROOT/embargo-config"
  session_dir="$TMP_ROOT/embargo-sessions"
  worktree="$TMP_ROOT/embargo-worktree"
  mkdir -p "$home/state" "$home/config" "$worktree"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "worktree=$worktree" "backend=tmux" "harness=codex"
  write_embargo_config "$config"
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 86 22

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial embargo watcher pass should arm the session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "embargo watcher pass should be stopped by test timeout"
  flag="$home/fm-state/watchdog/embargo-codex"
  assert_present "$flag" "86 percent five-hour usage should create the codex embargo flag"
  assert_grep "five_hr_pct=86" "$flag" "embargo flag should record the triggering five-hour percentage"
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"embargo","sid":"demo","status":"raised"' "$event" "embargo transition should be logged"

  FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$ROOT/bin/fm-spawn.sh" demo "$worktree" --harness codex --dry-run >/dev/null 2>&1
  status=$?
  expect_code 7 "$status" "dry-run spawn on an embargoed harness should exit rc 7"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = opencode ] || fail "crew harness rotation should choose opencode, got $out"

  FM_HOME="$home" "$ROOT/bin/fm-embargo-lift" --harness codex >/dev/null
  assert_absent "$flag" "manual lift should remove the embargo flag"
  assert_grep '"type":"embargo","sid":"codex","status":"lifted"' "$event" "lift transition should be logged"
  pass "budget embargo gates new spawns, rotates harnesses, and lifts manually"
}

test_budget_embargo_auto_lifts_at_reset_boundary() {
  local home flag event
  home="$TMP_ROOT/auto-lift-home"
  mkdir -p "$home/state"
  FM_HOME="$home" bash -c '. "$1"; fm_watchdog_write_embargo codex demo 86 22 1 1 "five_hr_pct>=85"' _ "$ROOT/bin/fm-watchdog-lib.sh"
  flag="$home/fm-state/watchdog/embargo-codex"
  assert_present "$flag" "fixture embargo flag should exist before auto-lift"
  FM_HOME="$home" bash -c '. "$1"; fm_watchdog_embargo_auto_lift codex demo ""' _ "$ROOT/bin/fm-watchdog-lib.sh"
  assert_absent "$flag" "auto-lift should remove a flag whose reset timestamp has crossed"
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"embargo","sid":"demo","status":"lifted"' "$event" "auto-lift transition should be logged"
  assert_grep 'reason=provider_reset' "$event" "auto-lift event should name the provider reset reason"
  pass "budget embargo auto-lifts at the provider reset boundary"
}

test_budget_embargo_gate_rotation_and_lift
test_budget_embargo_auto_lifts_at_reset_boundary

echo "# all watchdog embargo tests passed"
