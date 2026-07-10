#!/usr/bin/env bash
# Session metrics, config, transcript, and event helpers for the firstmate watchdog.
#
# fm_watchdog_collect_metrics <harness> <task-id> writes one metrics snapshot
# to $STATE/watchdog/metrics-<task-id>.json.
# The path is under state/watchdog so watchdog artifacts stay with firstmate's
# existing runtime signals without mixing into the watcher's own dotfile internals.

FM_WATCHDOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$FM_WATCHDOG_LIB_DIR/fm-wake-lib.sh"

FM_WATCHDOG_PARSER_VERSION=1

fm_watchdog_default_config() {
  cat <<'JSON'
{
  "poll_interval_sec": 30,
  "thresholds": {
    "compact_at_context_pct": 85,
    "successor_at_context_pct": 95,
    "embargo_at_5hr_pct": 85,
    "embargo_at_7d_pct": 85
  },
  "steer_retries": 3,
  "steer_timeout_sec": 120,
  "compact_pending_retry_sec": 900,
  "metrics_failure_event_interval_sec": 300,
  "rotate_to": ["codex", "opencode"],
  "parser_version": 1
}
JSON
}

fm_watchdog_thresholds() {
  local config_dir=${FM_CONFIG_OVERRIDE:-$FM_HOME/config} config
  config=${FM_WATCHDOG_CONFIG:-$config_dir/watchdog.json}
  if [ -f "$config" ]; then
    jq -c . "$config" 2>/dev/null && return 0
    fm_watchdog_event watchdog_config "$config" invalid "malformed JSON; using defaults"
    fm_watchdog_default_config | jq -c .
  else
    fm_watchdog_default_config | jq -c .
  fi
}

fm_watchdog_metrics_dir() {
  printf '%s/watchdog\n' "$STATE"
}

fm_watchdog_events_path() {
  printf '%s/fm-state/watchdog.events\n' "$FM_HOME"
}

fm_watchdog_event() {
  local type=$1 sid=$2 status=${3:-} detail=${4:-} path dir tmp rc lock
  path=$(fm_watchdog_events_path)
  dir=$(dirname "$path")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.watchdog-event.XXXXXX")
  jq -cn \
    --arg type "$type" \
    --arg sid "$sid" \
    --arg status "$status" \
    --arg detail "$detail" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{type:$type,sid:$sid,status:$status,detail:$detail,ts:$ts}' > "$tmp" || {
      rc=$?
      rm -f "$tmp"
      return "$rc"
    }
  lock="$STATE/.watchdog-events.lock"
  fm_lock_acquire_wait "$lock"
  rc=0
  cat "$tmp" >> "$path" || rc=$?
  fm_lock_release "$lock"
  rm -f "$tmp"
  return "$rc"
}

fm_watchdog_metrics_path() {
  local session_id=$1
  printf '%s/metrics-%s.json\n' "$(fm_watchdog_metrics_dir)" "$session_id"
}

fm_watchdog_parser_mismatch() {
  printf 'WATCHDOG_PARSER_MISMATCH: %s\n' "$1" >&2
  return 3
}

fm_watchdog_latest_file() {
  local dir=$1 pattern=$2 file mtime best_file='' best_mtime=-1
  [ -d "$dir" ] || return 1
  while IFS= read -r -d '' file; do
    mtime=$(fm_path_mtime "$file") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$dir" -type f -name "$pattern" -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_watchdog_latest_claude_checkpoint() {
  local dir=${FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR:-$HOME/.claude/token-optimizer/checkpoints}
  fm_watchdog_latest_file "$dir" '*.json'
}

fm_watchdog_claude_checkpoint_for_session() {
  local session_id=$1 dir=${FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR:-$HOME/.claude/token-optimizer/checkpoints}
  local file mtime best_file='' best_mtime=-1 found_sid
  [ -d "$dir" ] || return 1
  while IFS= read -r -d '' file; do
    found_sid=$(jq -r '.session_id // empty' "$file" 2>/dev/null || true)
    [ "$found_sid" = "$session_id" ] || continue
    mtime=$(fm_path_mtime "$file") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$dir" -type f -name '*.json' -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_watchdog_latest_codex_rollout() {
  local dir=${FM_WATCHDOG_CODEX_SESSION_DIR:-$HOME/.codex/sessions}
  fm_watchdog_latest_file "$dir" 'rollout-*.jsonl'
}

