#!/usr/bin/env bash
# Spawn a watchdog successor from a handoff artifact and retire its predecessor.
# Usage: fm-successor.sh <predecessor-sid> <handoff-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"

usage() {
  echo "usage: fm-successor.sh <predecessor-sid> <handoff-path>" >&2
}

watchdog_halt_path() {
  printf '%s/fm-state/watchdog.halt\n' "$FM_HOME"
}

successor_failure_artifact() {
  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  printf '%s/fm-state/steer-failure-%s.md\n' "$FM_HOME" "$ts"
}

write_failure_and_halt() {
  local predecessor=$1 handoff=$2 reason=$3 artifact halt
  artifact=$(successor_failure_artifact)
  halt=$(watchdog_halt_path)
  mkdir -p "$(dirname "$artifact")"
  {
    printf '# Watchdog Successor Failure\n\n'
    printf "Predecessor: \`%s\`.\n" "$predecessor"
    printf "Handoff: \`%s\`.\n" "$handoff"
    printf 'Reason: %s.\n' "$reason"
    printf "Timestamp: \`%s\`.\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$artifact"
  {
    printf 'halted_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'predecessor=%s\n' "$predecessor"
    printf 'handoff=%s\n' "$handoff"
    printf 'artifact=%s\n' "$artifact"
    printf 'reason=%s\n' "$reason"
  } > "$halt"
  fm_watchdog_event successor_spawn_failed "$predecessor" halted "handoff=$handoff artifact=$artifact reason=$reason"
  echo "fm-successor: spawn failed; watchdog halted; see $artifact" >&2
}

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

shell_quote() {
  local s=$1
  printf "'%s'" "$(printf '%s' "$s" | sed "s/'/'\\\\''/g")"
}

make_successor_id() {
  local predecessor=$1 suffix
  suffix=$(date -u +%H%M%S)
  printf '%s-successor-%s\n' "$predecessor" "$suffix" | tr -c 'A-Za-z0-9_.-' '-'
}

write_successor_brief() {
  local brief=$1 predecessor=$2 handoff=$3
  mkdir -p "$(dirname "$brief")"
  {
    printf '# Successor Handoff\n\n'
    printf "You are a successor session for \`%s\`.\n" "$predecessor"
    printf "Read and continue from this handoff artifact: \`%s\`.\n" "$handoff"
    printf '\n'
    printf '## Handoff Content\n\n'
    cat "$handoff"
    printf '\n'
  } > "$brief"
}

run_spawn() {
  if [ -n "${FM_SUCCESSOR_SPAWN_CMD:-}" ]; then
    "$FM_SUCCESSOR_SPAWN_CMD" "$@"
  else
    "$SCRIPT_DIR/fm-spawn.sh" "$@"
  fi
}

successor_meta_matches_worktree() {
  local successor=$1 worktree=$2 meta
  meta="$STATE/$successor.meta"
  [ -f "$meta" ] || return 1
  [ "$(meta_value "$meta" worktree)" = "$worktree" ] || return 1
}

successor_readiness_signal() {
  local successor=$1 worktree=$2 meta backend target alive
  meta="$STATE/$successor.meta"
  [ -f "$meta" ] || return 1
  [ "$(meta_value "$meta" worktree)" = "$worktree" ] || return 1
  backend=$(meta_value "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  target=$(fm_backend_resolve_selector "$successor" "$STATE" 2>/dev/null || meta_value "$meta" window)
  if [ -n "$target" ]; then
    alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf 'unknown')
    if [ "$alive" = alive ]; then
      printf 'agent_alive'
      return 0
    fi
    if [ "$alive" = unknown ] && fm_backend_target_exists "$backend" "$target" "fm-$successor" 2>/dev/null; then
      printf 'endpoint'
      return 0
    fi
  fi
  if [ -s "$STATE/$successor.status" ]; then
    printf 'status'
    return 0
  fi
  return 1
}

wait_successor_ready() {
  local successor=$1 worktree=$2 timeout=${FM_SUCCESSOR_READY_TIMEOUT:-30} waited=0 signal
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  while [ "$waited" -le "$timeout" ]; do
    if signal=$(successor_readiness_signal "$successor" "$worktree"); then
      printf '%s' "$signal"
      return 0
    fi
    [ "$waited" -lt "$timeout" ] || break
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

carry_task_metadata() {
  local predecessor_meta=$1 successor=$2 successor_meta key value tmp
  successor_meta="$STATE/$successor.meta"
  [ -f "$successor_meta" ] || return 1
  for key in pr pr_head; do
    value=$(meta_value "$predecessor_meta" "$key")
    [ -n "$value" ] || continue
    tmp=$(mktemp "$successor_meta.carry.XXXXXX")
    awk -v k="$key" -v v="$value" '
      BEGIN { written = 0 }
      index($0, k "=") == 1 {
        if (!written) {
          print k "=" v
          written = 1
        }
        next
      }
      { print }
      END {
        if (!written) {
          print k "=" v
        }
      }
    ' "$successor_meta" > "$tmp"
    mv "$tmp" "$successor_meta"
  done
}

carry_x_link() {
  local predecessor_meta=$1 successor=$2 request request_ts followups
  request=$(meta_value "$predecessor_meta" x_request)
  [ -n "$request" ] || return 0
  request_ts=$(meta_value "$predecessor_meta" x_request_ts)
  followups=$(meta_value "$predecessor_meta" x_followups)
  if [ -z "$request_ts" ] || [ -z "$followups" ]; then
    echo "predecessor X link is incomplete" >&2
    return 1
  fi
  "$SCRIPT_DIR/fm-x-link.sh" "$successor" "$request" --carry-count "$followups" --carry-ts "$request_ts" >/dev/null
}

validate_x_link() {
  local predecessor_meta=$1 request request_ts followups
  request=$(meta_value "$predecessor_meta" x_request)
  [ -n "$request" ] || return 0
  request_ts=$(meta_value "$predecessor_meta" x_request_ts)
  followups=$(meta_value "$predecessor_meta" x_followups)
  case "$request" in
    .*|*[!A-Za-z0-9._-]*) echo "predecessor X link has unsafe request id" >&2; return 1 ;;
  esac
  case "$request_ts" in
    ''|*[!0-9]*) echo "predecessor X link has invalid timestamp" >&2; return 1 ;;
  esac
  case "$followups" in
    ''|*[!0-9]*) echo "predecessor X link has invalid follow-up count" >&2; return 1 ;;
  esac
}

