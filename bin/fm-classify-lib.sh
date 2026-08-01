#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, deliberate-hold vocabulary, and the working/parked absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# Deliberate holds are a representable state: state/<id>.parked, written only by
# bin/fm-park.sh (and the thin fm-held-gate-mark.sh wrapper). Absorb of idle-pane
# wedge noise keys on that marker alone - never on secondary run-step shapes or
# status-verb corroboration. The absorb classification (crew_absorb_class) still
# may call bin/fm-crew-state.sh for the separate "provably working" decision.
# Callers run it ONLY on no-verb signal handling and first sighting of a stale
# hash, never on every wake, so the per-wake triage stays cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a deliberate hold. Far longer than the wedge
# threshold (FM_STALE_ESCALATE_SECS, default 240s) so an expected wait is not
# nagged like a wedge, yet finite so a forgotten hold cannot rot invisibly - it
# re-surfaces once for a recheck every window. One hour by default; both consumers
# read FM_PAUSE_RESURFACE_SECS with this default so the cadence has one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. status_open_decisions is the ONE
# authoritative statement of the status-fold contract: a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}


# Firstmate-owned deliberate-hold marker. One path, one writer (bin/fm-park.sh).
# JSON fields: reason, parked_at, recheck_secs, optional until.
parked_marker() {  # <id>
  printf '%s/%s.parked' "${STATE:-${FM_STATE_OVERRIDE:-}}" "$1"
}

# Back-compat alias: older call sites and tests may still say "held gate marker".
# The physical file is always state/<id>.parked.
held_gate_marker() {  # <id>
  parked_marker "$1"
}

crew_line_is_ask_user_gate() {  # <fm-crew-state line>
  case "$1" in
    'state: parked '*'source: run-step '*'ask-user: captain decision'*) return 0 ;;
    *) return 1 ;;
  esac
}

crew_current_state_line() {  # <id>
  local line
  line=$("$FM_CREW_STATE_BIN" "$1" 2>/dev/null) || true
  case "$line" in state:*) printf '%s' "$line" ;; esac
}

# 0 if state/<id>.parked exists (the primary deliberate-hold fact).
crew_is_parked() {  # <id>
  local id=$1 marker
  [ -n "$id" ] || return 1
  marker=$(parked_marker "$id")
  [ -e "$marker" ]
}

# Print the park marker's reason, or empty when absent/unreadable.
crew_parked_reason() {  # <id>
  local marker reason
  marker=$(parked_marker "$1")
  [ -e "$marker" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    reason=$(jq -r '.reason // empty' "$marker" 2>/dev/null) || reason=
  else
    reason=
  fi
  printf '%s' "$reason"
}

# Print recheck_secs from the marker, falling back to FM_PAUSE_RESURFACE_SECS default.
crew_parked_recheck_secs() {  # <id>
  local marker secs default
  default=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
  marker=$(parked_marker "$1")
  if [ -e "$marker" ] && command -v jq >/dev/null 2>&1; then
    secs=$(jq -r '.recheck_secs // empty' "$marker" 2>/dev/null) || secs=
    case "$secs" in
      ''|*[!0-9]*) secs=$default ;;
    esac
  else
    secs=$default
  fi
  printf '%s' "$secs"
}