fm_watchdog_claude_checkpoint_matches_session() {
  local file=$1 session_id=$2
  jq -e --arg session_id "$session_id" '
    (.session_id // .sessionId // "") == $session_id
  ' "$file" >/dev/null 2>&1
}

fm_watchdog_codex_rollout_matches_session() {
  local file=$1 session_id=$2
  jq -e --arg session_id "$session_id" '
    select(.type == "session_meta")
    | ((.payload.session_id // .payload.id // .session_id // .sessionId // "") == $session_id)
  ' "$file" >/dev/null 2>&1
}

fm_watchdog_latest_claude_checkpoint_for_session() {
  local session_id=$1 dir=${FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR:-$HOME/.claude/token-optimizer/checkpoints}
  local file mtime best_file='' best_mtime=-1
  [ -d "$dir" ] || return 1
  while IFS= read -r -d '' file; do
    fm_watchdog_claude_checkpoint_matches_session "$file" "$session_id" || continue
    mtime=$(fm_path_mtime "$file") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$dir" -type f -name '*.json' -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_watchdog_latest_codex_rollout_for_session() {
  local session_id=$1 dir=${FM_WATCHDOG_CODEX_SESSION_DIR:-$HOME/.codex/sessions}
  local file mtime best_file='' best_mtime=-1
  [ -d "$dir" ] || return 1
  while IFS= read -r -d '' file; do
    fm_watchdog_codex_rollout_matches_session "$file" "$session_id" || continue
    mtime=$(fm_path_mtime "$file") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$dir" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_watchdog_latest_claude_jsonl() {
  local dir=${FM_WATCHDOG_CLAUDE_SESSION_DIR:-$HOME/.claude/projects}
  fm_watchdog_latest_file "$dir" '*.jsonl'
}

fm_watchdog_canonical_path() {
  local path=$1 dir base
  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    return 0
  fi
  dir=$(dirname "$path")
  base=$(basename "$path")
  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || printf '%s\n' "$path"
}

fm_watchdog_paths_match() {
  local left=$1 right=$2 left_real right_real
  [ "$left" = "$right" ] && return 0
  left_real=$(fm_watchdog_canonical_path "$left")
  right_real=$(fm_watchdog_canonical_path "$right")
  [ "$left_real" = "$right_real" ]
}

fm_watchdog_claude_project_key() {
  fm_watchdog_canonical_path "$1" | sed 's#/#-#g'
}

fm_watchdog_latest_claude_jsonl_for_worktree() {
  local worktree=$1 base=${FM_WATCHDOG_CLAUDE_SESSION_DIR:-$HOME/.claude/projects} dir
  dir="$base/$(fm_watchdog_claude_project_key "$worktree")"
  fm_watchdog_latest_file "$dir" '*.jsonl'
}

fm_watchdog_codex_rollout_cwd() {
  jq -r 'select(.type == "session_meta") | .payload.cwd // empty' "$1" 2>/dev/null | head -n 1
}

fm_watchdog_task_key() {
  printf '%s' "$1" | tr ':/.' '___'
}

fm_watchdog_codex_rollout_cache_path() {
  local task=$1
  printf '%s/.codex-rollout-%s\n' "$(fm_watchdog_metrics_dir)" "$(fm_watchdog_task_key "$task")"
}

fm_watchdog_codex_rollout_cache_write() {
  local cache=$1 file=$2 worktree=$3 tmp
  mkdir -p "$(dirname "$cache")"
  tmp=$(mktemp "${cache}.tmp.XXXXXX")
  printf '%s\n%s\n' "$file" "$(fm_watchdog_canonical_path "$worktree")" > "$tmp"
  mv "$tmp" "$cache"
}

fm_watchdog_codex_cached_rollout() {
  local cache=$1 worktree=$2 file cached_worktree
  [ -s "$cache" ] || return 1
  file=$(sed -n '1p' "$cache")
  cached_worktree=$(sed -n '2p' "$cache")
  [ -f "$file" ] || return 1
  [ "$cached_worktree" = "$(fm_watchdog_canonical_path "$worktree")" ] || return 1
  printf '%s\n' "$file"
}

fm_watchdog_latest_codex_rollout_for_worktree() {
  local worktree=$1 task=${2:-} dir=${FM_WATCHDOG_CODEX_SESSION_DIR:-$HOME/.codex/sessions}
  local cache='' cached='' file cwd mtime best_file='' best_mtime=-1 search_dir seen_dirs=''
  [ -d "$dir" ] || return 1
  if [ -n "$task" ]; then
    cache=$(fm_watchdog_codex_rollout_cache_path "$task")
    cached=$(fm_watchdog_codex_cached_rollout "$cache" "$worktree" 2>/dev/null || true)
    if [ -n "$cached" ]; then
      best_file=$cached
      best_mtime=$(fm_path_mtime "$cached") || best_mtime=-1
    fi
  fi
  while IFS= read -r -d '' file; do
    cwd=$(fm_watchdog_codex_rollout_cwd "$file")
    [ -n "$cwd" ] || continue
    fm_watchdog_paths_match "$cwd" "$worktree" || continue
    mtime=$(fm_path_mtime "$file") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(
    if [ -n "$best_file" ]; then
      for search_dir in "$(dirname "$best_file")" "$dir/$(date +%Y/%m/%d)"; do
        [ -d "$search_dir" ] || continue
        case "|$seen_dirs|" in
          *"|$search_dir|"*) continue ;;
        esac
        seen_dirs="$seen_dirs|$search_dir"
        find "$search_dir" -maxdepth 1 -type f -name 'rollout-*.jsonl' -newer "$best_file" -print0 2>/dev/null
      done
    else
      find "$dir" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null
    fi
  )
  [ -n "$best_file" ] || return 1
  [ -n "$cache" ] && fm_watchdog_codex_rollout_cache_write "$cache" "$best_file" "$worktree"
  printf '%s\n' "$best_file"
}

fm_watchdog_task_worktree() {
  local task=$1 meta worktree
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || return 1
  worktree=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$worktree" ] || return 1
  printf '%s\n' "$worktree"
}

fm_watchdog_session_file() {
  local harness=$1 task=${2:-} worktree
  if [ -n "$task" ]; then
    worktree=$(fm_watchdog_task_worktree "$task" 2>/dev/null || true)
    if [ -n "$worktree" ]; then
      case "$harness" in
        claude) fm_watchdog_latest_claude_jsonl_for_worktree "$worktree"; return $? ;;
        codex) fm_watchdog_latest_codex_rollout_for_worktree "$worktree" "$task"; return $? ;;
      esac
    fi
  fi
  case "$harness" in
    claude) fm_watchdog_latest_claude_jsonl ;;
    codex) fm_watchdog_latest_codex_rollout ;;
    *) return 1 ;;
  esac
}

