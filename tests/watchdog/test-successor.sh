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
case "$1 $2 $3" in
  "display-message -p -t")
    if [ "${FM_TMUX_TARGET_EXISTS_ALL:-0}" = 1 ] && [ "$5" = '#{pane_id}' ]; then
      printf '%%1\n'
      exit 0
    fi
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_dead_tmux_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "display-message -p -t fm-demo-dead-next #{pane_current_command}") printf 'bash\n'; exit 0 ;;
  "display-message -p -t fm-demo-dead-next #{pane_id}") printf '%%1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_orca_terminal_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --help) printf 'status repo worktree terminal\n'; exit 0 ;;
esac
case "$1 $2" in
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":["ready"]}}}\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/orca"
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
  local dir=$1 session_id=$2 pct=${3:-96}
  mkdir -p "$dir"
  jq -cn --arg sid "$session_id" --argjson pct "$pct" \
    '{version:1,session_id:$sid,fill_pct:$pct,quality:{tool_calls:2}}' > "$dir/$session_id.json"
}

make_spawn_double() {
  local path=$1 log=$2 status=${3:-0}
  cat > "$path" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_SUCCESSOR_SPAWN_LOG"
if [ "${FM_SUCCESSOR_DOUBLE_CREATE_META:-0}" = 1 ]; then
  mkdir -p "$FM_HOME/state"
  id=$1
  project=$2
  worktree=$2
  mode=no-mistakes
  yolo=off
  kind=ship
  backend=tmux
  harness=codex
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --adopt-worktree-path) shift; worktree=$1 ;;
      --backend) shift; backend=$1 ;;
      --harness) shift; harness=$1 ;;
      --scout) kind=scout ;;
      --mode) shift; mode=$1 ;;
      --yolo) shift; yolo=$1 ;;
    esac
    shift
  done
  {
    printf 'window=%s\n' "fm-$id"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
    printf 'harness=%s\n' "$harness"
    printf 'kind=%s\n' "$kind"
    printf 'mode=%s\n' "$mode"
    printf 'yolo=%s\n' "$yolo"
    [ "$backend" = tmux ] || printf 'backend=%s\n' "$backend"
  } > "$FM_HOME/state/$id.meta"
  if [ "${FM_SUCCESSOR_DOUBLE_WRITE_HOOKS:-0}" = 1 ]; then
    state_real=$(cd "$FM_HOME/state" && pwd -P)
    turnend="$state_real/$id.turn-ended"
    case "$harness" in
      claude*)
        mkdir -p "$worktree/.claude"
        printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '\''%s'\''"}]}]}}\n' "$turnend" > "$worktree/.claude/settings.local.json"
        ;;
      grok*)
        printf '%s\n' "fm.bbbbbbbbbbbb" > "$FM_HOME/state/$id.grok-turnend-token"
        printf 'token=%s\n' "fm.bbbbbbbbbbbb" > "$worktree/.fm-grok-turnend"
        ;;
    esac
  fi
  case "${FM_SUCCESSOR_DOUBLE_READY:-}" in
    status) printf 'working: accepted successor handoff\n' > "$FM_HOME/state/$id.status" ;;
    turn) : > "$FM_HOME/state/$id.turn-ended" ;;
  esac
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
exit "${FM_SUCCESSOR_RETIRE_STATUS:-0}"
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
  local home project worktree spawn_log retire_log spawn_double retire_double handoff brief event retired_meta
  home="$TMP_ROOT/success-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/success-spawn.log"
  retire_log="$TMP_ROOT/success-retire.log"
  spawn_double="$TMP_ROOT/success-spawn-double"
  retire_double="$TMP_ROOT/success-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$home/data/demo" "$project" "$worktree"
  handoff="$home/fm-state/handoff-latest.md"
  printf 'Continue from W3 HANDOFF MARKER.\n' > "$handoff"
  printf 'Original objective marker.\n' > "$home/data/demo/brief.md"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "harness=claude" "model=default" "effort=default" "mode=local-only" "yolo=on"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_READY=status \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" \
    FM_SUCCESSOR_RETIRE_LOG="$retire_log" "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null \
    || fail "successor spawn should succeed"

  brief="$home/data/demo-next/brief.md"
  assert_present "$brief" "successor brief should be generated"
  assert_grep "$handoff" "$brief" "successor brief should include handoff path"
  assert_grep "W3 HANDOFF MARKER" "$brief" "successor brief should include handoff content"
  assert_absent "$home/state/demo.meta" "retired predecessor meta should leave active state"
  retired_meta="$home/state/retired/demo.meta"
  assert_present "$retired_meta" "retired predecessor meta should be archived outside active state"
  assert_grep "retired_by=demo-next" "$retired_meta" "retired predecessor meta should record successor"
  assert_grep "demo-next $project --adopt-worktree --adopt-worktree-path $worktree --harness claude --backend tmux --mode local-only --yolo on" "$spawn_log" "spawn double should receive successor args"
  [ "$(cat "$retire_log")" = "tmux|target-pane" ] || fail "predecessor should be retired through backend target"
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"successor_spawn","sid":"demo","status":"started"' "$event" "spawn start event should be logged"
  assert_grep 'readiness=status' "$event" "spawn success event should record readiness proof"
  assert_grep '"type":"predecessor_retired","sid":"demo","status":"closed"' "$event" "retire event should be logged"
  pass "successor spawns with handoff brief and retires predecessor"
}

