#!/usr/bin/env bash
# Multi-harness Crew Lead transcript discovery + publish matrix (issue #703 / ADR 0056).
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_ROOT=$(fm_test_tmproot fm-resident-mh)
# shellcheck source=bin/fm-resident-lib.sh
. "$ROOT/bin/fm-resident-lib.sh"

HOME_DIR="$TEST_ROOT/home"
WORKTREE="$TEST_ROOT/worktree"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$WORKTREE"
# Physical path for /home vs /var/home spellings where the host has both.
WORKTREE=$(cd "$WORKTREE" && pwd -P)

# Isolated harness roots so discovery never touches the operator's real journals.
export CLAUDE_HOME="$TEST_ROOT/claude-home"
export CODEX_HOME="$TEST_ROOT/codex-home"
export GROK_HOME="$TEST_ROOT/grok-home"
export CURSOR_HOME="$TEST_ROOT/cursor-home"
export PI_HOME="$TEST_ROOT/pi-home"
export HERMES_HOME="$TEST_ROOT/hermes-home"
export OPENCODE_TRANSCRIPT_ROOT="$TEST_ROOT/opencode.db"
export XDG_DATA_HOME="$TEST_ROOT/xdg-data"
mkdir -p \
  "$CLAUDE_HOME/.claude/projects" \
  "$CODEX_HOME/sessions/2026/07/22" \
  "$GROK_HOME/sessions" \
  "$CURSOR_HOME/projects/proj-slug/agent-transcripts" \
  "$CURSOR_HOME/chats/bucket" \
  "$PI_HOME/agent/sessions" \
  "$HERMES_HOME" \
  "$XDG_DATA_HOME/opencode"

# --- adapter id map ---------------------------------------------------------
assert_adapter() {
  local harness=$1 expected=$2 got
  got=$(fm_resident_transcript_adapter "$harness")
  [ "$got" = "$expected" ] || fail "adapter for $harness: got $got want $expected"
}
assert_adapter claude claude-jsonl-v1
assert_adapter codex codex-rollout-v1
assert_adapter grok grok-chat-history-v1
assert_adapter cursor cursor-agent-transcript-v1
assert_adapter opencode opencode-db-v1
assert_adapter pi pi-session-jsonl-v1
assert_adapter hermes hermes-state-db-v1
! fm_resident_transcript_adapter unknown >/dev/null 2>&1 || fail "unknown harness must fail adapter lookup"
pass "ADR 0056 adapter id map covers all seven harnesses"

[ "$(FM_WATCHDOG_CLAUDE_SESSION_DIR="$TEST_ROOT/watchdog-claude" fm_resident_claude_projects_root)" = "$TEST_ROOT/watchdog-claude" ] \
  || fail "Claude watchdog transcript root did not take precedence"
[ "$(FM_WATCHDOG_CODEX_SESSION_DIR="$TEST_ROOT/watchdog-codex" fm_resident_codex_sessions_root)" = "$TEST_ROOT/watchdog-codex" ] \
  || fail "Codex watchdog transcript root did not take precedence"
[ "$(fm_resident_grok_encode_cwd '/tmp/café')" = '%2Ftmp%2Fcaf%C3%A9' ] \
  || fail "Grok cwd encoding was not UTF-8 byte-safe"
pass "legacy roots and UTF-8 Grok cwd encoding remain compatible"

# --- fixture journals -------------------------------------------------------
CLAUDE_KEY=$(fm_resident_claude_project_key "$WORKTREE")
mkdir -p "$CLAUDE_HOME/.claude/projects/$CLAUDE_KEY"
CLAUDE_JSONL="$CLAUDE_HOME/.claude/projects/$CLAUDE_KEY/session-claude-aaa.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$CLAUDE_JSONL"

CODEX_JSONL="$CODEX_HOME/sessions/2026/07/22/rollout-2026-07-22T00-00-00-session-codex-bbb.jsonl"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"session-codex-bbb\",\"cwd\":\"$WORKTREE\"}}" > "$CODEX_JSONL"
# Distractor rollout for a different cwd must not win.
printf '%s\n' '{"type":"session_meta","payload":{"session_id":"other","cwd":"/tmp/other"}}' \
  > "$CODEX_HOME/sessions/2026/07/22/rollout-2026-07-22T00-00-01-other.jsonl"

