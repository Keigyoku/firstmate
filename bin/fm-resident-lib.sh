#!/usr/bin/env bash
# Crew Lead resident-container contract helpers.
# Source this file; use fm_resident_atomic_json <destination> to validate JSON,
# fsync a same-directory temporary file, rename it into place, and best-effort
# fsync the containing directory.
#
# Multi-harness transcript discovery (ADR 0056 adapter ids):
#   fm_resident_transcript_adapter <harness>
#   fm_resident_discover_transcript <harness> <worktree>
#   fm_resident_session_id_from_transcript <harness> <path> [worktree]
# Env roots: CLAUDE_HOME / VELLUM_TRANSCRIPT_ROOT, CODEX_HOME, GROK_HOME,
# CURSOR_HOME, PI_HOME, HERMES_HOME, OPENCODE_TRANSCRIPT_ROOT / XDG_DATA_HOME.
# FM_RESIDENT_* overrides live in fm-resident-publish.sh.

fm_resident_atomic_json() {  # <destination>
  local destination=$1 directory temporary
  [ ! -d "$destination" ] || return 1
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.$(basename "$destination").tmp.XXXXXX") || return 1
  if ! jq -e . > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if command -v sync >/dev/null 2>&1; then
    sync -f "$temporary" 2>/dev/null || sync 2>/dev/null || true
  fi
  mv -f "$temporary" "$destination"
  if command -v sync >/dev/null 2>&1; then
    sync -f "$directory" 2>/dev/null || true
  fi
}

fm_resident_rfc3339() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

fm_resident_container_id() {  # <home>
  jq -er 'select(.schema == "dev.vellum.god-node.provision/1") | .container_id' "$1/.god-node/provision.json"
}

fm_resident_process_identity() {  # <pid>
  local pid=$1 start boot
  if [ -r "/proc/$pid/stat" ]; then
    start=$(awk '{print $22}' "/proc/$pid/stat") || return 1
    boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown-boot)
    printf 'linux-proc-v1:%s:%s' "$boot" "$start"
    return 0
  fi
  start=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]][[:space:]]*/ /g')
  [ -n "$start" ] || return 1
  printf 'ps-lstart-v1:%s' "$start"
}

# --- multi-harness transcript discovery (Vellum ADR 0056) -------------------

# Canonical adapter id for a verified harness. Codex uses codex-rollout-v1
# (ADR 0056); consumers may dual-accept legacy codex-jsonl-v1 during migration.
fm_resident_transcript_adapter() {  # <harness>
  case "$1" in
    claude) printf '%s\n' claude-jsonl-v1 ;;
    codex) printf '%s\n' codex-rollout-v1 ;;
    grok) printf '%s\n' grok-chat-history-v1 ;;
    cursor) printf '%s\n' cursor-agent-transcript-v1 ;;
    opencode) printf '%s\n' opencode-db-v1 ;;
    pi) printf '%s\n' pi-session-jsonl-v1 ;;
    hermes) printf '%s\n' hermes-state-db-v1 ;;
    *) return 1 ;;
  esac
}

# Capability tokens advertised in .god-node/resident.json (space-separated).
fm_resident_capability_tokens() {
  printf '%s\n' \
    input.file-v1 \
    input.backend-v1 \
    transcript.claude-jsonl-v1 \
    transcript.codex-rollout-v1 \
    transcript.grok-chat-history-v1 \
    transcript.cursor-agent-transcript-v1 \
    transcript.opencode-db-v1 \
    transcript.pi-session-jsonl-v1 \
    transcript.hermes-state-db-v1 \
    crew.bridge-v1
}

fm_resident_path_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_resident_canonical_path() {  # <path>
  local path=$1 dir base
  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    return 0
  fi
  dir=$(dirname "$path")
  base=$(basename "$path")
  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || printf '%s\n' "$path"
}

fm_resident_paths_match() {  # <left> <right>
  local left=$1 right=$2 left_real right_real
  [ "$left" = "$right" ] && return 0
  left_real=$(fm_resident_canonical_path "$left")
  right_real=$(fm_resident_canonical_path "$right")
  [ "$left_real" = "$right_real" ]
}