test_successor_preserves_scout_and_pr_metadata() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff successor_meta
  home="$TMP_ROOT/metadata-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/metadata-spawn.log"
  retire_log="$TMP_ROOT/metadata-retire.log"
  spawn_double="$TMP_ROOT/metadata-spawn-double"
  retire_double="$TMP_ROOT/metadata-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-metadata.md"
  printf 'handoff for metadata successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" \
    "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" \
    "kind=scout" "mode=no-mistakes" "yolo=off" "pr=https://github.com/o/r/pull/42" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-metadata-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_READY=status \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null \
    || fail "metadata successor spawn should succeed"

  assert_grep "--scout" "$spawn_log" "scout predecessor should spawn scout successor"
  successor_meta="$home/state/demo-metadata-next.meta"
  assert_grep 'kind=scout' "$successor_meta" "successor meta should preserve scout kind"
  assert_grep 'pr=https://github.com/o/r/pull/42' "$successor_meta" "successor meta should carry pr"
  assert_grep 'pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' "$successor_meta" "successor meta should carry pr_head"
  [ "$(cat "$retire_log")" = "tmux|target-pane" ] || fail "metadata predecessor should retire after readiness"
  pass "successor preserves scout and PR metadata"
}

test_successor_carries_predecessor_check_script() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff successor_check
  home="$TMP_ROOT/check-carry-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/check-carry-spawn.log"
  retire_log="$TMP_ROOT/check-carry-retire.log"
  spawn_double="$TMP_ROOT/check-carry-spawn-double"
  retire_double="$TMP_ROOT/check-carry-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-check.md"
  printf 'handoff for check successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" \
    "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" \
    "mode=no-mistakes" "yolo=off" "pr=https://github.com/o/r/pull/42"
  printf '%s\n' 'echo merged' > "$home/state/demo.check.sh"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-check-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_READY=status \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null \
    || fail "check-carry successor spawn should succeed"

  successor_check="$home/state/demo-check-next.check.sh"
  assert_present "$successor_check" "successor should inherit predecessor check script"
  assert_grep 'echo merged' "$successor_check" "successor check script should keep poll body"
  assert_absent "$home/state/demo.check.sh" "retired predecessor check script should be disarmed"
  pass "successor carries predecessor check script"
}