retire_predecessor() {
  local predecessor=$1 meta=$2 backend target
  backend=$(meta_value "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  target=$(fm_backend_resolve_selector "$predecessor" "$STATE" 2>/dev/null || meta_value "$meta" window)
  [ -n "$target" ] || return 0
  if [ -n "${FM_SUCCESSOR_RETIRE_CMD:-}" ]; then
    "$FM_SUCCESSOR_RETIRE_CMD" "$backend" "$target"
  else
    fm_backend_kill "$backend" "$target"
  fi
}

mark_predecessor_retired() {
  local predecessor=$1 meta=$2 successor=$3 handoff=$4 retired_dir retired_meta tmp
  retired_dir="$STATE/retired"
  retired_meta="$retired_dir/$predecessor.meta"
  mkdir -p "$retired_dir"
  tmp=$(mktemp "$retired_dir/$predecessor.meta.tmp.XXXXXX")
  cat "$meta" > "$tmp"
  {
    printf 'retired_by=%s\n' "$successor"
    printf 'retired_handoff=%s\n' "$handoff"
    printf 'retired_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >> "$tmp"
  mv "$tmp" "$retired_meta"
  rm -f "$meta"
}

restore_predecessor_turnend_hook() {
  local predecessor=$1 meta=$2 worktree=$3 harness state_real turnend token
  [ -d "$worktree" ] || return 0
  harness=$(meta_value "$meta" harness)
  mkdir -p "$STATE"
  state_real=$(cd "$STATE" && pwd -P)
  turnend="$state_real/$predecessor.turn-ended"
  case "$harness" in
    claude*)
      mkdir -p "$worktree/.claude"
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch %s"}]}]}}\n' "$(shell_quote "$turnend")" > "$worktree/.claude/settings.local.json"
      ;;
    opencode*)
      mkdir -p "$worktree/.opencode/plugins"
      cat > "$worktree/.opencode/plugins/fm-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $turnend\`
  },
})
EOF
      ;;
    grok*)
      token=$(cat "$STATE/$predecessor.grok-turnend-token" 2>/dev/null || true)
      case "$token" in
        fm.????????????) printf 'token=%s\n' "$token" > "$worktree/.fm-grok-turnend" ;;
      esac
      ;;
  esac
}

remove_grok_turnend_auth() {
  local id=$1 token hooks_dir
  token=$(cat "$STATE/$id.grok-turnend-token" 2>/dev/null || true)
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  hooks_dir="${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d"
  rm -f "$hooks_dir/$token"
}

