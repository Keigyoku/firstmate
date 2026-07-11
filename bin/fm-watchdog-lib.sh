#!/usr/bin/env bash
# Session metrics, config, transcript, embargo, and event helpers for the firstmate watchdog.
#
# fm_watchdog_collect_metrics <harness> <task-id> writes one metrics snapshot
# to $STATE/watchdog/metrics-<task-id>.json.
# The path is under state/watchdog so watchdog artifacts stay with firstmate's
# existing runtime signals without mixing into the watcher's own dotfile internals.
# Budget embargo flags live under $FM_HOME/fm-state/watchdog because they are
# persistent provider-state gates owned by the spawner, not per-task runtime signals.

FM_WATCHDOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WATCHDOG_DEFAULT_ROOT="$(cd "$FM_WATCHDOG_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WATCHDOG_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"

FM_WATCHDOG_PARSER_VERSION=1

fm_watchdog_wake_lib_source() {
  [ -n "${_FM_WATCHDOG_WAKE_LIB_SOURCED:-}" ] && return 0
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$FM_WATCHDOG_LIB_DIR/fm-wake-lib.sh"
  _FM_WATCHDOG_WAKE_LIB_SOURCED=1
}

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

fm_watchdog_embargo_dir() {
  printf '%s/fm-state/watchdog\n' "$FM_HOME"
}

fm_watchdog_safe_harness() {
  local harness=$1
  case "$harness" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$harness"
}

fm_watchdog_embargo_path() {
  local harness safe
  harness=$1
  safe=$(fm_watchdog_safe_harness "$harness") || return 1
  printf '%s/embargo-%s\n' "$(fm_watchdog_embargo_dir)" "$safe"
}

fm_watchdog_harness_embargoed() {
  local path
  path=$(fm_watchdog_embargo_path "$1") || return 1
  [ -e "$path" ]
}

fm_watchdog_event() {
  local type=$1 sid=$2 status=${3:-} detail=${4:-} path dir tmp rc lock state_dir
  path=$(fm_watchdog_events_path)
  dir=$(dirname "$path")
  mkdir -p "$dir"
  state_dir=${STATE:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}
  mkdir -p "$state_dir"
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
  lock="$state_dir/.watchdog-events.lock"
  fm_watchdog_wake_lib_source
  fm_lock_acquire_wait "$lock"
  rc=0
  cat "$tmp" >> "$path" || rc=$?
  fm_lock_release "$lock"
  rm -f "$tmp"
  return "$rc"
}

fm_watchdog_write_embargo() {
  local harness=$1 sid=$2 five=${3:-} seven=${4:-} five_reset=${5:-} seven_reset=${6:-} reason=${7:-threshold} path dir tmp
  path=$(fm_watchdog_embargo_path "$harness") || return 1
  [ ! -e "$path" ] || return 0
  dir=$(dirname "$path")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.embargo-${harness}.XXXXXX")
  {
    printf 'harness=%s\n' "$harness"
    printf 'sid=%s\n' "$sid"
    printf 'reason=%s\n' "$reason"
    printf 'five_hr_pct=%s\n' "$five"
    printf 'seven_day_pct=%s\n' "$seven"
    printf 'five_hr_reset_at=%s\n' "$five_reset"
    printf 'seven_day_reset_at=%s\n' "$seven_reset"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  if mv -n "$tmp" "$path" 2>/dev/null; then
    fm_watchdog_event embargo "$sid" raised "harness=$harness five_hr_pct=$five seven_day_pct=$seven reason=$reason"
  else
    rm -f "$tmp"
  fi
}

fm_watchdog_lift_embargo() {
  local harness=$1 sid=${2:-$1} reason=${3:-manual} path
  path=$(fm_watchdog_embargo_path "$harness") || return 1
  [ -e "$path" ] || return 0
  rm -f "$path"
  fm_watchdog_event embargo "$sid" lifted "harness=$harness reason=$reason"
}

fm_watchdog_reset_epoch() {
  local value=$1
  case "$value" in
    ''|null) return 1 ;;
    *[!0-9]*)
      perl -MTime::Piece -e '
        my $value = shift;
        $value =~ s/\.\d+//;
        $value =~ s/Z$/+0000/;
        $value =~ s/([+-]\d\d):(\d\d)$/$1$2/;
        for my $format ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S%z") {
          my $t = eval { Time::Piece->strptime($value, $format) };
          if ($t) {
            print $t->epoch, "\n";
            exit 0;
          }
        }
        exit 1;
      ' "$value" 2>/dev/null || return 1
      ;;
    *)
      if [ "$value" -gt 9999999999 ]; then
        printf '%s\n' "$((value / 1000))"
      else
        printf '%s\n' "$value"
      fi
      ;;
  esac
}