test_successor_rejects_orca_backend_before_spawn() {
  local home project worktree spawn_log spawn_double handoff status halt artifact
  home="$TMP_ROOT/orca-backend-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/orca-backend-spawn.log"
  spawn_double="$TMP_ROOT/orca-backend-spawn-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-orca.md"
  printf 'handoff for unsupported Orca successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" \
    "window=fm-demo" "terminal=term-demo" "project=$project" "worktree=$worktree" \
    "backend=orca" "harness=codex" "mode=no-mistakes" "yolo=off"
  make_spawn_double "$spawn_double" "$spawn_log" 0

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-orca-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "Orca successor should exit 1 before spawn"
  [ ! -s "$spawn_log" ] || fail "Orca successor should not call fm-spawn"
  assert_present "$home/state/demo.meta" "Orca predecessor meta should remain active"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "Orca successor direct call should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_grep "unsupported successor backend orca" "$artifact" "failure artifact should explain unsupported Orca successor"
  pass "successor rejects Orca backend before spawn"
}

test_successor_accepts_backend_endpoint_readiness() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff event
  home="$TMP_ROOT/endpoint-ready-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/endpoint-ready-spawn.log"
  retire_log="$TMP_ROOT/endpoint-ready-retire.log"
  spawn_double="$TMP_ROOT/endpoint-ready-spawn-double"
  retire_double="$TMP_ROOT/endpoint-ready-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-endpoint.md"
  printf 'handoff for endpoint-ready successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" "mode=no-mistakes" "yolo=off"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-endpoint-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_TMUX_TARGET_EXISTS_ALL=1 \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null \
    || fail "endpoint-ready successor spawn should succeed"

  event="$home/fm-state/watchdog.events"
  assert_grep 'readiness=endpoint' "$event" "spawn success event should record endpoint readiness proof"
  assert_absent "$home/state/demo.meta" "endpoint-ready predecessor meta should be retired"
  pass "successor accepts backend endpoint readiness"
}

test_successor_rejects_dead_agent_endpoint_readiness() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff status halt artifact dead_fakebin
  home="$TMP_ROOT/dead-endpoint-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/dead-endpoint-spawn.log"
  retire_log="$TMP_ROOT/dead-endpoint-retire.log"
  spawn_double="$TMP_ROOT/dead-endpoint-spawn-double"
  retire_double="$TMP_ROOT/dead-endpoint-retire-double"
  dead_fakebin=$(make_dead_tmux_fakebin "$TMP_ROOT/dead-endpoint-tools")
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-dead-endpoint.md"
  printf 'handoff for dead endpoint successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" "mode=no-mistakes" "yolo=off"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  PATH="$dead_fakebin:$PATH" FM_HOME="$home" FM_SUCCESSOR_ID=demo-dead-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_READY_TIMEOUT=0 \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "dead-agent successor endpoint should exit 1"
  assert_present "$home/state/demo.meta" "predecessor meta should remain active when successor agent is dead"
  assert_no_grep 'tmux|target-pane' "$retire_log" "predecessor should not retire for a dead successor agent"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "dead-agent successor should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_grep "successor readiness could not be proven" "$artifact" "failure artifact should explain missing readiness"
  pass "successor rejects endpoint readiness after a dead agent verdict"
}

test_successor_rejects_bare_turnend_readiness() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff status halt artifact
  home="$TMP_ROOT/turnend-ready-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/turnend-ready-spawn.log"
  retire_log="$TMP_ROOT/turnend-ready-retire.log"
  spawn_double="$TMP_ROOT/turnend-ready-spawn-double"
  retire_double="$TMP_ROOT/turnend-ready-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-turnend.md"
  printf 'handoff for turnend-only successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" "mode=no-mistakes" "yolo=off"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-turnend-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_READY=turn \
    FM_SUCCESSOR_READY_TIMEOUT=0 FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "turn-ended-only successor should exit 1"
  assert_present "$home/state/demo.meta" "predecessor meta should remain active for turn-ended-only readiness"
  assert_absent "$home/state/demo-turnend-next.meta" "turn-ended-only successor meta should be cleaned up"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "turn-ended-only successor should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_grep "successor readiness could not be proven" "$artifact" "failure artifact should explain missing readiness"
  pass "successor rejects bare turn-ended readiness"
}