GROK_ENC=$(fm_resident_grok_encode_cwd "$WORKTREE")
GROK_SID=019f9999-aaaa-bbbb-cccc-ddddeeeeffff
mkdir -p "$GROK_HOME/sessions/$GROK_ENC/$GROK_SID"
GROK_JSONL="$GROK_HOME/sessions/$GROK_ENC/$GROK_SID/chat_history.jsonl"
printf '%s\n' '{"type":"user","content":"hello"}' > "$GROK_JSONL"

CURSOR_SID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
mkdir -p "$CURSOR_HOME/projects/proj-slug/agent-transcripts/$CURSOR_SID"
mkdir -p "$CURSOR_HOME/chats/bucket/$CURSOR_SID"
CURSOR_JSONL="$CURSOR_HOME/projects/proj-slug/agent-transcripts/$CURSOR_SID/$CURSOR_SID.jsonl"
printf '%s\n' '{"role":"user","message":{"content":[{"type":"text","text":"hi"}]}}' > "$CURSOR_JSONL"
printf '%s\n' "{\"schemaVersion\":1,\"cwd\":\"$WORKTREE\"}" > "$CURSOR_HOME/chats/bucket/$CURSOR_SID/meta.json"

PI_ENC=$(fm_resident_pi_encode_cwd "$WORKTREE")
PI_SID=019f8888-1111-2222-3333-444455556666
mkdir -p "$PI_HOME/agent/sessions/$PI_ENC"
PI_JSONL="$PI_HOME/agent/sessions/$PI_ENC/2026-07-22T00-00-00-000Z_${PI_SID}.jsonl"
printf '%s\n' "{\"type\":\"session\",\"id\":\"$PI_SID\",\"cwd\":\"$WORKTREE\",\"version\":1}" > "$PI_JSONL"
printf '%s\n' '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"x"}]}}' >> "$PI_JSONL"

OPENCODE_SID=ses_testopencode001
HERMES_SID=20260722_000000_abc123
DELIMITER_WORKTREE="$TEST_ROOT/work|tree"
mkdir -p "$DELIMITER_WORKTREE"
python3 - "$OPENCODE_TRANSCRIPT_ROOT" "$HERMES_HOME/state.db" "$WORKTREE" "$OPENCODE_SID" "$HERMES_SID" "$DELIMITER_WORKTREE" <<'PY'
import sqlite3
import sys

opencode_db, hermes_db, worktree, opencode_sid, hermes_sid, delimiter_worktree = sys.argv[1:]
with sqlite3.connect(opencode_db) as connection:
    connection.execute(
        "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL, "
        "time_updated INTEGER NOT NULL DEFAULT 0, time_archived INTEGER)"
    )
    connection.executemany(
        "INSERT INTO session (id, directory, time_updated) VALUES (?, ?, ?)",
        [
            (opencode_sid, worktree, 100),
            ("ses_othercwd0001", "/tmp/other", 200),
            ("ses|delimiter", delimiter_worktree, 300),
        ],
    )
with sqlite3.connect(hermes_db) as connection:
    connection.execute(
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL NOT NULL DEFAULT 0, "
        "cwd TEXT, archived INTEGER NOT NULL DEFAULT 0)"
    )
    connection.executemany(
        "INSERT INTO sessions (id, started_at, cwd, archived) VALUES (?, ?, ?, 0)",
        [
            (hermes_sid, 1000.5, worktree),
            ("20260722_000001_other", 2000.0, "/tmp/other"),
            ("hermes|delimiter", 3000.0, delimiter_worktree),
        ],
    )
PY

# --- discovery matrix -------------------------------------------------------
check_discover() {
  local harness=$1 expect_path=$2 expect_sid=$3 got_path got_sid
  got_path=$(fm_resident_discover_transcript "$harness" "$WORKTREE") \
    || fail "discover $harness returned no path"
  [ "$got_path" = "$expect_path" ] || fail "discover $harness path: got $got_path want $expect_path"
  got_sid=$(fm_resident_session_id_from_transcript "$harness" "$got_path" "$WORKTREE") \
    || fail "session id $harness failed"
  [ "$got_sid" = "$expect_sid" ] || fail "session id $harness: got $got_sid want $expect_sid"
}

check_discover claude "$CLAUDE_JSONL" session-claude-aaa
check_discover codex "$CODEX_JSONL" session-codex-bbb
check_discover grok "$GROK_JSONL" "$GROK_SID"
check_discover cursor "$CURSOR_JSONL" "$CURSOR_SID"
check_discover pi "$PI_JSONL" "$PI_SID"
check_discover opencode "$OPENCODE_TRANSCRIPT_ROOT" "$OPENCODE_SID"
check_discover hermes "$HERMES_HOME/state.db" "$HERMES_SID"
pass "discovery matrix resolves path+session_id for all seven harnesses"