fm_watchdog_reset_crossed() {
  local value=$1 now=${2:-}
  case "$now" in ''|*[!0-9]*) now=$(date -u +%s) ;; esac
  local reset
  reset=$(fm_watchdog_reset_epoch "$value" 2>/dev/null) || return 1
  [ "$now" -ge "$reset" ]
}

fm_watchdog_embargo_reset_value() {
  local bucket=$1 flag=$2 metrics=${3:-} value
  if [ -n "$metrics" ] && [ -f "$metrics" ]; then
    case "$bucket" in
      five_hr) value=$(jq -r '.five_hr_reset_at // empty' "$metrics" 2>/dev/null || true) ;;
      seven_day) value=$(jq -r '.seven_day_reset_at // empty' "$metrics" 2>/dev/null || true) ;;
      *) return 1 ;;
    esac
    [ -n "$value" ] && [ "$value" != null ] && { printf '%s\n' "$value"; return 0; }
  fi
  case "$bucket" in
    five_hr) sed -n 's/^five_hr_reset_at=//p' "$flag" | head -1 ;;
    seven_day) sed -n 's/^seven_day_reset_at=//p' "$flag" | head -1 ;;
    *) return 1 ;;
  esac
}

fm_watchdog_metric_bucket_blocks_embargo() {
  local metrics=$1 bucket=$2 threshold=$3 now=$4 pct reset
  [ -n "$metrics" ] && [ -f "$metrics" ] || return 1
  case "$threshold" in ''|null|*[!0-9.]* ) return 1 ;; esac
  case "$bucket" in
    five_hr)
      pct=$(jq -r '.five_hr_pct // empty' "$metrics" 2>/dev/null || true)
      reset=$(jq -r '.five_hr_reset_at // empty' "$metrics" 2>/dev/null || true)
      ;;
    seven_day)
      pct=$(jq -r '.seven_day_pct // empty' "$metrics" 2>/dev/null || true)
      reset=$(jq -r '.seven_day_reset_at // empty' "$metrics" 2>/dev/null || true)
      ;;
    *) return 1 ;;
  esac
  case "$pct" in ''|null|*[!0-9.]* ) return 1 ;; esac
  awk "BEGIN { exit !($pct >= $threshold) }" || return 1
  fm_watchdog_reset_crossed "$reset" "$now" && return 1
  return 0
}

fm_watchdog_embargo_auto_lift() {
  local harness=$1 sid=$2 metrics=$3 path now reason config embargo_5hr embargo_7d bucket reset has_reason_bucket=1
  path=$(fm_watchdog_embargo_path "$harness") || return 1
  [ -e "$path" ] || return 0
  now=$(date -u +%s)
  config=$(fm_watchdog_thresholds 2>/dev/null || true)
  embargo_5hr=$(printf '%s' "$config" | jq -r '.thresholds.embargo_at_5hr_pct // empty' 2>/dev/null || true)
  embargo_7d=$(printf '%s' "$config" | jq -r '.thresholds.embargo_at_7d_pct // empty' 2>/dev/null || true)
  if fm_watchdog_metric_bucket_blocks_embargo "$metrics" five_hr "$embargo_5hr" "$now" \
    || fm_watchdog_metric_bucket_blocks_embargo "$metrics" seven_day "$embargo_7d" "$now"; then
    return 0
  fi
  reason=$(sed -n 's/^reason=//p' "$path" | head -1)
  case "$reason" in *five_hr_pct*) has_reason_bucket=0 ;; esac
  case "$reason" in *seven_day_pct*) has_reason_bucket=0 ;; esac
  if [ "$has_reason_bucket" -eq 0 ]; then
    for bucket in five_hr seven_day; do
      case "$bucket:$reason" in
        five_hr:*five_hr_pct*|seven_day:*seven_day_pct*)
          reset=$(fm_watchdog_embargo_reset_value "$bucket" "$path" "$metrics" 2>/dev/null || true)
          fm_watchdog_reset_crossed "$reset" "$now" || return 0
          ;;
      esac
    done
    fm_watchdog_lift_embargo "$harness" "$sid" "provider_reset"
    return 0
  fi
  if [ -n "$metrics" ] && [ -f "$metrics" ]; then
    for bucket in five_hr seven_day; do
      reset=$(fm_watchdog_embargo_reset_value "$bucket" "$path" "$metrics" 2>/dev/null || true)
      fm_watchdog_reset_crossed "$reset" "$now" && { fm_watchdog_lift_embargo "$harness" "$sid" "provider_reset"; return 0; }
    done
  fi
}