test_successor_halts_without_readiness_and_keeps_predecessor_active() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff status halt artifact
  home="$TMP_ROOT/not-ready-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/not-ready-spawn.log"
  retire_log="$TMP_ROOT/not-ready-retire.log"
  spawn_double="$TMP_ROOT/not-ready-spawn-double"
  retire_double="$TMP_ROOT/not-ready-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-not-ready.md"
  printf 'handoff for not-ready successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" "mode=no-mistakes" "yolo=off"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-not-ready-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_READY_TIMEOUT=0 \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "successor without readiness should exit 1"
  assert_present "$home/state/demo.meta" "predecessor meta should remain active when readiness is unproven"
  assert_no_grep 'tmux|target-pane' "$retire_log" "predecessor should not retire without readiness"
  assert_absent "$home/state/demo-not-ready-next.meta" "unready successor meta should be cleaned up"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "unready successor should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_grep "successor readiness could not be proven" "$artifact" "failure artifact should explain missing readiness"
  pass "successor halts without readiness and keeps predecessor active"
}

test_successor_failure_restores_claude_predecessor_hook() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff status settings
  home="$TMP_ROOT/restore-claude-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/restore-claude-spawn.log"
  retire_log="$TMP_ROOT/restore-claude-retire.log"
  spawn_double="$TMP_ROOT/restore-claude-spawn-double"
  retire_double="$TMP_ROOT/restore-claude-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree/.claude"
  handoff="$home/fm-state/handoff-restore-claude.md"
  printf 'handoff for Claude hook restore\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=claude" "mode=no-mistakes" "yolo=off"
  settings="$worktree/.claude/settings.local.json"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '\''%s'\''"}]}]}}\n' "$home/state/demo.turn-ended" > "$settings"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-restore-claude-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_WRITE_HOOKS=1 \
    FM_SUCCESSOR_READY_TIMEOUT=0 FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "unready Claude successor should exit 1"
  assert_present "$home/state/demo.meta" "predecessor meta should remain active after Claude successor failure"
  assert_grep '/demo.turn-ended' "$settings" "Claude hook should be restored to predecessor turn-end file"
  assert_no_grep '/demo-restore-claude-next.turn-ended' "$settings" "Claude hook should not remain targeted at failed successor"
  pass "successor failure restores Claude predecessor hook"
}

test_successor_failure_restores_grok_predecessor_pointer() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff status pointer
  home="$TMP_ROOT/restore-grok-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/restore-grok-spawn.log"
  retire_log="$TMP_ROOT/restore-grok-retire.log"
  spawn_double="$TMP_ROOT/restore-grok-spawn-double"
  retire_double="$TMP_ROOT/restore-grok-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-restore-grok.md"
  printf 'handoff for Grok hook restore\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=grok" "mode=no-mistakes" "yolo=off"
  printf '%s\n' "fm.aaaaaaaaaaaa" > "$home/state/demo.grok-turnend-token"
  pointer="$worktree/.fm-grok-turnend"
  printf 'token=%s\n' "fm.aaaaaaaaaaaa" > "$pointer"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  HOME="$home/fake-home" FM_HOME="$home" FM_SUCCESSOR_ID=demo-restore-grok-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_WRITE_HOOKS=1 \
    FM_SUCCESSOR_READY_TIMEOUT=0 FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "unready Grok successor should exit 1"
  assert_present "$home/state/demo.meta" "predecessor meta should remain active after Grok successor failure"
  [ "$(cat "$pointer")" = "token=fm.aaaaaaaaaaaa" ] || fail "Grok pointer should be restored to predecessor token"
  assert_absent "$home/state/demo-restore-grok-next.grok-turnend-token" "failed successor Grok token should be cleaned from state"
  pass "successor failure restores Grok predecessor pointer"
}