[ "$(fm_resident_opencode_session_id_for_worktree "$OPENCODE_TRANSCRIPT_ROOT" "$DELIMITER_WORKTREE")" = 'ses|delimiter' ] \
  || fail "OpenCode SQLite row framing split a delimiter-bearing value"
[ "$(fm_resident_hermes_session_id_for_worktree "$HERMES_HOME/state.db" "$DELIMITER_WORKTREE")" = 'hermes|delimiter' ] \
  || fail "Hermes SQLite row framing split a delimiter-bearing value"
pass "database row framing preserves delimiter-bearing values"

PYTHON_ONLY_BIN="$TEST_ROOT/python-only-bin"
mkdir -p "$PYTHON_ONLY_BIN"
ln -s "$(command -v python3)" "$PYTHON_ONLY_BIN/python3"
ln -s "$(command -v dirname)" "$PYTHON_ONLY_BIN/dirname"
ln -s "$(command -v basename)" "$PYTHON_ONLY_BIN/basename"
[ ! -e "$PYTHON_ONLY_BIN/sqlite3" ] || fail "python-only fixture unexpectedly contains sqlite3"
[ "$(PATH="$PYTHON_ONLY_BIN" fm_resident_discover_opencode "$WORKTREE")" = "$OPENCODE_TRANSCRIPT_ROOT" ] \
  || fail "OpenCode discovery required the sqlite3 executable"
[ "$(PATH="$PYTHON_ONLY_BIN" fm_resident_discover_hermes "$WORKTREE")" = "$HERMES_HOME/state.db" ] \
  || fail "Hermes discovery required the sqlite3 executable"
pass "database discovery uses Python stdlib without sqlite3 executable"

CURSOR_OTHER_SID=cccccccc-dddd-eeee-ffff-000000000000
mkdir -p "$CURSOR_HOME/projects/proj-slug/agent-transcripts/$CURSOR_OTHER_SID"
printf '%s\n' '{}' > "$CURSOR_HOME/projects/proj-slug/agent-transcripts/$CURSOR_OTHER_SID/$CURSOR_OTHER_SID.jsonl"
CURSOR_FIND_BIN=$(fm_fakebin "$TEST_ROOT/cursor-find-bin")
CURSOR_REAL_FIND=$(command -v find)
CURSOR_FIND_LOG="$TEST_ROOT/cursor-find.log"
cat > "$CURSOR_FIND_BIN/find" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CURSOR_FIND_LOG"
exec "$CURSOR_REAL_FIND" "$@"
SH
chmod +x "$CURSOR_FIND_BIN/find"
CURSOR_FOUND=$(PATH="$CURSOR_FIND_BIN:$PATH" CURSOR_FIND_LOG="$CURSOR_FIND_LOG" \
  CURSOR_REAL_FIND="$CURSOR_REAL_FIND" fm_resident_discover_cursor "$WORKTREE")
[ "$CURSOR_FOUND" = "$CURSOR_JSONL" ] || fail "indexed Cursor discovery selected the wrong transcript"
[ "$(grep -Fxc "$CURSOR_HOME/chats" "$CURSOR_FIND_LOG")" -eq 1 ] \
  || fail "Cursor discovery rescanned chat metadata"
[ "$(grep -Fxc "$CURSOR_HOME/projects" "$CURSOR_FIND_LOG")" -eq 1 ] \
  || fail "Cursor discovery rescanned agent transcripts"
pass "cursor discovery scans metadata and transcripts once each"

# Cursor without meta must not bind (lossy project slug).
rm -f "$CURSOR_HOME/chats/bucket/$CURSOR_SID/meta.json"
if fm_resident_discover_transcript cursor "$WORKTREE" >/dev/null 2>&1; then
  fail "cursor discovery without meta.json must fail closed"
fi
printf '%s\n' "{\"schemaVersion\":1,\"cwd\":\"$WORKTREE\"}" > "$CURSOR_HOME/chats/bucket/$CURSOR_SID/meta.json"
pass "cursor discovery fails closed without meta cwd attestation"