fm_watchdog_session_id_from_file() {
  local harness=$1 file=$2 sid
  case "$harness" in
    claude)
      sid=$(basename "$file")
      printf '%s\n' "${sid%.jsonl}"
      ;;
    codex)
      sid=$(jq -r 'select(.type == "session_meta") | .payload.session_id // .payload.id // empty' "$file" 2>/dev/null | head -n 1)
      if [ -n "$sid" ]; then
        printf '%s\n' "$sid"
      else
        sid=$(basename "$file")
        sid=${sid%.jsonl}
        printf '%s\n' "${sid#rollout-}"
      fi
      ;;
    *) return 1 ;;
  esac
}

fm_watchdog_file_identity() {
  local file=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%i:%N' "$file" 2>/dev/null
  else
    stat -c '%i:%n' "$file" 2>/dev/null
  fi
}

fm_watchdog_write_metrics() {
  local path=$1 json=$2 tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "${path}.tmp.XXXXXX")
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$path"
  printf '%s\n' "$path"
}

fm_watchdog_claude_metrics_json() {
  local harness=$1 session_id=$2 checkpoint=$3 collected_at
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -ce \
    --arg harness "$harness" \
    --arg session_id "$session_id" \
    --arg collected_at "$collected_at" \
    --argjson parser_version "$FM_WATCHDOG_PARSER_VERSION" '
      def number_or_null: if type == "number" then . else null end;
      if (.version == 1)
        and ((.session_id // .sessionId // "") == $session_id)
        and (.fill_pct | type == "number")
        and (.quality | type == "object")
        and (.quality.tool_calls | type == "number")
      then
        {
          harness: $harness,
          context_pct: .fill_pct,
          five_hr_pct: null,
          seven_day_pct: null,
          tool_calls: .quality.tool_calls,
          collected_at: $collected_at,
          parser_version: $parser_version
        }
      else
        error("unsupported token-optimizer checkpoint shape")
      end
    ' "$checkpoint" 2>/dev/null || fm_watchdog_parser_mismatch "claude checkpoint format drift: $checkpoint"
}

fm_watchdog_codex_metrics_json() {
  local harness=$1 session_id=$2 rollout=$3 collected_at
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -sce \
    --arg harness "$harness" \
    --arg session_id "$session_id" \
    --arg collected_at "$collected_at" \
    --argjson parser_version "$FM_WATCHDOG_PARSER_VERSION" '
      def token_events:
        map(select(.type == "event_msg" and .payload.type == "token_count"));
      def session_matches:
        map(select(.type == "session_meta")
          | ((.payload.session_id // .payload.id // .session_id // .sessionId // "") == $session_id))
        | any;
      def last_token_event: token_events | last;
      def pct($used; $limit):
        if ($used | type == "number") and ($limit | type == "number") and $limit > 0
        then (($used / $limit * 1000) | round / 10)
        else null
        end;
      if session_matches
        and (last_token_event | type == "object")
        and (last_token_event.payload.info.last_token_usage.total_tokens | type == "number")
        and (last_token_event.payload.info.model_context_window | type == "number")
        and (last_token_event.payload.rate_limits.primary.used_percent | type == "number")
        and (last_token_event.payload.rate_limits.secondary.used_percent | type == "number")
      then
        last_token_event.payload as $p
        | {
            harness: $harness,
            context_pct: pct($p.info.last_token_usage.total_tokens; $p.info.model_context_window),
            five_hr_pct: $p.rate_limits.primary.used_percent,
            seven_day_pct: $p.rate_limits.secondary.used_percent,
            tool_calls: null,
            collected_at: $collected_at,
            parser_version: $parser_version
          }
      else
        error("unsupported codex rollout token-count shape")
      end
    ' "$rollout" 2>/dev/null || fm_watchdog_parser_mismatch "codex rollout format drift: $rollout"
}

fm_watchdog_unknown_metrics_json() {
  local harness=$1 collected_at
  collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -cn \
    --arg harness "$harness" \
    --arg collected_at "$collected_at" \
    --argjson parser_version "$FM_WATCHDOG_PARSER_VERSION" \
    '{
      harness: $harness,
      context_pct: null,
      five_hr_pct: null,
      seven_day_pct: null,
      tool_calls: null,
      collected_at: $collected_at,
      parser_version: $parser_version
    }'
}

fm_watchdog_collect_metrics() {
  local harness=$1 task=$2 path metrics source session_file session_id meta
  path=$(fm_watchdog_metrics_path "$task")
  meta="$STATE/$task.meta"
  case "$harness" in
    claude)
      if [ -f "$meta" ]; then
        session_file=$(fm_watchdog_session_file "$harness" "$task" 2>/dev/null || true)
        [ -n "$session_file" ] || { fm_watchdog_parser_mismatch "no claude transcript found for $task"; return $?; }
        session_id=$(fm_watchdog_session_id_from_file "$harness" "$session_file") || return $?
        source=$(fm_watchdog_claude_checkpoint_for_session "$session_id") \
          || { fm_watchdog_parser_mismatch "no claude token-optimizer checkpoint found for $session_id"; return $?; }
      else
        source=$(fm_watchdog_latest_claude_checkpoint_for_session "$task") \
          || { fm_watchdog_parser_mismatch "no claude token-optimizer checkpoint found for session: $task"; return $?; }
        session_id=$task
      fi
      metrics=$(fm_watchdog_claude_metrics_json "$harness" "$session_id" "$source") || return $?
      ;;
    codex)
      if [ -f "$meta" ]; then
        source=$(fm_watchdog_session_file "$harness" "$task") \
          || { fm_watchdog_parser_mismatch "no codex rollout file found for $task"; return $?; }
        session_id=$(fm_watchdog_session_id_from_file "$harness" "$source") || return $?
      else
        source=$(fm_watchdog_latest_codex_rollout_for_session "$task") \
          || { fm_watchdog_parser_mismatch "no codex rollout file found for session: $task"; return $?; }
        session_id=$task
      fi
      metrics=$(fm_watchdog_codex_metrics_json "$harness" "$session_id" "$source") || return $?
      ;;
    *)
      metrics=$(fm_watchdog_unknown_metrics_json "$harness")
      ;;
  esac
  fm_watchdog_write_metrics "$path" "$metrics"
}