test_successor_carries_x_followup_link() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff successor_meta
  home="$TMP_ROOT/xlink-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/xlink-spawn.log"
  retire_log="$TMP_ROOT/xlink-retire.log"
  spawn_double="$TMP_ROOT/xlink-spawn-double"
  retire_double="$TMP_ROOT/xlink-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-x.md"
  printf 'handoff for X-linked successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" \
    "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" \
    "mode=no-mistakes" "yolo=off" "x_request=req-123" "x_request_ts=1770000000" "x_followups=2"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-x-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 \
    FM_SUCCESSOR_DOUBLE_READY=status \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null \
    || fail "X-linked successor spawn should succeed"

  successor_meta="$home/state/demo-x-next.meta"
  assert_grep 'x_request=req-123' "$successor_meta" "successor meta should carry X request id"
  assert_grep 'x_request_ts=1770000000' "$successor_meta" "successor meta should carry original X timestamp"
  assert_grep 'x_followups=2' "$successor_meta" "successor meta should carry consumed follow-up count"
  assert_grep "project=$project" "$successor_meta" "successor meta should preserve predecessor project"
  assert_grep "worktree=$worktree" "$successor_meta" "successor meta should adopt predecessor worktree"
  [ "$(cat "$retire_log")" = "tmux|target-pane" ] || fail "X-linked predecessor should retire after relink"
  pass "successor carries X follow-up link before retiring predecessor"
}

test_successor_halts_when_predecessor_retire_fails() {
  local home project worktree spawn_log retire_log spawn_double retire_double handoff status halt artifact
  home="$TMP_ROOT/retire-fails-home"
  project="$home/project"
  worktree="$home/worktree"
  spawn_log="$TMP_ROOT/retire-fails-spawn.log"
  retire_log="$TMP_ROOT/retire-fails-retire.log"
  spawn_double="$TMP_ROOT/retire-fails-spawn-double"
  retire_double="$TMP_ROOT/retire-fails-retire-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree"
  handoff="$home/fm-state/handoff-retire-fails.md"
  printf 'handoff for retire-failure successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=codex" "mode=no-mistakes" "yolo=off"
  printf '%s\n' 'echo merged' > "$home/state/demo.check.sh"
  make_spawn_double "$spawn_double" "$spawn_log" 0
  make_retire_double "$retire_double" "$retire_log"

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-retire-fails-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_READY=status \
    FM_SUCCESSOR_RETIRE_CMD="$retire_double" FM_SUCCESSOR_RETIRE_LOG="$retire_log" FM_SUCCESSOR_RETIRE_STATUS=17 \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "retire failure should exit 1"
  assert_present "$home/state/demo.meta" "predecessor meta should remain active after retire failure"
  assert_present "$home/state/demo.check.sh" "predecessor check should remain armed after retire failure"
  assert_absent "$home/state/demo-retire-fails-next.check.sh" "successor check should be cleaned after retire failure"
  assert_absent "$home/state/retired/demo.meta" "predecessor meta should not be archived after retire failure"
  assert_absent "$home/state/demo-retire-fails-next.meta" "successor meta should be cleaned up after retire failure"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "retire failure should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_grep "predecessor retirement failed" "$artifact" "failure artifact should explain retire failure"
  pass "successor halts when predecessor retire fails"
}