# Print parked_at epoch from the marker, or empty when absent.
crew_parked_at() {  # <id>
  local marker at
  marker=$(parked_marker "$1")
  [ -e "$marker" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    at=$(jq -r '.parked_at // empty' "$marker" 2>/dev/null) || at=
  else
    at=
  fi
  printf '%s' "$at"
}

# Write state/<id>.parked atomically. Args: id reason recheck_secs [until].
# Intended for bin/fm-park.sh; other callers should use that CLI.
park_write() {  # <id> <reason> <recheck_secs> [until]
  local id=$1 reason=$2 recheck=$3 until=${4:-} marker tmp now st
  [ -n "$id" ] || return 1
  st=${STATE:-${FM_STATE_OVERRIDE:-}}
  [ -n "$st" ] || return 1
  mkdir -p "$st" || return 1
  marker=$(parked_marker "$id")
  now=$(date +%s)
  tmp="${marker}.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    if [ -n "$until" ]; then
      jq -n \
        --arg reason "$reason" \
        --argjson parked_at "$now" \
        --argjson recheck_secs "$recheck" \
        --argjson until "$until" \
        '{reason:$reason, parked_at:$parked_at, recheck_secs:$recheck_secs, until:$until}' \
        > "$tmp" || { rm -f "$tmp"; return 1; }
    else
      jq -n \
        --arg reason "$reason" \
        --argjson parked_at "$now" \
        --argjson recheck_secs "$recheck" \
        '{reason:$reason, parked_at:$parked_at, recheck_secs:$recheck_secs}' \
        > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
  else
    # Fail closed without jq: park is a JSON contract.
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$marker"
}

park_clear() {  # <id>
  local id=$1 marker
  [ -n "$id" ] || return 1
  marker=$(parked_marker "$id")
  rm -f "$marker"
  # Remove the legacy held-for-captain path if a pre-migration marker remains.
  rm -f "${STATE:-${FM_STATE_OVERRIDE:-}}/${id}.held-for-captain"
}

# Gate-relay hook: after a captain-relevant status is durably surfaced, record a
# park only when the authoritative run-step proves it is an ask-user gate.
# The run-step check is this wrapper's own precondition; the marker itself needs
# none for absorb (crew_absorb_class keys on marker presence alone).
mark_held_gate_if_verified() {  # <id>
  local id=$1 line recheck
  [ -n "$id" ] || return 1
  line=$(crew_current_state_line "$id")
  if crew_line_is_ask_user_gate "$line"; then
    recheck=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
    park_write "$id" "held for captain at ask-user gate" "$recheck" ""
    return 0
  fi
  park_clear "$id"
  return 1
}

# 0 if a park marker is present for a still-verified ask-user gate; clears the
# marker when the run-step no longer verifies the gate. Absorb no longer requires
# this re-check - prefer crew_is_parked - but held-gate write and resume cleanup
# still use it.
held_gate_is_verified() {  # <id>
  local id=$1 line
  [ -n "$id" ] || return 1
  crew_is_parked "$id" || return 1
  line=$(crew_current_state_line "$id")
  if crew_line_is_ask_user_gate "$line"; then
    return 0
  fi
  # Only clear when the marker reason is the held-gate reason, so a capacity or
  # external-wait park is not wiped by a non-gate run-step.
  case "$(crew_parked_reason "$id")" in
    'held for captain at ask-user gate')
      park_clear "$id"
      ;;
  esac
  return 1
}

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  if [ -n "${FM_CAPTAIN_RE+x}" ]; then
    printf '%s' "$line" | grep -qiE "$FM_CAPTAIN_RE"
    return
  fi
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
  esac
  printf '%s' "$line" | grep -qiE "$FM_CLASSIFY_CAPTAIN_RE_DEFAULT"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=${line%%:*}
  verb=${verb#"${verb%%[![:space:]]*}"}
  verb=${verb%"${verb##*[![:space:]]}"}
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced.
# Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - state/<id>.parked is present. Firstmate wrote that marker via
#             bin/fm-park.sh for ANY deliberate hold (external wait, held ask-user
#             gate, capacity backoff, board poll, ...). Marker presence alone is
#             the absorb fact - no run-step shape or status-verb corroboration.
#             Captain-relevant STATUS SIGNALS still wake through the signal path
#             regardless of this class (park suppresses idle-pane wedge noise only);
#   none    - neither, so the wake must surface (a stopped crew with no park
#             marker, or unreadable verdict). A stopped crew without a marker is
#             NEVER silently absorbed.
# Working evidence outranks a stale park marker so a crew that resumed after a
# hold is never mis-absorbed as paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call for the
# working decision, so callers run it only on no-verb signal and first-sighting
# stale paths, never every wake. FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$(crew_current_state_line "$id")
  if [ -n "$line" ]; then
    state=${line#state: }; state=${state%% *}
    if [ "$state" = working ]; then
      src=${line#*source: }; src=${src%% *}
      case "$src" in
        run-step|pane)
          printf 'working'
          return
          ;;
      esac
    fi
  fi
  if crew_is_parked "$id"; then
    printf 'paused'
    return
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id> is deliberately held via state/<id>.parked (crew_absorb_class
# reports `paused`). The stale path absorbs such a crew on the marker's recheck
# cadence instead of escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
