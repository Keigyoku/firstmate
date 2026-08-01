#!/usr/bin/env bash
# tests/fm-park.test.sh - structural deliberate-hold absorb (state/<id>.parked).
#
# Closes the watcher absorb class that keyed eligibility on secondary fields
# (run-step shape, status-verb corroboration, one-off markers). One marker, one
# writer (bin/fm-park.sh); absorb keys on marker presence alone.
#
# Historical escapes (RED on pre-fix main; GREEN with the park marker):
#   - parked reviewer, cancelled/no run + declared pause → stale without marker
#   - needs-decision board poller idle pane → repeated stale without marker
#   - capacity-backoff crew → stale without marker
#   - held ask-user gate → same absorb as former held-for-captain (no regression)
#   - parked crew whose status then gains done:/blocked: → still wakes (signal)
#   - stopped crew with NO marker → still wakes (never absorbed)
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
PARK="$ROOT/bin/fm-park.sh"
HELD_MARK="$ROOT/bin/fm-held-gate-mark.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-park-tests)

watch_bg() {
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# hash_text / wait_for_exit come from wake-helpers.sh

# --- park CLI + marker schema ----------------------------------------------

test_park_cli_writes_and_clears_json_marker() {
  local dir state marker parked_at rechecked
  dir=$(make_case park-cli); state="$dir/state"
  export FM_STATE_OVERRIDE="$state"
  printf 'window=test:fm-a\nkind=ship\n' > "$state/a.meta"
  "$PARK" a --reason 'capacity backoff' --recheck 1800 \
    || fail "fm-park.sh failed to write marker"
  marker="$state/a.parked"
  [ -e "$marker" ] || fail "park marker not written at $marker"
  command -v jq >/dev/null 2>&1 || fail "jq required for park tests"
  [ "$(jq -r .reason "$marker")" = 'capacity backoff' ] || fail "reason not stored"
  [ "$(jq -r .recheck_secs "$marker")" = '1800' ] || fail "recheck_secs not stored"
  case "$(jq -r .parked_at "$marker")" in ''|*[!0-9]*) fail "parked_at not an epoch" ;; esac
  crew_is_parked a || fail "crew_is_parked false after park write"
  [ "$(crew_parked_reason a)" = 'capacity backoff' ] || fail "crew_parked_reason mismatch"
  [ "$(crew_parked_recheck_secs a)" = '1800' ] || fail "crew_parked_recheck_secs mismatch"
  parked_at=$(crew_parked_at a)
  rechecked=$(( parked_at + 1 ))
  crew_parked_recheck_advance a "$rechecked" || fail "shared recheck epoch write failed"
  [ "$(crew_parked_recheck_epoch a)" = "$rechecked" ] || fail "shared recheck epoch mismatch"
  "$PARK" --clear a || fail "fm-park.sh --clear failed"
  [ ! -e "$marker" ] || fail "park marker remained after --clear"
  [ ! -e "$(park_recheck_marker a)" ] || fail "shared recheck epoch remained after --clear"
  ! crew_is_parked a || fail "crew_is_parked true after clear"
  unset FM_STATE_OVERRIDE
  pass "fm-park.sh writes JSON state/<id>.parked and --clear removes it"
}

test_park_cli_rejects_zero_recheck() {
  local dir state err
  dir=$(make_case park-zero); state="$dir/state"; err="$dir/err"
  printf 'window=test:fm-zero\nkind=ship\n' > "$state/zero.meta"
  if FM_STATE_OVERRIDE="$state" "$PARK" zero --recheck 0 2> "$err"; then
    fail "fm-park.sh accepted --recheck 0"
  fi
  grep -F -- '--recheck must be a positive integer seconds' "$err" >/dev/null \
    || fail "fm-park.sh zero rejection was unclear: $(cat "$err")"
  [ ! -e "$state/zero.parked" ] || fail "zero recheck wrote a park marker"
  if FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=0 "$PARK" zero 2> "$err"; then
    fail "fm-park.sh accepted a zero default recheck"
  fi
  [ ! -e "$state/zero.parked" ] || fail "zero default recheck wrote a park marker"
  pass "fm-park.sh rejects zero recheck intervals"
}