# Print cwd spellings (as-given, physical, /home↔/var/home when same inode).
fm_resident_cwd_spellings() {  # <worktree>
  local worktree=$1 physical alt rest
  printf '%s\n' "$worktree"
  physical=$(fm_resident_canonical_path "$worktree")
  [ "$physical" = "$worktree" ] || printf '%s\n' "$physical"
  case "$worktree" in
    /home/*)
      rest=${worktree#/home/}
      alt=/var/home/$rest
      if [ -e "$worktree" ] && [ -e "$alt" ] && fm_resident_paths_match "$worktree" "$alt"; then
        printf '%s\n' "$alt"
      fi
      ;;
    /var/home/*)
      rest=${worktree#/var/home/}
      alt=/home/$rest
      if [ -e "$worktree" ] && [ -e "$alt" ] && fm_resident_paths_match "$worktree" "$alt"; then
        printf '%s\n' "$alt"
      fi
      ;;
  esac
}

fm_resident_latest_file_in() {  # <dir> <find-name-pattern>
  local dir=$1 pattern=$2 file mtime best_file='' best_mtime=-1
  [ -d "$dir" ] || return 1
  while IFS= read -r -d '' file; do
    mtime=$(fm_resident_path_mtime "$file") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$dir" -type f -name "$pattern" -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_resident_claude_projects_root() {
  if [ -n "${VELLUM_TRANSCRIPT_ROOT:-}" ]; then
    printf '%s\n' "$VELLUM_TRANSCRIPT_ROOT"
  elif [ -n "${CLAUDE_HOME:-}" ]; then
    printf '%s\n' "$CLAUDE_HOME/.claude/projects"
  else
    printf '%s\n' "$HOME/.claude/projects"
  fi
}

fm_resident_claude_project_key() {  # <worktree>
  fm_resident_canonical_path "$1" | sed 's#[^A-Za-z0-9]#-#g'
}

fm_resident_codex_sessions_root() {
  if [ -n "${CODEX_HOME:-}" ]; then
    printf '%s\n' "$CODEX_HOME/sessions"
  else
    printf '%s\n' "$HOME/.codex/sessions"
  fi
}

fm_resident_grok_sessions_root() {
  if [ -n "${GROK_HOME:-}" ]; then
    printf '%s\n' "$GROK_HOME/sessions"
  else
    printf '%s\n' "$HOME/.grok/sessions"
  fi
}

fm_resident_cursor_home() {
  if [ -n "${CURSOR_HOME:-}" ]; then
    printf '%s\n' "$CURSOR_HOME"
  else
    printf '%s\n' "$HOME/.cursor"
  fi
}

fm_resident_pi_sessions_root() {
  if [ -n "${PI_HOME:-}" ]; then
    printf '%s\n' "$PI_HOME/agent/sessions"
  else
    printf '%s\n' "$HOME/.pi/agent/sessions"
  fi
}

fm_resident_hermes_state_db() {
  if [ -n "${HERMES_HOME:-}" ]; then
    printf '%s\n' "$HERMES_HOME/state.db"
  else
    printf '%s\n' "$HOME/.hermes/state.db"
  fi
}

fm_resident_opencode_db() {
  if [ -n "${OPENCODE_TRANSCRIPT_ROOT:-}" ]; then
    printf '%s\n' "$OPENCODE_TRANSCRIPT_ROOT"
  elif [ -n "${XDG_DATA_HOME:-}" ]; then
    printf '%s\n' "$XDG_DATA_HOME/opencode/opencode.db"
  else
    printf '%s\n' "$HOME/.local/share/opencode/opencode.db"
  fi
}

# Grok percent-encodes cwd: unreserved [A-Za-z0-9-._~], else %XX uppercase.
fm_resident_grok_encode_cwd() {  # <cwd>
  local cwd=$1 out='' i c hex
  i=0
  while [ "$i" -lt "${#cwd}" ]; do
    c=${cwd:i:1}
    case "$c" in
      [A-Za-z0-9._~-]) out+=$c ;;
      *)
        printf -v hex '%%%02X' "'$c"
        out+=$hex
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# Pi cwd dir encoding: leading -, / → -, trailing --.
fm_resident_pi_encode_cwd() {  # <cwd>
  local cwd=$1
  printf -- '-%s--\n' "${cwd//\//-}"
}

fm_resident_discover_claude() {  # <worktree>
  local worktree=$1 root key dir spelling
  root=$(fm_resident_claude_projects_root)
  while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    key=$(fm_resident_claude_project_key "$spelling")
    dir="$root/$key"
    if [ -d "$dir" ]; then
      fm_resident_latest_file_in "$dir" '*.jsonl' && return 0
    fi
  done < <(fm_resident_cwd_spellings "$worktree")
  return 1
}

fm_resident_discover_codex() {  # <worktree>
  local worktree=$1 root file cwd mtime best_file='' best_mtime=-1
  root=$(fm_resident_codex_sessions_root)
  [ -d "$root" ] || return 1
  while IFS= read -r -d '' file; do
    cwd=$(jq -r 'select(.type == "session_meta") | .payload.cwd // empty' "$file" 2>/dev/null | head -n 1)
    [ -n "$cwd" ] || continue
    fm_resident_paths_match "$cwd" "$worktree" || continue
    mtime=$(fm_resident_path_mtime "$file") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$root" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_resident_discover_grok() {  # <worktree>
  local worktree=$1 root spelling enc dir file mtime best_file='' best_mtime=-1
  root=$(fm_resident_grok_sessions_root)
  [ -d "$root" ] || return 1
  while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    enc=$(fm_resident_grok_encode_cwd "$spelling")
    dir="$root/$enc"
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
      mtime=$(fm_resident_path_mtime "$file") || continue
      case "$mtime" in ''|*[!0-9]*) continue ;; esac
      if [ "$mtime" -gt "$best_mtime" ]; then
        best_mtime=$mtime
        best_file=$file
      fi
    done < <(find "$dir" -mindepth 2 -maxdepth 2 -type f -name 'chat_history.jsonl' -print0 2>/dev/null)
  done < <(fm_resident_cwd_spellings "$worktree")
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_resident_discover_cursor() {  # <worktree>
  local worktree=$1 home projects chats file meta_cwd mtime best_file='' best_mtime=-1 sid
  home=$(fm_resident_cursor_home)
  projects="$home/projects"
  chats="$home/chats"
  [ -d "$projects" ] || return 1
  while IFS= read -r -d '' file; do
    sid=$(basename "$(dirname "$file")")
    meta_cwd=''
    if [ -d "$chats" ]; then
      while IFS= read -r -d '' meta; do
        meta_cwd=$(jq -r '.cwd // empty' "$meta" 2>/dev/null || true)
        [ -n "$meta_cwd" ] && break
      done < <(find "$chats" -type f -path "*/$sid/meta.json" -print0 2>/dev/null)
    fi
    # Project slug encoding is lossy; only meta-attested cwd may bind a worktree.
    [ -n "$meta_cwd" ] || continue
    fm_resident_paths_match "$meta_cwd" "$worktree" || continue
    mtime=$(fm_resident_path_mtime "$file") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -gt "$best_mtime" ]; then
      best_mtime=$mtime
      best_file=$file
    fi
  done < <(find "$projects" -type f -path '*/agent-transcripts/*/*.jsonl' -print0 2>/dev/null)
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_resident_discover_pi() {  # <worktree>
  local worktree=$1 root spelling enc dir file mtime best_file='' best_mtime=-1 header_cwd
  root=$(fm_resident_pi_sessions_root)
  [ -d "$root" ] || return 1
  while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    enc=$(fm_resident_pi_encode_cwd "$spelling")
    dir="$root/$enc"
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
      header_cwd=$(jq -r 'select(.type == "session") | .cwd // empty' "$file" 2>/dev/null | head -n 1)
      if [ -n "$header_cwd" ]; then
        fm_resident_paths_match "$header_cwd" "$worktree" || continue
      fi
      mtime=$(fm_resident_path_mtime "$file") || continue
      case "$mtime" in ''|*[!0-9]*) continue ;; esac
      if [ "$mtime" -gt "$best_mtime" ]; then
        best_mtime=$mtime
        best_file=$file
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.jsonl' -print0 2>/dev/null)
  done < <(fm_resident_cwd_spellings "$worktree")
  [ -n "$best_file" ] || return 1
  printf '%s\n' "$best_file"
}

