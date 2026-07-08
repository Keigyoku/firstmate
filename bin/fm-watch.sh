#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# Before each normal wake scan it also runs the session-metrics watchdog, which
# can steer a non-secondmate Claude/Codex task into an unmanned compact cycle
# when configured context thresholds are crossed, or launch a successor when the
# successor threshold is crossed or steering becomes undeliverable.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. While state/.afk exists, the daemon
# owns triage and this watcher queues and exits on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. Only when
#                          NOT provably working does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine re-arm. Unless
#                          afk is active.
#   check: <script>: <out> per-task check output, always actionable
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, re-arm after each printed reason by running
# bin/fm-watch-arm.sh through the harness's tracked background mechanism. Direct
# duplicate invocations of this script still no-op through the watcher singleton
# lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. herdr contributes native semantic busy-state through the
# same poll loop until a future push subscription replaces this default source;
# see bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}
if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
trap 'fm_lock_release "$WATCH_LOCK"' EXIT
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

WATCHDOG_BOOT_CONFIG=$(fm_watchdog_thresholds 2>/dev/null || true)
WATCHDOG_POLL=$(printf '%s' "$WATCHDOG_BOOT_CONFIG" | jq -r '.poll_interval_sec // empty' 2>/dev/null || true)
case "$WATCHDOG_POLL" in ''|null|*[!0-9]*) WATCHDOG_POLL=15 ;; esac
[ "$WATCHDOG_POLL" -gt 0 ] || WATCHDOG_POLL=15
POLL=${FM_POLL:-$WATCHDOG_POLL}       # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly);
# cursor: "ctrl+c to stop" (footer while a turn runs - verified cursor-agent
# 2026.07.01); hermes: "Ctrl+C cancel" (the mid-turn cancel hint in its input bar -
# verified Hermes Agent v0.18.0). All matched case-insensitively.
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|ctrl\+c to stop|Ctrl\+C cancel'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

watchdog_marker_key() {
  printf '%s' "$1" | tr ':/.' '___'
}

watchdog_check_rotation() {  # <task> <harness> <marker-file>
  local task=$1 harness=$2 marker=$3 old_sig old_sid old_generation file sig new_sid generation
  [ -s "$marker" ] || return 0
  old_sig=$(sed -n '1p' "$marker")
  old_sid=$(sed -n '2p' "$marker")
  old_generation=$(sed -n '3p' "$marker")
  file=$(fm_watchdog_session_file "$harness" "$task" 2>/dev/null || true)
  [ -n "$file" ] || return 0
  sig=$(fm_watchdog_file_identity "$file" 2>/dev/null || true)
  [ -n "$sig" ] || return 0
  generation=$(fm_watchdog_compact_generation "$harness" "$file" 2>/dev/null || true)
  if [ "$sig" = "$old_sig" ]; then
    [ -n "$generation" ] || return 0
    [ "$generation" != "$old_generation" ] || return 0
  fi
  new_sid=$(fm_watchdog_session_id_from_file "$harness" "$file" 2>/dev/null || basename "$file")
  fm_watchdog_event compact_rotated "$task" rearmed "old_sid=$old_sid new_sid=$new_sid file=$file compact_generation=$generation"
  fm_watchdog_arm_session "$task" "$harness" "$file"
  printf '%s\n%s\n%s\n' "$old_sig" "$old_sid" "$generation" > "$STATE/watchdog/.compact-handled-$(watchdog_marker_key "$task")"
  rm -f "$marker"
}

watchdog_compact_handled() {
  local handled=$1 sig=$2 generation=$3 handled_sig handled_generation
  handled_sig=$(printf '%s\n' "$handled" | sed -n '1p')
  [ "$handled_sig" = "$sig" ] || return 1
  [ -n "$generation" ] || return 0
  handled_generation=$(printf '%s\n' "$handled" | sed -n '3p')
  [ "$handled_generation" = "$generation" ]
}