# Escape: parked reviewer with cancelled/no run + declared pause trips stale on
# main without a marker; with the marker it is absorbed as paused.
test_parked_reviewer_cancelled_or_no_run_absorbs_with_marker() {
  local dir fakebin state
  dir=$(make_case park-reviewer); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE
  printf 'window=test:fm-reviewer\nkind=ship\n' > "$state/reviewer.meta"
  printf 'paused: holding for captain review smoke\n' > "$state/reviewer.status"

  # Without marker: cancelled/parked/unknown must NOT absorb (no secondary corroboration).
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  [ "$(crew_absorb_class reviewer)" = none ] \
    || fail "unmarked parked reviewer absorbed via secondary fields: $(crew_absorb_class reviewer)"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no run'
  [ "$(crew_absorb_class reviewer)" = none ] \
    || fail "unmarked no-run reviewer absorbed: $(crew_absorb_class reviewer)"
  FM_FAKE_CREW_STATE='state: cancelled · source: run-step · run cancelled'
  [ "$(crew_absorb_class reviewer)" = none ] \
    || fail "unmarked cancelled+paused absorbed without park marker: $(crew_absorb_class reviewer)"

  # With marker: absorbed regardless of run-step shape.
  park_write reviewer 'holding for captain review smoke' 3600
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  [ "$(crew_absorb_class reviewer)" = paused ] \
    || fail "parked marker + parked run not classed paused: $(crew_absorb_class reviewer)"
  FM_FAKE_CREW_STATE='state: cancelled · source: run-step · run cancelled'
  [ "$(crew_absorb_class reviewer)" = paused ] \
    || fail "parked marker + cancelled run not classed paused: $(crew_absorb_class reviewer)"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no run'
  [ "$(crew_absorb_class reviewer)" = paused ] \
    || fail "parked marker + no run not classed paused: $(crew_absorb_class reviewer)"
  crew_is_paused reviewer || fail "crew_is_paused missed park marker"

  unset FM_STATE_OVERRIDE FM_FAKE_CREW_STATE
  pass "parked reviewer: marker absorbs cancelled/no-run; unmarked never absorbs via secondary fields"
}

# Escape: needs-decision board poller with idle pane trips stale; marker absorbs.
test_needs_decision_board_poller_absorbs_with_marker() {
  local dir fakebin state
  dir=$(make_case park-poller); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  printf 'window=test:fm-poller\nkind=ship\n' > "$state/poller.meta"
  printf 'paused: polling board for captain merge word\n' > "$state/poller.status"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle poller'
  [ "$(crew_absorb_class poller)" = none ] \
    || fail "unmarked poller absorbed: $(crew_absorb_class poller)"
  park_write poller 'polling board for captain merge word' 3600
  [ "$(crew_absorb_class poller)" = paused ] \
    || fail "marker did not absorb board poller: $(crew_absorb_class poller)"
  unset FM_STATE_OVERRIDE FM_FAKE_CREW_STATE
  pass "needs-decision board poller absorbs only with park marker"
}

# Escape: capacity-backoff crew trips stale; marker absorbs.
test_capacity_backoff_absorbs_with_marker() {
  local dir fakebin state
  dir=$(make_case park-capacity); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  printf 'window=test:fm-cap\nkind=ship\n' > "$state/cap.meta"
  printf 'paused: capacity backoff until quota reset\n' > "$state/cap.status"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · capacity'
  [ "$(crew_absorb_class cap)" = none ] \
    || fail "unmarked capacity crew absorbed: $(crew_absorb_class cap)"
  park_write cap 'capacity backoff until quota reset' 7200
  [ "$(crew_absorb_class cap)" = paused ] \
    || fail "capacity park marker not classed paused: $(crew_absorb_class cap)"
  [ "$(crew_parked_recheck_secs cap)" = '7200' ] || fail "capacity recheck_secs not honored"
  unset FM_STATE_OVERRIDE FM_FAKE_CREW_STATE
  pass "capacity-backoff crew absorbs only with park marker"
}

# Held ask-user gate: fm-held-gate-mark writes the same park marker; absorb works.
test_held_ask_user_gate_writes_park_marker() {
  local dir fakebin state
  dir=$(make_case park-held-gate); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  printf 'window=test:fm-held\nkind=ship\n' > "$state/held.meta"
  printf 'needs-decision: choose review finding resolution\n' > "$state/held.status"
  export FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 1 finding(s) (ask-user: captain decision)'
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" "$HELD_MARK" held \
    || fail "fm-held-gate-mark.sh failed on verified ask-user gate"
  [ -e "$state/held.parked" ] || fail "held-gate mark did not write state/<id>.parked"
  [ ! -e "$state/held.held-for-captain" ] || fail "legacy held-for-captain file should not be written"
  [ "$(crew_parked_reason held)" = 'held for captain at ask-user gate' ] \
    || fail "held-gate reason wrong: $(crew_parked_reason held)"
  [ "$(crew_absorb_class held)" = paused ] \
    || fail "held-gate park not classed paused: $(crew_absorb_class held)"
  # Post-write run-step changes do not revalidate or clear the durable marker.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (fixing)'
  [ "$(crew_absorb_class held)" = paused ] \
    || fail "held-gate marker lost authority after run-step changed"
  [ -e "$state/held.parked" ] || fail "held-gate park cleared by post-write run-step state"
  unset FM_STATE_OVERRIDE FM_FAKE_CREW_STATE
  pass "held ask-user gate marker remains authoritative until structural clear"
}

test_failed_held_gate_mark_preserves_existing_park() {
  local dir fakebin state
  dir=$(make_case held-gate-failure); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  printf 'window=test:fm-held-failure\nkind=ship\n' > "$state/held-failure.meta"
  park_write held-failure 'capacity backoff' 7200
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  mark_held_gate_if_verified held-failure && fail "non-gate run-step passed held-gate verification"
  [ -e "$state/held-failure.parked" ] || fail "failed held-gate mark deleted an existing park"
  [ "$(crew_parked_reason held-failure)" = 'capacity backoff' ] \
    || fail "failed held-gate mark changed the existing park"
  unset FM_STATE_OVERRIDE FM_FAKE_CREW_STATE
  pass "failed held-gate mark preserves an existing structural park"
}