fm_watchdog_rotate_harness() {
  local current=$1 config candidate
  if ! fm_watchdog_harness_embargoed "$current"; then
    printf '%s\n' "$current"
    return 0
  fi
  config=$(fm_watchdog_thresholds 2>/dev/null || true)
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if ! fm_watchdog_harness_embargoed "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$(printf '%s' "$config" | jq -r '.rotate_to[]? // empty' 2>/dev/null || true)
EOF
  printf '%s\n' "$current"
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
  fm_watchdog_wake_lib_source
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
  fm_watchdog_wake_lib_source
  while IFS= read -r -d '' file; do
    found_sid=$(jq -r '.session_id // .sessionId // empty' "$file" 2>/dev/null || true)
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
  fm_watchdog_wake_lib_source
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
  fm_watchdog_wake_lib_source
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
  fm_watchdog_canonical_path "$1" | sed 's#[^A-Za-z0-9]#-#g'
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

fm_watchdog_armed_session_path() {
  local task=$1
  printf '%s/armed-%s\n' "$(fm_watchdog_metrics_dir)" "$(fm_watchdog_task_key "$task")"
}

fm_watchdog_arm_session() {
  local task=$1 harness=$2 file=$3 marker sid sig tmp
  sid=$(fm_watchdog_session_id_from_file "$harness" "$file") || return $?
  sig=$(fm_watchdog_file_identity "$file") || return $?
  marker=$(fm_watchdog_armed_session_path "$task")
  mkdir -p "$(dirname "$marker")"
  tmp=$(mktemp "${marker}.tmp.XXXXXX")
  {
    printf 'sid=%s\n' "$sid"
    printf 'sig=%s\n' "$sig"
    printf 'file=%s\n' "$file"
    printf 'armed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  mv "$tmp" "$marker"
}

fm_watchdog_session_is_armed() {
  local task=$1 harness=$2 file=$3 marker sid sig armed_sid armed_sig
  marker=$(fm_watchdog_armed_session_path "$task")
  [ -s "$marker" ] || return 1
  sid=$(fm_watchdog_session_id_from_file "$harness" "$file") || return $?
  sig=$(fm_watchdog_file_identity "$file") || return $?
  armed_sid=$(sed -n 's/^sid=//p' "$marker" | head -1)
  armed_sig=$(sed -n 's/^sig=//p' "$marker" | head -1)
  [ "$sid" = "$armed_sid" ] && [ "$sig" = "$armed_sig" ]
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
  local worktree=$1 task=${2:-} cache_mode=${3:-write-cache} dir=${FM_WATCHDOG_CODEX_SESSION_DIR:-$HOME/.codex/sessions}
  local cache='' cached='' file cwd mtime best_file='' best_mtime=-1 search_dir seen_dirs=''
  [ -d "$dir" ] || return 1
  fm_watchdog_wake_lib_source
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
  [ -n "$cache" ] && [ "$cache_mode" != no-write ] && fm_watchdog_codex_rollout_cache_write "$cache" "$best_file" "$worktree"
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
  local harness=$1 task=${2:-} cache_mode=${3:-write-cache} worktree
  if [ -n "$task" ]; then
    worktree=$(fm_watchdog_task_worktree "$task" 2>/dev/null || true)
    [ -n "$worktree" ] || return 1
    case "$harness" in
      claude) fm_watchdog_latest_claude_jsonl_for_worktree "$worktree"; return $? ;;
      codex) fm_watchdog_latest_codex_rollout_for_worktree "$worktree" "$task" "$cache_mode"; return $? ;;
      *) return 1 ;;
    esac
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
      sid=$(jq -r 'select(.type == "session_meta") | .payload.session_id // .payload.id // .session_id // .sessionId // empty' "$file" 2>/dev/null | head -n 1)
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

fm_watchdog_compact_generation() {
  local harness=$1 file=$2
  case "$harness" in
    claude)
      jq -r 'select(.isCompactSummary == true) | .uuid // empty' "$file" 2>/dev/null | tail -1
      ;;
    *)
      return 1
      ;;
  esac
}

fm_watchdog_marker_key() {
  printf '%s' "$1" | tr ':/.' '___'
}

fm_watchdog_rotation_lock_path() {
  local task=$1
  printf '%s/.resident-rotation-%s\n' "$(fm_watchdog_metrics_dir)" "$(fm_watchdog_marker_key "$task")"
}