watchdog_check_clear_rotation() {  # <task> <harness> <marker-file>
  local task=$1 harness=$2 marker=$3 old_sig old_sid context file sig new_sid
  [ -s "$marker" ] || return 0
  old_sig=$(sed -n '1p' "$marker")
  old_sid=$(sed -n '2p' "$marker")
  context=$(sed -n '3p' "$marker")
  file=$(fm_watchdog_session_file "$harness" "$task" 2>/dev/null || true)
  [ -n "$file" ] || return 0
  sig=$(fm_watchdog_file_identity "$file" 2>/dev/null || true)
  [ -n "$sig" ] || return 0
  [ "$sig" != "$old_sig" ] || return 0
  new_sid=$(fm_watchdog_session_id_from_file "$harness" "$file" 2>/dev/null || basename "$file")
  fm_watchdog_event clear_rotated "$task" successor_takeover "old_sid=$old_sid new_sid=$new_sid file=$file"
  fm_watchdog_arm_session "$task" "$harness" "$file"
  printf '%s\n%s\n' "$old_sig" "$old_sid" > "$STATE/watchdog/.clear-handled-$(watchdog_marker_key "$task")"
  rm -f "$marker"
  watchdog_start_successor "$task" "${context:-unknown}" "clear_rotated"
}

watchdog_steer_inflight() {
  local marker=$1 pid
  [ -s "$marker" ] || return 1
  pid=$(sed -n '1p' "$marker")
  case "$pid" in ''|*[!0-9]*) rm -f "$marker"; return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  rm -f "$marker"
  return 1
}

watchdog_pending_active() {
  local pending=$1 task=$2 retry_sec=$3 key=$4 kind=${5:-compact} age
  [ -s "$pending" ] || return 1
  case "$retry_sec" in ''|null|*[!0-9]*) retry_sec=900 ;; esac
  [ "$retry_sec" -gt 0 ] || retry_sec=900
  age=$(fm_path_age "$pending")
  if [ "$age" -lt "$retry_sec" ]; then
    return 0
  fi
  fm_watchdog_event "${kind}_pending_expired" "$task" retrying "age_sec=$age retry_sec=$retry_sec key=$key"
  rm -f "$pending"
  return 1
}

watchdog_collect_failure() {
  local task=$1 key=$2 interval=$3 err_file=$4 throttle age detail
  case "$interval" in ''|null|*[!0-9]*) interval=300 ;; esac
  [ "$interval" -gt 0 ] || interval=300
  throttle="$STATE/watchdog/.metrics-failure-$key"
  if [ -e "$throttle" ]; then
    age=$(fm_path_age "$throttle")
    [ "$age" -lt "$interval" ] && return 0
  fi
  detail=$(tr '\n' ';' < "$err_file" | sed 's/[[:space:]][[:space:]]*/ /g; s/;*$//' | cut -c 1-300)
  [ -n "$detail" ] || detail="metrics collection failed"
  fm_watchdog_event metrics_collect_failed "$task" throttled "$detail"
  : > "$throttle"
}

watchdog_collect_failure_recent() {
  local key=$1 interval=$2 throttle age
  case "$interval" in ''|null|*[!0-9]*) interval=300 ;; esac
  [ "$interval" -gt 0 ] || interval=300
  throttle="$STATE/watchdog/.metrics-failure-$key"
  [ -e "$throttle" ] || return 1
  age=$(fm_path_age "$throttle")
  [ "$age" -lt "$interval" ]
}

watchdog_start_compact_steer() {
  local task=$1 context=$2 compact=$3 sig=$4 sid=$5 key=$6 pending=$7 inflight=$8 generation=$9 pid
  (
    local rc
    if "$SCRIPT_DIR/fm-steer.sh" "$task" "/compact complete current task, then /compact"; then
      printf '%s\n%s\n%s\n' "$sig" "$sid" "$generation" > "$pending"
    else
      rc=$?
      fm_watchdog_event compact_steer_failed "$task" "rc=$rc" "context_pct=$context threshold=$compact"
      if [ "$rc" -eq 4 ]; then
        watchdog_start_successor "$task" "$context" "steer_undeliverable" "$rc"
      fi
    fi
    rm -f "$inflight"
  ) >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$inflight"
  fm_watchdog_event compact_steer_started "$task" "pid=$pid" "context_pct=$context threshold=$compact key=$key"
}

watchdog_start_clear_steer() {
  local task=$1 context=$2 threshold=$3 sig=$4 sid=$5 key=$6 pending=$7 inflight=$8 pid
  (
    local rc
    if "$SCRIPT_DIR/fm-steer.sh" "$task" "/clear complete current task, then /clear"; then
      printf '%s\n%s\n%s\n' "$sig" "$sid" "$context" > "$pending"
    else
      rc=$?
      fm_watchdog_event clear_steer_failed "$task" "rc=$rc" "context_pct=$context threshold=$threshold"
      if [ "$rc" -eq 4 ]; then
        watchdog_start_successor "$task" "$context" "steer_undeliverable" "$rc"
      fi
    fi
    rm -f "$inflight"
  ) >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$inflight"
  fm_watchdog_event clear_steer_started "$task" "pid=$pid" "context_pct=$context threshold=$threshold key=$key"
}