# --- publish end-to-end per harness -----------------------------------------
# FM_HOME is both the provision home and discovery cwd, so fixtures are keyed
# to HOME_DIR (the publish FM_HOME).
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
CONTAINER_ID=$(jq -r '.container_id' "$HOME_DIR/.god-node/provision.json")
PUBLISH_HOME=$(cd "$HOME_DIR" && pwd -P)

# Claude under publish home
P_CLAUDE_KEY=$(fm_resident_claude_project_key "$PUBLISH_HOME")
mkdir -p "$CLAUDE_HOME/.claude/projects/$P_CLAUDE_KEY"
P_CLAUDE="$CLAUDE_HOME/.claude/projects/$P_CLAUDE_KEY/pub-claude.jsonl"
printf '%s\n' '{}' > "$P_CLAUDE"

# Codex
P_CODEX="$CODEX_HOME/sessions/2026/07/22/rollout-pub-codex.jsonl"
printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"pub-codex-id\",\"cwd\":\"$PUBLISH_HOME\"}}" > "$P_CODEX"

# Grok
P_GROK_ENC=$(fm_resident_grok_encode_cwd "$PUBLISH_HOME")
P_GROK_SID=019f7777-aaaa-bbbb-cccc-111122223333
mkdir -p "$GROK_HOME/sessions/$P_GROK_ENC/$P_GROK_SID"
P_GROK="$GROK_HOME/sessions/$P_GROK_ENC/$P_GROK_SID/chat_history.jsonl"
printf '%s\n' '{"type":"user","content":"x"}' > "$P_GROK"

# Cursor
P_CUR_SID=bbbbbbbb-cccc-dddd-eeee-ffffffffffff
mkdir -p "$CURSOR_HOME/projects/pub/agent-transcripts/$P_CUR_SID"
mkdir -p "$CURSOR_HOME/chats/pub/$P_CUR_SID"
P_CUR="$CURSOR_HOME/projects/pub/agent-transcripts/$P_CUR_SID/$P_CUR_SID.jsonl"
printf '%s\n' '{}' > "$P_CUR"
printf '%s\n' "{\"cwd\":\"$PUBLISH_HOME\"}" > "$CURSOR_HOME/chats/pub/$P_CUR_SID/meta.json"

# Pi
P_PI_ENC=$(fm_resident_pi_encode_cwd "$PUBLISH_HOME")
P_PI_SID=019f6666-aaaa-bbbb-cccc-dddddddddddd
mkdir -p "$PI_HOME/agent/sessions/$P_PI_ENC"
P_PI="$PI_HOME/agent/sessions/$P_PI_ENC/2026-07-22T12-00-00-000Z_${P_PI_SID}.jsonl"
printf '%s\n' "{\"type\":\"session\",\"id\":\"$P_PI_SID\",\"cwd\":\"$PUBLISH_HOME\"}" > "$P_PI"

# OpenCode + Hermes already have tables; insert rows for publish home
python3 - "$OPENCODE_TRANSCRIPT_ROOT" "$HERMES_HOME/state.db" "$PUBLISH_HOME" <<'PY'
import sqlite3
import sys

opencode_db, hermes_db, publish_home = sys.argv[1:]
with sqlite3.connect(opencode_db) as connection:
    connection.execute(
        "INSERT INTO session (id, directory, time_updated) VALUES (?, ?, ?)",
        ("ses_publishhome01", publish_home, 300),
    )
with sqlite3.connect(hermes_db) as connection:
    connection.execute(
        "INSERT INTO sessions (id, started_at, cwd, archived) VALUES (?, ?, ?, 0)",
        ("20260722_120000_pub1", 3000.0, publish_home),
    )
PY

expect_publish() {
  local harness=$1 expect_adapter=$2 expect_sid=$3 expect_path=$4
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RESIDENT_PID="$$" FM_RESIDENT_HARNESS="$harness" \
    FM_RESIDENT_BACKEND_KIND=herdr FM_RESIDENT_WORKSPACE_ID=ws FM_RESIDENT_PANE_ID=pane \
    "$ROOT/bin/fm-resident-publish.sh" ready
  jq -e --arg h "$harness" --arg a "$expect_adapter" --arg s "$expect_sid" --arg p "$expect_path" --arg id "$CONTAINER_ID" '
    .container_id == $id
    and .conversation.harness == $h
    and .conversation.session_id == $s
    and .conversation.transcript.adapter == $a
    and .conversation.transcript.id == $s
    and .conversation.transcript.path == $p
  ' "$HOME_DIR/state/resident-current.json" >/dev/null \
    || fail "publish conversation fields wrong for $harness: $(cat "$HOME_DIR/state/resident-current.json")"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-doctor.sh" >/dev/null \
    || fail "doctor failed after $harness publish"
}

