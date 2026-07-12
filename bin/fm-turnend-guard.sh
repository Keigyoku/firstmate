#!/usr/bin/env bash
# Primary turn-end guard for the firstmate PRIMARY session only.
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode, pi, and grok adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, any
# crewmate/scout task worktree spawned to work on firstmate itself (the
# recursive "firstmate improving itself" case), and every secondmate home
# (treehouse-leased or git-cloned). It must therefore scope itself to the
# PRIMARY at runtime and stay a silent, fast no-op everywhere else.
#
# Loop-guard: never block twice in the same turn. Claude Code and codex Stop
# payloads carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow
# the stop, whether or not watcher supervision actually got resumed. Passive
# harness adapters provide their own one-follow-up guard before calling this
# script.
# That bounds this to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

INPUT_CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR-<unset>}
INPUT_FM_HOME=${FM_HOME-<unset>}
INPUT_PWD=${PWD-<unset>}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT=${FM_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-}}
if [ -z "$FM_ROOT" ]; then
  PWD_ROOT=$(pwd -P 2>/dev/null || true)
  if [ -f "$PWD_ROOT/AGENTS.md" ] && [ -f "$PWD_ROOT/bin/fm-turnend-guard.sh" ]; then
    FM_ROOT=$PWD_ROOT
  else
    FM_ROOT=$SCRIPT_ROOT
  fi
fi
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
LOCK_SETTLE=${FM_TURNEND_LOCK_SETTLE:-1}

[ "$(cat "$CONFIG/turnend-guard" 2>/dev/null || true)" = off ] && exit 0

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- scope precisely to the PRIMARY checkout --------------------------------
# Excludes secondmate homes (the .fm-secondmate-home marker is written at seed
# time regardless of whether the home was treehouse-leased or git-cloned; see
# bin/fm-home-seed.sh) and ordinary crewmate/scout task worktrees of
# firstmate-on-itself (bin/fm-spawn.sh only ever hands those out as genuine
# linked `git worktree`s - it aborts the spawn otherwise - so a plain,
# non-worktree checkout is never one of those). A linked worktree's git-dir
# lives under the main repo's .git/worktrees/<name> and differs from the common
# (shared) git-dir; only the main, non-worktree checkout has the two equal.
[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
WATCHER_HEALTHY=false
if fm_watcher_healthy_settled "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$LOCK_SETTLE"; then
  WATCHER_HEALTHY=true
fi
[ "$WATCHER_HEALTHY" = true ] && [ "$FM_SUP_QUEUE_PENDING" = false ] && exit 0

write_decision_diagnostic() {
  local out lock beat lock_pid lock_home lock_path lock_identity pid_alive=false pid_identity physical_home physical_lock_home physical_watch physical_lock_path beat_mtime beat_age
  out="$FM_HOME/fm-state/turnend-guard-diagnostics.log"
  lock="$STATE/.watch.lock"
  beat="$STATE/.last-watcher-beat"
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 0
  lock_pid=$(cat "$lock/pid" 2>/dev/null || true)
  lock_home=$(cat "$lock/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lock/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lock/pid-identity" 2>/dev/null || true)
  fm_pid_alive "$lock_pid" && pid_alive=true
  pid_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null || true)
  physical_home=$(fm_physical_path "$FM_HOME" 2>/dev/null || true)
  physical_lock_home=$(fm_physical_path "$lock_home" 2>/dev/null || true)
  physical_watch=$(fm_physical_path "$WATCH" 2>/dev/null || true)
  physical_lock_path=$(fm_physical_path "$lock_path" 2>/dev/null || true)
  beat_mtime=$(fm_path_mtime "$beat" 2>/dev/null || true)
  beat_age=$(fm_path_age "$beat")
  {
    printf '%s\n' '--- turn-end guard warning decision ---'
    printf 'timestamp=%s\n' "$(date -Iseconds 2>/dev/null || date)"
    printf 'env.CLAUDE_PROJECT_DIR=%s\nenv.FM_HOME=%s\nenv.PWD=%s\ncwd=%s\n' "$INPUT_CLAUDE_PROJECT_DIR" "$INPUT_FM_HOME" "$INPUT_PWD" "$(pwd -P 2>/dev/null || true)"
    printf 'script_root=%s\nresolved_root=%s\nresolved_home=%s\nstate=%s\n' "$SCRIPT_ROOT" "$FM_ROOT" "$FM_HOME" "$STATE"
    printf 'lock=%s\nlock.pid=%s\nlock.fm_home=%s\nlock.watcher_path=%s\nlock.pid_identity=%s\n' "$lock" "$lock_pid" "$lock_home" "$lock_path" "$lock_identity"
    printf 'physical.home=%s\nphysical.lock_home=%s\nphysical.watch=%s\nphysical.lock_path=%s\n' "$physical_home" "$physical_lock_home" "$physical_watch" "$physical_lock_path"
    printf 'pid.alive=%s\npid.current_identity=%s\nbeacon=%s\nbeacon.mtime=%s\nbeacon.age=%s\n' "$pid_alive" "$pid_identity" "$beat" "$beat_mtime" "$beat_age"
    printf 'predicate.in_flight=%s\npredicate.beacon_fresh=%s\npredicate.queue_pending=%s\npredicate.watcher_healthy=%s\npredicate.home_match=%s\npredicate.watch_path_match=%s\npredicate.identity_match=%s\n' \
      "$FM_SUP_IN_FLIGHT" "$FM_SUP_WATCHER_FRESH" "$FM_SUP_QUEUE_PENDING" "$WATCHER_HEALTHY" \
      "$([ -n "$physical_home" ] && [ "$physical_home" = "$physical_lock_home" ] && printf true || printf false)" \
      "$([ -n "$physical_watch" ] && [ "$physical_watch" = "$physical_lock_path" ] && printf true || printf false)" \
      "$([ -n "$lock_identity" ] && [ "$lock_identity" = "$pid_identity" ] && printf true || printf false)"
  } >> "$out" 2>/dev/null || return 0
  if [ "$(wc -c < "$out" 2>/dev/null || printf 0)" -gt 65536 ]; then
    tail -c 49152 "$out" > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" 2>/dev/null || true
  fi
}

write_decision_diagnostic

afk=0
[ -e "$STATE/.afk" ] && afk=1
x_mode=0
[ -f "$CONFIG/x-mode.env" ] && x_mode=1
REASON=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
  || printf '%s\n' 'tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn')
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
if [ "$FM_SUP_QUEUE_PENDING" = true ]; then
  SUMMARY="$FM_SUP_IN_FLIGHT task(s) in flight and queued wakes are pending (last beat: $FM_SUP_BEACON_DESC)."
else
  SUMMARY="$FM_SUP_IN_FLIGHT task(s) in flight, but no live watcher holds this home lock (last beat: $FM_SUP_BEACON_DESC)."
fi
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s\n' "$SUMMARY"
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$rule"
} >&2
exit 2