cleanup_successor_after_failure() {
  local successor=$1 predecessor_meta=${2:-} predecessor=${3:-} worktree=${4:-} meta backend target
  meta="$STATE/$successor.meta"
  if [ -f "$meta" ]; then
    backend=$(meta_value "$meta" backend)
    [ -n "$backend" ] || backend=tmux
    target=$(fm_backend_resolve_selector "$successor" "$STATE" 2>/dev/null || meta_value "$meta" window)
    if [ -n "$target" ]; then
      if [ -n "${FM_SUCCESSOR_RETIRE_CMD:-}" ]; then
        "$FM_SUCCESSOR_RETIRE_CMD" "$backend" "$target" || true
      else
        fm_backend_kill "$backend" "$target" || true
      fi
    fi
    rm -f "$meta"
  fi
  remove_grok_turnend_auth "$successor"
  rm -f "$STATE/$successor.status" "$STATE/$successor.turn-ended" "$STATE/$successor.check.sh" "$STATE/$successor.pi-ext.ts" "$STATE/$successor.grok-turnend-token"
  if [ -n "$predecessor_meta" ] && [ -n "$predecessor" ] && [ -n "$worktree" ]; then
    restore_predecessor_turnend_hook "$predecessor" "$predecessor_meta" "$worktree" || true
  fi
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

PREDECESSOR=$1
HANDOFF=$2
META="$STATE/$PREDECESSOR.meta"

if [ ! -f "$META" ]; then
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "missing predecessor meta $META"
  exit 1
fi
if [ ! -f "$HANDOFF" ]; then
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "missing handoff artifact"
  exit 1
fi

SUCCESSOR_ID=${FM_SUCCESSOR_ID:-$(make_successor_id "$PREDECESSOR")}
BRIEF="$DATA/$SUCCESSOR_ID/brief.md"
WORKTREE=$(meta_value "$META" worktree)
PROJECT=$(meta_value "$META" project)
HARNESS=$(meta_value "$META" harness)
BACKEND=$(meta_value "$META" backend)
[ -n "$BACKEND" ] || BACKEND=tmux
MODEL=$(meta_value "$META" model)
EFFORT=$(meta_value "$META" effort)
MODE=$(meta_value "$META" mode)
YOLO=$(meta_value "$META" yolo)
KIND=$(meta_value "$META" kind)
[ -n "$KIND" ] || KIND=ship

if [ -z "$WORKTREE" ]; then
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "predecessor meta has no worktree"
  exit 1
fi
if [ -z "$PROJECT" ]; then
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "predecessor meta has no project"
  exit 1
fi
if ! x_link_output=$(validate_x_link "$META" 2>&1); then
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "predecessor X link invalid: $x_link_output"
  exit 1
fi
case "$KIND" in
  ship|scout) ;;
  *)
    write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "unsupported predecessor kind $KIND"
    exit 1
    ;;
esac

write_successor_brief "$BRIEF" "$PREDECESSOR" "$HANDOFF"
fm_watchdog_event successor_spawn "$PREDECESSOR" started "successor=$SUCCESSOR_ID handoff=$HANDOFF brief=$BRIEF"

spawn_args=("$SUCCESSOR_ID" "$PROJECT" --adopt-worktree --adopt-worktree-path "$WORKTREE")
[ "$KIND" != scout ] || spawn_args+=(--scout)
[ -z "$HARNESS" ] || spawn_args+=(--harness "$HARNESS")
spawn_args+=(--backend "$BACKEND")
[ -z "$MODEL" ] || [ "$MODEL" = default ] || spawn_args+=(--model "$MODEL")
[ -z "$EFFORT" ] || [ "$EFFORT" = default ] || spawn_args+=(--effort "$EFFORT")
[ -z "$MODE" ] || spawn_args+=(--mode "$MODE")
[ -z "$YOLO" ] || spawn_args+=(--yolo "$YOLO")

if ! spawn_output=$(run_spawn "${spawn_args[@]}" 2>&1); then
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "spawn failed: $spawn_output"
  exit 1
fi

if ! successor_meta_matches_worktree "$SUCCESSOR_ID" "$WORKTREE"; then
  cleanup_successor_after_failure "$SUCCESSOR_ID" "$META" "$PREDECESSOR" "$WORKTREE"
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "successor did not adopt predecessor worktree $WORKTREE"
  exit 1
fi

if ! metadata_output=$(carry_task_metadata "$META" "$SUCCESSOR_ID" 2>&1); then
  cleanup_successor_after_failure "$SUCCESSOR_ID" "$META" "$PREDECESSOR" "$WORKTREE"
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "metadata carry failed: $metadata_output"
  exit 1
fi

if ! x_link_output=$(carry_x_link "$META" "$SUCCESSOR_ID" 2>&1); then
  cleanup_successor_after_failure "$SUCCESSOR_ID" "$META" "$PREDECESSOR" "$WORKTREE"
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "X link carry failed: $x_link_output"
  exit 1
fi

if ! ready_signal=$(wait_successor_ready "$SUCCESSOR_ID" "$WORKTREE"); then
  cleanup_successor_after_failure "$SUCCESSOR_ID" "$META" "$PREDECESSOR" "$WORKTREE"
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "successor readiness could not be proven for worktree $WORKTREE"
  exit 1
fi

fm_watchdog_event successor_spawn "$PREDECESSOR" succeeded "successor=$SUCCESSOR_ID handoff=$HANDOFF readiness=$ready_signal"
if ! retire_output=$(retire_predecessor "$PREDECESSOR" "$META" 2>&1); then
  cleanup_successor_after_failure "$SUCCESSOR_ID" "$META" "$PREDECESSOR" "$WORKTREE"
  write_failure_and_halt "$PREDECESSOR" "$HANDOFF" "predecessor retirement failed: $retire_output"
  exit 1
fi
mark_predecessor_retired "$PREDECESSOR" "$META" "$SUCCESSOR_ID" "$HANDOFF"
fm_watchdog_event predecessor_retired "$PREDECESSOR" closed "successor=$SUCCESSOR_ID"
printf '%s\n' "$spawn_output"