fm_watchdog_rotation_claim() {
  local task=$1 owner=${2:-watchdog} lock pid token
  lock=$(fm_watchdog_rotation_lock_path "$task")
  mkdir -p "$(dirname "$lock")"
  while ! mkdir "$lock" 2>/dev/null; do
    pid=$(sed -n '1p' "$lock/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*)
        rm -f "$lock/pid" "$lock/owner" "$lock/created_at" "$lock/token"
        rmdir "$lock" 2>/dev/null || return 1
        ;;
      *)
        kill -0 "$pid" 2>/dev/null || {
          rm -f "$lock/pid" "$lock/owner" "$lock/created_at" "$lock/token"
          rmdir "$lock" 2>/dev/null || return 1
          continue
        }
        return 1
        ;;
    esac
  done
  token="${owner}.${$}.${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).${RANDOM}${RANDOM}"
  printf '%s\n' "$$" > "$lock/pid"
  printf '%s\n' "$owner" > "$lock/owner"
  printf '%s\n' "$token" > "$lock/token"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$lock/created_at"
  printf '%s\n' "$token"
}

fm_watchdog_rotation_set_pid() {
  local task=$1 pid=$2 token=${3:-} lock actual
  lock=$(fm_watchdog_rotation_lock_path "$task")
  [ -d "$lock" ] || return 1
  [ -n "$token" ] || return 1
  actual=$(sed -n '1p' "$lock/token" 2>/dev/null || true)
  [ "$actual" = "$token" ] || return 1
  printf '%s\n' "$pid" > "$lock/pid"
}

fm_watchdog_rotation_release() {
  local task=$1 token=${2:-} lock actual
  lock=$(fm_watchdog_rotation_lock_path "$task")
  [ -d "$lock" ] || return 0
  [ -n "$token" ] || return 1
  actual=$(sed -n '1p' "$lock/token" 2>/dev/null || true)
  [ "$actual" = "$token" ] || return 1
  rm -f "$lock/pid" "$lock/owner" "$lock/created_at" "$lock/token"
  rmdir "$lock" 2>/dev/null || true
}

fm_watchdog_rotation_active() {
  local task=$1 lock pid
  lock=$(fm_watchdog_rotation_lock_path "$task")
  [ -e "$lock" ] || return 1
  pid=$(sed -n '1p' "$lock/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*)
      rm -f "$lock/pid" "$lock/owner" "$lock/created_at" "$lock/token"
      rmdir "$lock" 2>/dev/null || return 0
      return 1
      ;;
  esac
  kill -0 "$pid" 2>/dev/null && return 0
  rm -f "$lock/pid" "$lock/owner" "$lock/created_at" "$lock/token"
  rmdir "$lock" 2>/dev/null || return 0
  return 1
}

fm_watchdog_halt_file() {
  printf '%s/fm-state/watchdog.halt\n' "$FM_HOME"
}

fm_watchdog_start_successor() {
  local task=$1 context=$2 reason=$3 rc=${4:-} handoff latest tmp safe_task ts brief_path successor_cmd
  safe_task=$(fm_watchdog_marker_key "$task")
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  handoff="$FM_HOME/fm-state/handoffs/handoff-${safe_task}-${ts}-${$}.md"
  latest="$FM_HOME/fm-state/handoff-latest.md"
  brief_path="$FM_HOME/data/$task/brief.md"
  successor_cmd=${FM_WATCHDOG_SUCCESSOR_CMD:-$SCRIPT_DIR/fm-successor.sh}
  mkdir -p "$(dirname "$handoff")"
  tmp=$(mktemp "${handoff}.tmp.XXXXXX")
  {
    printf '# Watchdog Handoff\n\n'
    printf "Predecessor: \`%s\`.\n" "$task"
    printf 'Reason: %s.\n' "$reason"
    printf 'Context percent: %s.\n' "$context"
    [ -z "$rc" ] || printf 'Steer rc: %s.\n' "$rc"
    printf "Created: \`%s\`.\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n## Original Brief\n\n'
    if [ -f "$brief_path" ]; then
      printf "Original brief path: \`%s\`.\n\n" "$brief_path"
      printf '~~~~markdown\n'
      cat "$brief_path"
      printf '\n~~~~\n'
    else
      printf "Original brief path: \`%s\` was not present when this handoff was generated.\n" "$brief_path"
    fi
  } > "$tmp"
  mv "$tmp" "$handoff"
  cp "$handoff" "$latest" 2>/dev/null || true
  fm_watchdog_event successor_threshold "$task" triggered "context_pct=$context reason=$reason handoff=$handoff rc=$rc"
  if "$successor_cmd" "$task" "$handoff"; then
    fm_watchdog_event successor_complete "$task" succeeded "reason=$reason"
  else
    fm_watchdog_event successor_complete "$task" failed "reason=$reason"
    return 1
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
      def reset_at($bucket):
        $bucket.reset_at // $bucket.resetAt // $bucket.reset_at_ms // $bucket.resetAtMs // null;
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
            five_hr_reset_at: reset_at($p.rate_limits.primary),
            seven_day_reset_at: reset_at($p.rate_limits.secondary),
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