test_spawn_failure_writes_halt_flag_and_failure_artifact() {
  local home spawn_log spawn_double handoff status halt artifact
  home="$TMP_ROOT/failure-home"
  spawn_log="$TMP_ROOT/failure-spawn.log"
  spawn_double="$TMP_ROOT/failure-spawn-double"
  mkdir -p "$home/state" "$home/fm-state"
  handoff="$home/fm-state/handoff-latest.md"
  printf 'handoff for failing spawn\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$home" "worktree=$home" "backend=tmux" "harness=claude" "mode=no-mistakes" "yolo=off"
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

test_partial_spawn_failure_cleans_successor_and_restores_hook() {
  local home project worktree spawn_log spawn_double handoff status halt artifact settings
  home="$TMP_ROOT/partial-failure-home"
  project="$TMP_ROOT/partial-failure-project"
  worktree="$TMP_ROOT/partial-failure-worktree"
  spawn_log="$TMP_ROOT/partial-failure-spawn.log"
  spawn_double="$TMP_ROOT/partial-failure-spawn-double"
  mkdir -p "$home/state" "$home/fm-state" "$project" "$worktree/.claude"
  handoff="$home/fm-state/handoff-partial-failure.md"
  printf 'handoff for partial failing spawn\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$project" "worktree=$worktree" "backend=tmux" "harness=claude" "mode=no-mistakes" "yolo=off"
  make_spawn_double "$spawn_double" "$spawn_log" 23

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-partial-fails FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" FM_SUCCESSOR_DOUBLE_CREATE_META=1 FM_SUCCESSOR_DOUBLE_WRITE_HOOKS=1 \
    "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "partial failed successor spawn should exit 1"
  assert_present "$home/state/demo.meta" "predecessor meta should remain active after partial spawn failure"
  assert_absent "$home/state/demo-partial-fails.meta" "partial successor meta should be cleaned after spawn failure"
  assert_absent "$home/state/demo-partial-fails.status" "partial successor status should be cleaned after spawn failure"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "partial failed successor spawn should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_grep "spawn failed" "$artifact" "failure artifact should explain partial spawn failure"
  settings="$worktree/.claude/settings.local.json"
  assert_grep '/demo.turn-ended' "$settings" "Claude hook should be restored to predecessor after partial spawn failure"
  assert_no_grep '/demo-partial-fails.turn-ended' "$settings" "Claude hook should not remain targeted at failed successor"
  pass "partial spawn failure cleans successor and restores hook"
}

test_invalid_x_link_halts_before_spawn() {
  local home spawn_log spawn_double handoff status halt artifact
  home="$TMP_ROOT/invalid-xlink-home"
  spawn_log="$TMP_ROOT/invalid-xlink-spawn.log"
  spawn_double="$TMP_ROOT/invalid-xlink-spawn-double"
  mkdir -p "$home/state" "$home/fm-state"
  handoff="$home/fm-state/handoff-invalid-x.md"
  printf 'handoff for invalid X-linked successor\n' > "$handoff"
  fm_write_meta "$home/state/demo.meta" \
    "window=target-pane" "project=$home" "worktree=$home" "backend=tmux" "harness=codex" \
    "mode=no-mistakes" "yolo=off" "x_request=../bad" "x_request_ts=1770000000" "x_followups=2"
  make_spawn_double "$spawn_double" "$spawn_log" 0

  FM_HOME="$home" FM_SUCCESSOR_ID=demo-invalid-x-next FM_SUCCESSOR_SPAWN_CMD="$spawn_double" \
    FM_SUCCESSOR_SPAWN_LOG="$spawn_log" "$ROOT/bin/fm-successor.sh" demo "$handoff" >/dev/null 2>&1
  status=$?
  expect_code 1 "$status" "invalid predecessor X link should exit 1"
  [ ! -s "$spawn_log" ] || fail "invalid predecessor X link should halt before spawning successor"
  halt="$home/fm-state/watchdog.halt"
  assert_present "$halt" "invalid predecessor X link should set halt flag"
  artifact=$(sed -n 's/^artifact=//p' "$halt")
  assert_grep "predecessor X link invalid" "$artifact" "failure artifact should explain invalid X link"
  pass "invalid predecessor X link halts before spawn"
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
  mkdir -p "$home/state" "$home/fm-state" "$home/data/demo" "$worktree"
  handoff="$home/fm-state/handoff-latest.md"
  printf 'threshold handoff\n' > "$handoff"
  printf 'Threshold original objective marker.\n' > "$home/data/demo/brief.md"
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
  assert_contains "$(cat "$generated_handoff")" "Original Brief" "unique successor handoff should include original brief section"
  assert_contains "$(cat "$generated_handoff")" "Threshold original objective marker." "unique successor handoff should embed predecessor brief"
  assert_contains "$(cat "$handoff")" "Reason: clear_rotated." "successor handoff should be refreshed for the current trigger"
  if grep -q 'threshold handoff' "$handoff"; then
    fail "successor handoff should not reuse stale content"
  fi
  pass "watch loop clear rotation starts successor and exits when halted"
}

test_watch_loop_skips_orca_successor_threshold() {
  local home config session_dir worktree spawn_log spawn_double timeout_cmd orca_fakebin status event
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping Orca successor-skip coverage"
    return
  fi
  home="$TMP_ROOT/watch-orca-skip-home"
  config="$TMP_ROOT/watch-orca-skip-config"
  session_dir="$TMP_ROOT/watch-orca-skip-sessions"
  worktree="$TMP_ROOT/watch-orca-skip-worktree"
  spawn_log="$TMP_ROOT/watch-orca-skip-spawn.log"
  spawn_double="$TMP_ROOT/watch-orca-skip-spawn-double"
  orca_fakebin=$(make_orca_terminal_fakebin "$TMP_ROOT/watch-orca-tools")
  mkdir -p "$home/state" "$home/fm-state" "$worktree"
  fm_write_meta "$home/state/demo.meta" \
    "window=fm-demo" "terminal=term-demo" "project=$worktree" "worktree=$worktree" \
    "backend=orca" "harness=codex"
  write_successor_config "$config" 90 95
  write_codex_rollout "$session_dir/rollout-demo.jsonl" "$worktree" 960 old-sid
  make_spawn_double "$spawn_double" "$spawn_log" 23

  "$timeout_cmd" 1 env PATH="$orca_fakebin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_SUCCESSOR_ID=demo-orca-next \
    FM_SUCCESSOR_SPAWN_CMD="$spawn_double" FM_SUCCESSOR_SPAWN_LOG="$spawn_log" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial Orca watcher pass should arm the session"

  "$timeout_cmd" 1 env PATH="$orca_fakebin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" \
    FM_WATCHDOG_CODEX_SESSION_DIR="$session_dir" FM_SUCCESSOR_ID=demo-orca-next \
    FM_SUCCESSOR_SPAWN_CMD="$spawn_double" FM_SUCCESSOR_SPAWN_LOG="$spawn_log" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "Orca successor threshold should be skipped without halting"
  assert_absent "$home/fm-state/watchdog.halt" "Orca successor skip should not halt the watcher"
  [ ! -s "$spawn_log" ] || fail "Orca successor skip should not invoke fm-successor"
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"successor_threshold","sid":"demo","status":"skipped"' "$event" "Orca successor threshold should be logged as skipped"
  assert_grep 'backend=orca' "$event" "Orca successor skip event should name the backend"
  pass "watch loop skips Orca successor threshold"
}

test_watch_loop_clear_rotation_detects_claude_same_file_compaction() {
  local home config session_dir checkpoint_dir project_dir session_file worktree steer_log steer_double spawn_log spawn_double pending status event timeout_cmd project_key generated_handoff
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  else
    pass "timeout helper unavailable; skipping Claude same-file clear coverage"
    return
  fi
  home="$TMP_ROOT/watch-claude-clear-home"
  config="$TMP_ROOT/watch-claude-clear-config"
  session_dir="$TMP_ROOT/watch-claude-clear-sessions"
  checkpoint_dir="$TMP_ROOT/watch-claude-clear-checkpoints"
  worktree="$TMP_ROOT/watch-claude-clear-worktree"
  steer_log="$TMP_ROOT/watch-claude-clear-steer.log"
  steer_double="$TMP_ROOT/watch-claude-clear-steer-double"
  spawn_log="$TMP_ROOT/watch-claude-clear-spawn.log"
  spawn_double="$TMP_ROOT/watch-claude-clear-spawn-double"
  mkdir -p "$home/state" "$home/fm-state" "$home/data/demo" "$worktree"
  printf 'Claude same-file successor objective.\n' > "$home/data/demo/brief.md"
  fm_write_meta "$home/state/demo.meta" "window=target-pane" "project=$worktree" "worktree=$worktree" "backend=tmux" "harness=claude"
  write_successor_config "$config" 90 95
  project_key=$(bash -c '. "$1"; fm_watchdog_claude_project_key "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$worktree")
  project_dir="$session_dir/$project_key"
  session_file="$project_dir/claude-sid.jsonl"
  write_claude_jsonl "$session_file" claude-sid compact-before
  write_claude_checkpoint "$checkpoint_dir" claude-sid 96
  make_steer_success_double "$steer_double" "$steer_log"
  make_spawn_double "$spawn_double" "$spawn_log" 23

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$steer_double" \
    FM_STEER_DOUBLE_LOG="$steer_log" FM_SUCCESSOR_ID=demo-claude-clear-next \
    FM_SUCCESSOR_SPAWN_CMD="$spawn_double" FM_SUCCESSOR_SPAWN_LOG="$spawn_log" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "initial Claude clear-threshold watcher pass should arm the session"

  "$timeout_cmd" 1 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$steer_double" \
    FM_STEER_DOUBLE_LOG="$steer_log" FM_SUCCESSOR_ID=demo-claude-clear-next \
    FM_SUCCESSOR_SPAWN_CMD="$spawn_double" FM_SUCCESSOR_SPAWN_LOG="$spawn_log" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 124 "$status" "Claude clear-threshold watcher pass should steer clear"
  pending="$home/state/watchdog/.clear-pending-demo"
  for _ in $(seq 1 20); do
    [ -s "$pending" ] && break
    sleep 0.1
  done
  assert_present "$pending" "successful Claude clear steer should leave pending marker"
  assert_contains "$(cat "$pending")" "compact-before" "clear pending marker should record pre-clear compact generation"

  write_claude_jsonl "$session_file" claude-sid compact-after
  "$timeout_cmd" 5 env FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_WATCHDOG_CLAUDE_SESSION_DIR="$session_dir" \
    FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR="$checkpoint_dir" FM_STEER_BACKEND_CMD="$steer_double" \
    FM_STEER_DOUBLE_LOG="$steer_log" FM_SUCCESSOR_ID=demo-claude-clear-next \
    FM_SUCCESSOR_SPAWN_CMD="$spawn_double" FM_SUCCESSOR_SPAWN_LOG="$spawn_log" \
    FM_POLL=30 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "same-file Claude clear rotation should attempt successor and exit after halt"
  event="$home/fm-state/watchdog.events"
  assert_grep '"type":"clear_rotated","sid":"demo","status":"successor_takeover"' "$event" "same-file Claude clear rotation should be logged"
  assert_contains "$(cat "$event")" "compact_generation=compact-after" "clear rotation event should name the new compact generation"
  assert_grep '"type":"successor_spawn_failed","sid":"demo","status":"halted"' "$event" "same-file Claude clear spawn failure should halt through watch loop"
  generated_handoff=$(jq -r 'select(.type == "successor_threshold") | .detail | capture("handoff=(?<handoff>[^ ]+)").handoff' "$event" | tail -1)
  [ -n "$generated_handoff" ] || fail "same-file Claude clear event should record generated handoff"
  assert_present "$generated_handoff" "same-file Claude clear path should create unique handoff"
  assert_contains "$(cat "$generated_handoff")" "Reason: clear_rotated." "same-file Claude handoff should name clear rotation"
  pass "watch loop clear rotation detects Claude same-file compaction"
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
  assert_contains "$(cat "$generated_handoff")" "Original Brief" "rc4 generated handoff should include original brief section"
  assert_contains "$(cat "$generated_handoff")" "was not present" "missing rc4 original brief should be explicit"
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
test_successor_preserves_scout_and_pr_metadata
test_successor_carries_predecessor_check_script
test_successor_rejects_orca_backend_before_spawn
test_successor_accepts_backend_endpoint_readiness
test_successor_rejects_dead_agent_endpoint_readiness
test_successor_rejects_bare_turnend_readiness
test_successor_halts_without_readiness_and_keeps_predecessor_active
test_successor_failure_restores_claude_predecessor_hook
test_successor_failure_restores_grok_predecessor_pointer
test_successor_carries_x_followup_link
test_successor_halts_when_predecessor_retire_fails
test_spawn_failure_writes_halt_flag_and_failure_artifact
test_partial_spawn_failure_cleans_successor_and_restores_hook
test_invalid_x_link_halts_before_spawn
test_watch_loop_clear_rotation_starts_successor_and_exits_when_halted
test_watch_loop_skips_orca_successor_threshold
test_watch_loop_clear_rotation_detects_claude_same_file_compaction
test_steer_rc4_escalates_to_successor

echo "# all watchdog successor tests passed"