fm_resident_discover_opencode() {  # <worktree> -> prints db path when a matching session exists
  local worktree=$1 db sid spelling
  db=$(fm_resident_opencode_db)
  [ -f "$db" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sid=$(fm_resident_opencode_session_id_for_worktree "$db" "$worktree") || return 1
  [ -n "$sid" ] || return 1
  printf '%s\n' "$db"
}

fm_resident_discover_hermes() {  # <worktree> -> prints state.db when a matching session exists
  local worktree=$1 db sid
  db=$(fm_resident_hermes_state_db)
  [ -f "$db" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sid=$(fm_resident_hermes_session_id_for_worktree "$db" "$worktree") || return 1
  [ -n "$sid" ] || return 1
  printf '%s\n' "$db"
}

fm_resident_opencode_session_id_for_worktree() {  # <db> <worktree>
  local db=$1 worktree=$2 directory sid best_sid='' best_ts=-1
  while IFS='|' read -r sid directory ts; do
    [ -n "$sid" ] || continue
    [ -n "$directory" ] || continue
    fm_resident_paths_match "$directory" "$worktree" || continue
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    if [ "$ts" -gt "$best_ts" ]; then
      best_ts=$ts
      best_sid=$sid
    fi
  done < <(sqlite3 -separator '|' "$db" \
    "SELECT id, directory, COALESCE(time_updated, 0) FROM session WHERE time_archived IS NULL;" 2>/dev/null)
  [ -n "$best_sid" ] || return 1
  printf '%s\n' "$best_sid"
}

fm_resident_hermes_session_id_for_worktree() {  # <db> <worktree>
  local db=$1 worktree=$2 sid cwd ts best_sid='' best_ts=-1
  while IFS='|' read -r sid cwd ts; do
    [ -n "$sid" ] || continue
    [ -n "$cwd" ] || continue
    fm_resident_paths_match "$cwd" "$worktree" || continue
    # started_at is REAL seconds; compare as integer epoch for ordering.
    ts=${ts%%.*}
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    if [ "$ts" -gt "$best_ts" ]; then
      best_ts=$ts
      best_sid=$sid
    fi
  done < <(sqlite3 -separator '|' "$db" \
    "SELECT id, cwd, COALESCE(started_at, 0) FROM sessions WHERE archived = 0;" 2>/dev/null)
  [ -n "$best_sid" ] || return 1
  printf '%s\n' "$best_sid"
}

# Discover the latest transcript artifact path for harness@worktree.
# Returns 1 when none is found (publish then omits conversation).
fm_resident_discover_transcript() {  # <harness> <worktree>
  local harness=$1 worktree=$2
  [ -n "$harness" ] && [ -n "$worktree" ] || return 1
  case "$harness" in
    claude) fm_resident_discover_claude "$worktree" ;;
    codex) fm_resident_discover_codex "$worktree" ;;
    grok) fm_resident_discover_grok "$worktree" ;;
    cursor) fm_resident_discover_cursor "$worktree" ;;
    opencode) fm_resident_discover_opencode "$worktree" ;;
    pi) fm_resident_discover_pi "$worktree" ;;
    hermes) fm_resident_discover_hermes "$worktree" ;;
    *) return 1 ;;
  esac
}