expect_publish claude claude-jsonl-v1 pub-claude "$P_CLAUDE"
expect_publish codex codex-rollout-v1 pub-codex-id "$P_CODEX"
expect_publish grok grok-chat-history-v1 "$P_GROK_SID" "$P_GROK"
expect_publish cursor cursor-agent-transcript-v1 "$P_CUR_SID" "$P_CUR"
expect_publish pi pi-session-jsonl-v1 "$P_PI_SID" "$P_PI"
expect_publish opencode opencode-db-v1 ses_publishhome01 "$OPENCODE_TRANSCRIPT_ROOT"
expect_publish hermes hermes-state-db-v1 20260722_120000_pub1 "$HERMES_HOME/state.db"
pass "publish + doctor matrix emits ADR 0056 conversation for all seven harnesses"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RESIDENT_PID="$$" FM_RESIDENT_HARNESS=codex \
  FM_RESIDENT_TRANSCRIPT="$P_CODEX" FM_RESIDENT_SESSION_ID=pub-codex-id \
  FM_RESIDENT_TRANSCRIPT_ADAPTER=codex-jsonl-v1 \
  FM_RESIDENT_BACKEND_KIND=herdr FM_RESIDENT_WORKSPACE_ID=ws FM_RESIDENT_PANE_ID=pane \
  "$ROOT/bin/fm-resident-publish.sh" ready
jq -e '.conversation.transcript.adapter == "codex-rollout-v1"' \
  "$HOME_DIR/state/resident-current.json" >/dev/null \
  || fail "Codex publication accepted a noncanonical adapter override"
pass "known harness publication forces the canonical adapter map"

VALID_POINTER="$TEST_ROOT/resident-current.valid.json"
cp "$HOME_DIR/state/resident-current.json" "$VALID_POINTER"
expect_doctor_failure() {
  local filter=$1 message=$2
  jq "$filter" "$VALID_POINTER" > "$HOME_DIR/state/resident-current.json.tmp"
  mv "$HOME_DIR/state/resident-current.json.tmp" "$HOME_DIR/state/resident-current.json"
  if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-doctor.sh" >/dev/null 2>&1; then
    fail "$message"
  fi
}
expect_doctor_failure 'del(.conversation.session_id)' "doctor accepted a missing conversation.session_id"
expect_doctor_failure 'del(.conversation.transcript.id)' "doctor accepted a missing conversation.transcript.id"
expect_doctor_failure '.conversation.transcript.id = "different"' "doctor accepted mismatched conversation ids"
expect_doctor_failure '.conversation.harness = "unknown"' "doctor accepted an unknown conversation harness"
cp "$VALID_POINTER" "$HOME_DIR/state/resident-current.json"
pass "doctor rejects incomplete, mismatched, and unknown conversation identities"

# FM_RESIDENT_HARNESS override wins over detected harness; no hardcode to claude.
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RESIDENT_PID="$$" FM_RESIDENT_HARNESS=grok \
  FM_RESIDENT_TRANSCRIPT="$P_GROK" FM_RESIDENT_SESSION_ID=override-sid \
  FM_RESIDENT_BACKEND_KIND=herdr FM_RESIDENT_WORKSPACE_ID=ws FM_RESIDENT_PANE_ID=pane \
  "$ROOT/bin/fm-resident-publish.sh" ready
jq -e '.conversation.harness == "grok" and .conversation.transcript.adapter == "grok-chat-history-v1" and .conversation.session_id == "override-sid"' \
  "$HOME_DIR/state/resident-current.json" >/dev/null \
  || fail "FM_RESIDENT_HARNESS=grok was not respected"
pass "FM_RESIDENT_HARNESS override is respected (not hardcoded claude)"

# Empty discovery for unknown harness omits conversation (honest unbound).
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RESIDENT_PID="$$" FM_RESIDENT_HARNESS=unknown \
  FM_RESIDENT_BACKEND_KIND=herdr FM_RESIDENT_WORKSPACE_ID=ws FM_RESIDENT_PANE_ID=pane \
  "$ROOT/bin/fm-resident-publish.sh" ready
jq -e 'has("conversation") == false' "$HOME_DIR/state/resident-current.json" >/dev/null \
  || fail "unknown harness should omit conversation"
pass "unknown harness omits conversation rather than faking claude"