watchdog_halt_file() {
  printf '%s/fm-state/watchdog.halt\n' "$FM_HOME"
}

watchdog_halted() {
  local halt
  halt=$(watchdog_halt_file)
  [ ! -s "$halt" ] && return 1
  echo "watchdog halted: $(sed -n 's/^reason=//p' "$halt" | head -1)" >&2
  return 0
}

watchdog_start_successor() {
  local task=$1 context=$2 reason=$3 rc=${4:-} handoff latest tmp safe_task ts
  safe_task=$(watchdog_marker_key "$task")
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  handoff="$FM_HOME/fm-state/handoffs/handoff-${safe_task}-${ts}-${$}.md"
  latest="$FM_HOME/fm-state/handoff-latest.md"
  mkdir -p "$(dirname "$handoff")"
  tmp=$(mktemp "${handoff}.tmp.XXXXXX")
  {
    printf '# Watchdog Handoff\n\n'
    printf "Predecessor: \`%s\`.\n" "$task"
    printf 'Reason: %s.\n' "$reason"
    printf 'Context percent: %s.\n' "$context"
    [ -z "$rc" ] || printf 'Steer rc: %s.\n' "$rc"
    printf "Created: \`%s\`.\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  mv "$tmp" "$handoff"
  cp "$handoff" "$latest" 2>/dev/null || true
  fm_watchdog_event successor_threshold "$task" triggered "context_pct=$context reason=$reason handoff=$handoff rc=$rc"
  if "$SCRIPT_DIR/fm-successor.sh" "$task" "$handoff"; then
    fm_watchdog_event successor_complete "$task" succeeded "reason=$reason"
  else
    fm_watchdog_event successor_complete "$task" failed "reason=$reason"
    [ -s "$(watchdog_halt_file)" ] && exit 0
  fi
}

watchdog_meta_target_exists() {
  local meta=$1 task=$2 backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  fm_backend_target_exists "$backend" "$target" "fm-$task"
}

watchdog_threshold_scan() {
  local config compact successor pending_retry failure_interval meta task harness metrics context file sig sid generation key handled pending inflight clear_pending clear_inflight err_file
  watchdog_halted && exit 0
  config=$(fm_watchdog_thresholds 2>/dev/null) || return 0
  compact=$(printf '%s' "$config" | jq -r '.thresholds.compact_at_context_pct // empty' 2>/dev/null || true)
  successor=$(printf '%s' "$config" | jq -r '.thresholds.successor_at_context_pct // empty' 2>/dev/null || true)
  case "$compact" in ''|null|*[!0-9.]* ) compact= ;; esac
  case "$successor" in ''|null|*[!0-9.]* ) successor= ;; esac
  [ -n "$compact$successor" ] || return 0
  pending_retry=$(printf '%s' "$config" | jq -r '.compact_pending_retry_sec // empty' 2>/dev/null || true)
  failure_interval=$(printf '%s' "$config" | jq -r '.metrics_failure_event_interval_sec // empty' 2>/dev/null || true)
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" = secondmate ] && continue
    task=$(basename "$meta")
    task=${task%.meta}
    harness=$(fm_meta_get "$meta" harness)
    [ -n "$harness" ] || continue
    case "$harness" in
      claude|codex) ;;
      *) continue ;;
    esac
    watchdog_meta_target_exists "$meta" "$task" || continue
    key=$(watchdog_marker_key "$task")
    pending="$STATE/watchdog/.compact-pending-$key"
    inflight="$STATE/watchdog/.compact-steering-$key"
    clear_pending="$STATE/watchdog/.clear-pending-$key"
    clear_inflight="$STATE/watchdog/.clear-steering-$key"
    watchdog_check_rotation "$task" "$harness" "$pending"
    watchdog_check_clear_rotation "$task" "$harness" "$clear_pending"
    watchdog_pending_active "$clear_pending" "$task" "$pending_retry" "$key" clear && continue
    watchdog_steer_inflight "$clear_inflight" && continue
    watchdog_pending_active "$pending" "$task" "$pending_retry" "$key" compact && continue
    watchdog_steer_inflight "$inflight" && continue
    file=$(fm_watchdog_session_file "$harness" "$task" 2>/dev/null || true)
    if [ -z "$file" ]; then
      mkdir -p "$STATE/watchdog"
      err_file="$STATE/watchdog/.metrics-error-$key"
      printf 'no %s session file found for %s\n' "$harness" "$task" > "$err_file"
      watchdog_collect_failure "$task" "$key" "$failure_interval" "$err_file"
      rm -f "$err_file"
      continue
    fi
    sig=$(fm_watchdog_file_identity "$file" 2>/dev/null || true)
    [ -n "$sig" ] || continue
    sid=$(fm_watchdog_session_id_from_file "$harness" "$file" 2>/dev/null || basename "$file")
    generation=$(fm_watchdog_compact_generation "$harness" "$file" 2>/dev/null || true)
    if ! fm_watchdog_session_is_armed "$task" "$harness" "$file"; then
      fm_watchdog_arm_session "$task" "$harness" "$file"
      fm_watchdog_event watchdog_session_armed "$task" armed "harness=$harness sid=$sid file=$file"
      continue
    fi
    mkdir -p "$STATE/watchdog"
    err_file="$STATE/watchdog/.metrics-error-$key"
    watchdog_collect_failure_recent "$key" "$failure_interval" && continue
    if ! metrics=$(fm_watchdog_collect_metrics "$harness" "$task" 2>"$err_file"); then
      watchdog_collect_failure "$task" "$key" "$failure_interval" "$err_file"
      rm -f "$err_file"
      continue
    fi
    rm -f "$STATE/watchdog/.metrics-failure-$key"
    rm -f "$err_file"
    [ -n "$metrics" ] || continue
    context=$(jq -r '.context_pct // empty' "$metrics" 2>/dev/null || true)
    case "$context" in ''|null|*[!0-9.]* ) continue ;; esac
    if [ -n "$compact" ] && awk "BEGIN { exit !($context < $compact) }"; then
      handled=$(cat "$STATE/watchdog/.compact-handled-$key" 2>/dev/null || true)
      watchdog_compact_handled "$handled" "$sig" "$generation" && rm -f "$STATE/watchdog/.compact-handled-$key"
    fi
    if [ -n "$successor" ] && awk "BEGIN { exit !($context >= $successor) }"; then
      handled=$(cat "$STATE/watchdog/.clear-handled-$key" 2>/dev/null || true)
      [ "$(printf '%s\n' "$handled" | sed -n '1p')" = "$sig" ] && continue
      fm_watchdog_event clear_threshold "$task" triggered "context_pct=$context threshold=$successor sid=$sid"
      watchdog_start_clear_steer "$task" "$context" "$successor" "$sig" "$sid" "$key" "$clear_pending" "$clear_inflight"
      continue
    fi
    [ -n "$compact" ] || continue
    awk "BEGIN { exit !($context >= $compact) }" || continue
    handled=$(cat "$STATE/watchdog/.compact-handled-$key" 2>/dev/null || true)
    watchdog_compact_handled "$handled" "$sig" "$generation" && continue
    fm_watchdog_event compact_threshold "$task" triggered "context_pct=$context threshold=$compact sid=$sid"
    watchdog_start_compact_steer "$task" "$context" "$compact" "$sig" "$sid" "$key" "$pending" "$inflight" "$generation"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine re-arm. Reset wherever a window's pane/hash
