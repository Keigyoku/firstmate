#!/usr/bin/env bash
# Prepare and verify the isolated W3 live-proof environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOCKET=${FM_W3_TMUX_SOCKET:-fm-w3-test}
SCRATCH=${FM_W3_SCRATCH:-$ROOT/fm-scratch/w3-live}
CLAUDE_CONFIG="$SCRATCH/claude-config"
FM_SCRATCH_HOME="$SCRATCH/fm-home"
CONFIG_DIR="$SCRATCH/config"
BIN_DIR="$SCRATCH/bin"
GLOBAL_CLAUDE_PROJECTS=${FM_W3_GLOBAL_CLAUDE_PROJECTS:-$HOME/.claude/projects}
REAL_TMUX=${FM_W3_REAL_TMUX:-}
SOURCE_CLAUDE_CONFIG=${FM_W3_SOURCE_CLAUDE_CONFIG:-$HOME/.claude}
SOURCE_CLAUDE_APP_STATE=${FM_W3_SOURCE_CLAUDE_APP_STATE:-$HOME/.claude.json}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

safe_scratch_or_die() {
  case "$SCRATCH" in
    "$ROOT"/fm-scratch/*) ;;
    *) fail "scratch path must stay under $ROOT/fm-scratch" ;;
  esac
}

resolve_tmux() {
  if [ -n "$REAL_TMUX" ]; then
    [ -x "$REAL_TMUX" ] || fail "FM_W3_REAL_TMUX is not executable: $REAL_TMUX"
    return 0
  fi
  REAL_TMUX=$(command -v tmux || true)
  [ -n "$REAL_TMUX" ] || fail "tmux not found"
}

snapshot_global_claude_projects() {  # <output>
  local out=$1
  mkdir -p "$(dirname "$out")"
  if [ -d "$GLOBAL_CLAUDE_PROJECTS" ]; then
    find "$GLOBAL_CLAUDE_PROJECTS" -type f -printf '%P\t%s\t%T@\n' 2>/dev/null | sort > "$out"
  else
    : > "$out"
  fi
}

snapshot_default_tmux() {  # <prefix>
  local prefix=$1
  {
    tmux ls 2>&1 || true
  } > "$prefix.sessions"
  {
    tmux list-panes -a -F '#{session_name}:#{window_name}:#{pane_id}:#{pane_current_command}' 2>&1 || true
  } > "$prefix.panes"
}

write_tmux_shim() {
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$BIN_DIR/tmux"
}

write_claude_settings() {
  mkdir -p "$CLAUDE_CONFIG"
  cat > "$CLAUDE_CONFIG/settings.json" <<'JSON'
{
  "autoCompactEnabled": false,
  "env": {
    "DISABLE_AUTO_COMPACT": "1",
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "false"
  },
  "permissions": {
    "allow": [
      "Bash(*)",
      "Edit(*)",
      "Read(*)",
      "Write(*)"
    ],
    "deny": []
  },
  "skipDangerousModePermissionPrompt": true
}
JSON
}

copy_isolated_claude_auth() {
  [ -f "$SOURCE_CLAUDE_CONFIG/.credentials.json" ] \
    || fail "missing source Claude credentials file: $SOURCE_CLAUDE_CONFIG/.credentials.json"
  [ -f "$SOURCE_CLAUDE_APP_STATE" ] \
    || fail "missing source Claude app-state file: $SOURCE_CLAUDE_APP_STATE"
  install -m 600 "$SOURCE_CLAUDE_CONFIG/.credentials.json" "$CLAUDE_CONFIG/.credentials.json"
  jq '{
        oauthAccount,
        hasCompletedOnboarding: true,
        autoCompactEnabled: false
      }' "$SOURCE_CLAUDE_APP_STATE" > "$CLAUDE_CONFIG/.claude.json"
  chmod 600 "$CLAUDE_CONFIG/.claude.json"
}

write_watchdog_config() {
  mkdir -p "$CONFIG_DIR"
  jq '.thresholds.compact_at_context_pct = 40
      | .thresholds.successor_at_context_pct = 75
      | .compact_pending_retry_sec = 3
      | .metrics_failure_event_interval_sec = 1
      | .steer_retries = 1
      | .steer_timeout_sec = 30
      | .poll_interval_sec = 2' \
    "$ROOT/docs/examples/watchdog.json" > "$CONFIG_DIR/watchdog.json"
}

write_env_file() {
  cat > "$SCRATCH/env.sh" <<EOF
export CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG'
export FM_HOME='$FM_SCRATCH_HOME'
export FM_CONFIG_OVERRIDE='$CONFIG_DIR'
export FM_WATCHDOG_CLAUDE_SESSION_DIR='$CLAUDE_CONFIG/projects'
export FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR='$CLAUDE_CONFIG/token-optimizer/checkpoints'
export FM_STEER_REQUIRE_TARGET_EXISTS=1
export PATH='$BIN_DIR':"\$PATH"
EOF
}

prepare() {
  safe_scratch_or_die
  resolve_tmux
  rm -rf "$SCRATCH"
  mkdir -p "$SCRATCH" "$FM_SCRATCH_HOME/state" "$FM_SCRATCH_HOME/data" "$FM_SCRATCH_HOME/fm-state"
  snapshot_default_tmux "$SCRATCH/default-tmux-before"
  snapshot_global_claude_projects "$SCRATCH/global-claude-projects.before"
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s fm-w3-isolation-probe -c "$ROOT"
  "$REAL_TMUX" -L "$SOCKET" ls > "$SCRATCH/private-tmux-ls.txt"
  write_tmux_shim
  write_claude_settings
  copy_isolated_claude_auth
  write_watchdog_config
  write_env_file
  snapshot_default_tmux "$SCRATCH/default-tmux-after-prepare"
  snapshot_global_claude_projects "$SCRATCH/global-claude-projects.after-prepare"
  cmp -s "$SCRATCH/global-claude-projects.before" "$SCRATCH/global-claude-projects.after-prepare" \
    || fail "global Claude projects changed during isolation prepare"
  cmp -s "$SCRATCH/default-tmux-before.sessions" "$SCRATCH/default-tmux-after-prepare.sessions" \
    || fail "default tmux sessions changed during isolation prepare"
  printf 'prepared W3 isolation harness at %s\n' "$SCRATCH"
  printf 'source %s before any live proof command\n' "$SCRATCH/env.sh"
}

assert_after_live() {
  safe_scratch_or_die
  [ -f "$SCRATCH/global-claude-projects.before" ] || fail "missing before snapshot; run prepare first"
  snapshot_default_tmux "$SCRATCH/default-tmux-after-live"
  snapshot_global_claude_projects "$SCRATCH/global-claude-projects.after-live"
  cmp -s "$SCRATCH/global-claude-projects.before" "$SCRATCH/global-claude-projects.after-live" \
    || fail "global Claude projects changed during live proof"
  "$REAL_TMUX" -L "$SOCKET" ls > "$SCRATCH/private-tmux-after-live.txt"
  printf 'isolation assertions passed for %s\n' "$SCRATCH"
}

cleanup() {
  safe_scratch_or_die
  resolve_tmux
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  printf 'stopped private tmux socket %s\n' "$SOCKET"
}

case "${1:-prepare}" in
  prepare) prepare ;;
  assert) resolve_tmux; assert_after_live ;;
  cleanup) cleanup ;;
  *)
    fail "usage: $0 [prepare|assert|cleanup]"
    ;;
esac