# Extract session id from a discovered transcript path (and optional worktree for sqlite).
fm_resident_session_id_from_transcript() {  # <harness> <path> [worktree]
  local harness=$1 path=$2 worktree=${3:-} sid base
  [ -n "$path" ] || return 1
  case "$harness" in
    claude)
      base=$(basename "$path")
      printf '%s\n' "${base%.jsonl}"
      ;;
    codex)
      sid=$(jq -r 'select(.type == "session_meta") | .payload.session_id // .payload.id // .session_id // .sessionId // empty' "$path" 2>/dev/null | head -n 1)
      if [ -n "$sid" ]; then
        printf '%s\n' "$sid"
      else
        base=$(basename "$path")
        base=${base%.jsonl}
        printf '%s\n' "${base#rollout-}"
      fi
      ;;
    grok)
      # .../sessions/<encoded-cwd>/<uuid>/chat_history.jsonl
      printf '%s\n' "$(basename "$(dirname "$path")")"
      ;;
    cursor)
      # .../agent-transcripts/<uuid>/<uuid>.jsonl
      printf '%s\n' "$(basename "$(dirname "$path")")"
      ;;
    pi)
      # <ISO-ts>_<uuid>.jsonl — uuid is the session id
      base=$(basename "$path")
      base=${base%.jsonl}
      if [[ "$base" == *_* ]]; then
        printf '%s\n' "${base##*_}"
      else
        printf '%s\n' "$base"
      fi
      ;;
    opencode)
      [ -n "$worktree" ] || return 1
      fm_resident_opencode_session_id_for_worktree "$path" "$worktree"
      ;;
    hermes)
      [ -n "$worktree" ] || return 1
      fm_resident_hermes_session_id_for_worktree "$path" "$worktree"
      ;;
    *) return 1 ;;
  esac
}