# state resets to genuinely active (see the two rm-on-reset call sites below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check() {
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  watchdog_threshold_scan

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      out=$(run_check "$c")
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    # A secondmate idling on its own watcher is healthy. Its parent supervises
    # it through status writes and heartbeats, not pane-idle staleness.
    [ "$(window_kind "$w")" = secondmate ] && continue
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Absorb-only-when-provably-working, decided once per distinct stale hash
          # (the costly run-step read runs only on first sight, never every poll):
          #   - provably working: an actively-running pipeline legitimately sits on a
          #     static pane (e.g. waiting on CI), so absorb and start the wedge timer
          #     so a genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - NOT provably working: no running pipeline, idle pane, no busy
          #     signature - the crew has STOPPED. Surface immediately so firstmate
          #     peeks (it may be done via an interactive menu that wrote no done:
          #     status, waiting on a decision, or wedged) instead of leaving the
          #     finish to wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed non-terminal stale (provably working): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              wake "stale: $w"
            fi
          else
            wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
          fi
        fi
      else
        # Pane busy or not yet stably stale: it is alive, so clear any pending
        # stale escalation timer and the consecutive wedge-escalation count.
        rm -f "$ssf" "$ewf"
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      # Pane content changed: the crew is active again, so reset the escalation
      # timer and the consecutive wedge-escalation count.
      rm -f "$ssf" "$ewf"
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  sleep "$POLL"
done