# Parked crew whose status then gains done:/blocked: still wakes (signal path).
test_parked_crew_captain_relevant_status_still_wakes() {
  local dir state fakebin out drain_out status_file pid sig
  dir=$(make_case park-done-wakes); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  export FM_STATE_OVERRIDE="$state"
  printf 'window=test:fm-task\nkind=ship\n' > "$state/task.meta"
  printf 'paused: holding for external\n' > "$status_file"
  park_write task 'holding for external' 3600
  # Prime .seen so the first status is already consumed; then append done:.
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'paused: holding for external\ndone: PR https://example.test/pr/9\n' > "$status_file"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface done: under park marker"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "done: under park marker did not surface as signal: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "done: under park was not queued"
  # Same for blocked:
  reap "$pid" 2>/dev/null || true
  : > "$out"
  printf 'paused: holding for external\nblocked: needs credentials\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface blocked: under park marker"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "blocked: under park marker did not surface"
  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "captain-relevant status signals wake despite park marker"
}

# Stopped crew with NO marker still wakes (never absorbed).
test_stopped_crew_without_marker_still_wakes() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case park-stopped-surfaces); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-stopped"
  printf 'idle, no hold' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  printf 'working: was implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, no hold")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · stopped'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "stopped crew without marker was absorbed (must surface)"
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "stopped unmarked crew did not surface as stale: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || fail "unmarked stopped crew entered pause tracking"
  unset FM_FAKE_CREW_STATE
  pass "stopped crew with no park marker still wakes"
}

# Integration: parked reviewer stale pane absorbed then resurfaced on cadence.
test_parked_reviewer_stale_absorbed_then_resurfaced() {
  local dir state fakebin out capture_file window key pane_hash sig pid back marker
  dir=$(make_case park-reviewer-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-reviewer-stale"
  export FM_STATE_OVERRIDE="$state"
  printf 'idle at review, cancelled run' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/rev.meta"
  printf 'paused: holding for captain review smoke\n' > "$state/rev.status"
  sig=$(seen_sig "$state/rev.status"); printf '%s' "$sig" > "$state/.seen-rev_status"
  park_write rev 'holding for captain review smoke' 3600
  marker="$state/rev.parked"
  [ -e "$marker" ] || fail "park_write did not create $marker"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at review, cancelled run")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: cancelled · source: run-step · run cancelled'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced a freshly parked cancelled reviewer: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "fresh parked reviewer printed a wake: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "parked reviewer did not enter pause tracking"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "parked reviewer started a wedge timer"; }
  reap "$pid"

  back=$(( $(date +%s) - 500 ))
  # Age past recheck_secs=240 so the second poll re-surfaces once.
  jq --argjson at "$back" '.parked_at=$at | .recheck_secs=240' "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$marker"
  else touch -m -d "@$back" "$marker"; fi
  crew_parked_recheck_advance rev "$(date +%s)"
  : > "$out"
  printf 'idle at review, cancelled run, still waiting' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher duplicated a recent daemon park recheck: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "shared daemon epoch did not throttle watcher recheck"; }
  reap "$pid"

  crew_parked_recheck_advance rev "$back"
  : > "$out"
  printf 'idle at review, cancelled run, still waiting again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface an aged parked reviewer: $(cat "$out")"
  grep -F "holding for captain review smoke" "$out" >/dev/null \
    || fail "parked re-surface omitted hold reason: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "parked reviewer was mislabeled a wedge"
  [ -e "$(park_recheck_marker rev)" ] || fail "shared park recheck epoch missing"
  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "parked reviewer stale is absorbed then re-surfaced once per cadence"
}

# A park marker remains authoritative even if the run-step later reads working.
test_park_marker_outranks_active_run() {
  local dir fakebin state
  dir=$(make_case park-outranked); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  park_write x 'stale hold' 3600
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class x)" = paused ] \
    || fail "active run overrode park marker: $(crew_absorb_class x)"
  unset FM_STATE_OVERRIDE FM_FAKE_CREW_STATE
  pass "park marker outranks post-write run-step state"
}

# --- run -------------------------------------------------------------------

test_park_cli_writes_and_clears_json_marker
test_park_cli_rejects_zero_recheck
test_parked_reviewer_cancelled_or_no_run_absorbs_with_marker
test_needs_decision_board_poller_absorbs_with_marker
test_capacity_backoff_absorbs_with_marker
test_held_ask_user_gate_writes_park_marker
test_failed_held_gate_mark_preserves_existing_park
test_parked_crew_captain_relevant_status_still_wakes
test_stopped_crew_without_marker_still_wakes
test_parked_reviewer_stale_absorbed_then_resurfaced
test_park_marker_outranks_active_run

echo "all fm-park tests passed"
