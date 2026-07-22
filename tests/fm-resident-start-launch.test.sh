#!/usr/bin/env bash
# Behavior tests for Crew Lead start/restart --launch (firstmate-grade entrypath).
# Contract: Vellum agent.start argv = bin/fm-resident-start.sh --launch <harness> [args...]
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_ROOT=$(fm_test_tmproot fm-resident-start-launch)
HOME_DIR="$TEST_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
FAKEBIN=$(fm_fakebin "$TEST_ROOT")

# Isolate harness journal roots so publish never scans the operator's real trees.
export CLAUDE_HOME="$TEST_ROOT/claude-home"
export CODEX_HOME="$TEST_ROOT/codex-home"
export GROK_HOME="$TEST_ROOT/grok-home"
export CURSOR_HOME="$TEST_ROOT/cursor-home"
export PI_HOME="$TEST_ROOT/pi-home"
export HERMES_HOME="$TEST_ROOT/hermes-home"
export OPENCODE_TRANSCRIPT_ROOT="$TEST_ROOT/opencode.db"
export XDG_DATA_HOME="$TEST_ROOT/xdg-data"
mkdir -p "$CLAUDE_HOME" "$CODEX_HOME" "$GROK_HOME" "$CURSOR_HOME" "$PI_HOME" "$HERMES_HOME" "$XDG_DATA_HOME"

# --- usage -----------------------------------------------------------------
set +e
OUT=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-resident-start.sh" --launch 2>&1)
STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "--launch without cmd should fail"
case "$OUT" in
  *usage*|*--launch*) ;;
  *) fail "--launch without cmd should print usage; got: $OUT" ;;
esac
pass "start --launch without cmd fails with usage"

INVALID_HOME="$TEST_ROOT/invalid-home"
mkdir -p "$INVALID_HOME/state" "$INVALID_HOME/data" "$INVALID_HOME/config" "$INVALID_HOME/projects"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/not-executable"
mkdir "$TEST_ROOT/not-a-file"
for INVALID_CMD in "$TEST_ROOT/not-executable" "$TEST_ROOT/not-a-file"; do
  set +e
  OUT=$(FM_HOME="$INVALID_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-resident-start.sh" --launch "$INVALID_CMD" 2>&1)
  STATUS=$?
  set -e
  [ "$STATUS" -ne 0 ] || fail "--launch accepted invalid executable: $INVALID_CMD"
  case "$OUT" in
    *"cannot launch executable file"*) ;;
    *) fail "invalid executable did not report preflight error; got: $OUT" ;;
  esac
  [ ! -e "$INVALID_HOME/state/.lock" ] || fail "invalid executable created a session lock"
  [ ! -e "$INVALID_HOME/state/resident-current.json" ] || fail "invalid executable published resident state"
done
pass "start --launch rejects non-executable files and directories"

ZERO_PID_HOME="$TEST_ROOT/zero-pid-home"
set +e
OUT=$(FM_HOME="$ZERO_PID_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_LOCK_PID=0 \
  "$ROOT/bin/fm-lock.sh" 2>&1)
STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "fm-lock accepted FM_LOCK_PID=0"
case "$OUT" in
  *"positive integer process id"*) ;;
  *) fail "FM_LOCK_PID=0 did not report positive PID requirement; got: $OUT" ;;
esac
[ ! -e "$ZERO_PID_HOME/state/.lock" ] || fail "FM_LOCK_PID=0 created a session lock"
pass "fm-lock rejects FM_LOCK_PID=0"

EXEC_FAIL_HOME="$TEST_ROOT/exec-fail-home"
mkdir -p "$EXEC_FAIL_HOME/state" "$EXEC_FAIL_HOME/data" "$EXEC_FAIL_HOME/config" "$EXEC_FAIL_HOME/projects"
EXEC_FAIL_CMD="$TEST_ROOT/exec-fail"
printf '#!/definitely/missing/interpreter\n' > "$EXEC_FAIL_CMD"
chmod +x "$EXEC_FAIL_CMD"
set +e
OUT=$(FM_HOME="$EXEC_FAIL_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_RESIDENT_HARNESS=codex \
  "$ROOT/bin/fm-resident-start.sh" --launch "$EXEC_FAIL_CMD" 2>&1)
STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "--launch succeeded when exec failed"
case "$OUT" in
  *"failed to launch"*) ;;
  *) fail "exec failure did not report launch error; got: $OUT" ;;
esac
[ ! -e "$EXEC_FAIL_HOME/state/.lock" ] || fail "exec failure left the session lock"
jq -e '.lifecycle == "stopped" and (.process | not)' \
  "$EXEC_FAIL_HOME/state/resident-current.json" >/dev/null \
  || fail "exec failure did not replace ready state with stopped"
pass "start --launch stops resident state and clears lock after exec failure"

# --- default path still delegates to lock (no exec) ------------------------
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf 'codex\n' ;;
  *"args="*) printf 'codex test harness\n' ;;
  *"ppid="*) printf '1\n' ;;
esac
SH
chmod +x "$FAKEBIN/ps"
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-resident-start.sh" 2>&1) || fail "default start failed: $OUT"
case "$OUT" in
  *"lock acquired"*) ;;
  *) fail "default start did not acquire lock; got: $OUT" ;;
esac
[ -s "$HOME_DIR/state/resident-current.json" ] \
  || fail "default start did not publish resident-current"
jq -e '.lifecycle == "ready" and .process.pid' "$HOME_DIR/state/resident-current.json" >/dev/null \
  || fail "default start pointer missing ready process"
pass "default start (no --launch) still lock+publish only"

# --- --launch: setup/publish then exec so pane PID becomes harness ---------
LAUNCH_HOME="$TEST_ROOT/launch-home"
mkdir -p "$LAUNCH_HOME/state" "$LAUNCH_HOME/data" "$LAUNCH_HOME/config" "$LAUNCH_HOME/projects"
MARKER="$TEST_ROOT/launch-marker"
HARNESS_LOG="$TEST_ROOT/harness-args"

cat > "$FAKEBIN/fake-harness" <<SH
#!/usr/bin/env bash
{
  echo "pid=\$\$"
  echo "lock=\$(cat '$LAUNCH_HOME/state/.lock' 2>/dev/null || true)"
  echo "argv0=\$0"
  echo "args=\$*"
  if [ -s '$LAUNCH_HOME/state/resident-current.json' ]; then
    jq -c '{lifecycle, process}' \
      '$LAUNCH_HOME/state/resident-current.json' 2>/dev/null || true
  fi
} > '$MARKER'
printf '%s\n' "\$@" > '$HARNESS_LOG'
exit 0
SH
chmod +x "$FAKEBIN/fake-harness"

set +e
PATH="$FAKEBIN:$PATH" FM_HOME="$LAUNCH_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RESIDENT_HARNESS=codex \
  "$ROOT/bin/fm-resident-start.sh" --launch fake-harness --flag value 2>"$TEST_ROOT/launch.err"
LAUNCH_STATUS=$?
set -e
[ "$LAUNCH_STATUS" -eq 0 ] || fail "start --launch failed (exit $LAUNCH_STATUS): $(cat "$TEST_ROOT/launch.err" 2>/dev/null || true)"
[ -s "$MARKER" ] || fail "start --launch did not exec fake-harness (no marker)"

LAUNCH_PID=$(grep '^pid=' "$MARKER" | cut -d= -f2)
LOCK_PID=$(grep '^lock=' "$MARKER" | cut -d= -f2)
[ -n "$LAUNCH_PID" ] || fail "marker missing pid"
[ "$LAUNCH_PID" = "$LOCK_PID" ] \
  || fail "lock PID ($LOCK_PID) must equal harness PID after exec ($LAUNCH_PID)"

jq -e --argjson pid "$LAUNCH_PID" '
  .lifecycle == "ready"
  and .process.pid == $pid
  and (.process.creation_identity | type == "string" and length > 0)
' "$LAUNCH_HOME/state/resident-current.json" >/dev/null \
  || fail "launch publish missing process identity for exec PID $LAUNCH_PID"

[ "$(cat "$LAUNCH_HOME/state/.lock")" = "$LAUNCH_PID" ] \
  || fail "post-exit lock file drifted from launch PID"

grep -qx -- '--flag' "$HARNESS_LOG" || fail "harness missing --flag arg"
grep -qx -- 'value' "$HARNESS_LOG" || fail "harness missing value arg"
pass "start --launch publishes self-PID then execs harness"

# --- without FM_RESIDENT_HARNESS: basename used, still setup+publish+exec ---
BASENAME_HOME="$TEST_ROOT/basename-home"
mkdir -p "$BASENAME_HOME/state" "$BASENAME_HOME/data" "$BASENAME_HOME/config" "$BASENAME_HOME/projects"
MARKER2="$TEST_ROOT/basename-marker"
cat > "$FAKEBIN/codex" <<SH
#!/usr/bin/env bash
{
  echo "pid=\$\$"
  echo "lock=\$(cat '$BASENAME_HOME/state/.lock')"
  jq -e '.process.pid' '$BASENAME_HOME/state/resident-current.json' >/dev/null
} > '$MARKER2'
exit 0
SH
chmod +x "$FAKEBIN/codex"

set +e
# Unset harness env so start must derive basename(cmd).
env -u FM_RESIDENT_HARNESS PATH="$FAKEBIN:$PATH" FM_HOME="$BASENAME_HOME" \
  FM_ROOT_OVERRIDE="$ROOT" \
  CLAUDE_HOME="$CLAUDE_HOME" CODEX_HOME="$CODEX_HOME" GROK_HOME="$GROK_HOME" \
  CURSOR_HOME="$CURSOR_HOME" PI_HOME="$PI_HOME" HERMES_HOME="$HERMES_HOME" \
  OPENCODE_TRANSCRIPT_ROOT="$OPENCODE_TRANSCRIPT_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$ROOT/bin/fm-resident-start.sh" --launch codex 2>"$TEST_ROOT/basename.err"
set -e
[ -s "$MARKER2" ] || fail "basename launch did not exec: $(cat "$TEST_ROOT/basename.err" 2>/dev/null || true)"
[ -s "$BASENAME_HOME/.god-node/provision.json" ] \
  || fail "basename launch did not run setup"
jq -e '.process.pid' "$BASENAME_HOME/state/resident-current.json" >/dev/null \
  || fail "basename launch did not publish process"
pass "start --launch without FM_RESIDENT_HARNESS still setup+publish+exec"

# --- refuses when another live harness holds the lock ----------------------
BUSY_HOME="$TEST_ROOT/busy-home"
mkdir -p "$BUSY_HOME/state" "$BUSY_HOME/data" "$BUSY_HOME/config" "$BUSY_HOME/projects"
printf '%s\n' "$$" > "$BUSY_HOME/state/.lock"
# Any pid query reports a live codex holder (including this test shell).
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf 'codex\n' ;;
  *"args="*) printf 'codex held session\n' ;;
  *"ppid="*) printf '1\n' ;;
esac
SH
chmod +x "$FAKEBIN/ps"
set +e
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$BUSY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-resident-start.sh" --launch fake-harness 2>&1)
STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "start --launch should refuse when lock held by live harness"
case "$OUT" in
  *"another live"*) ;;
  *) fail "expected another-live error; got: $OUT" ;;
esac
pass "start --launch refuses when another live harness holds lock"

# --- restart --launch shares start entrypath -------------------------------
RESTART_HOME="$TEST_ROOT/restart-home"
mkdir -p "$RESTART_HOME/state" "$RESTART_HOME/data" "$RESTART_HOME/config" "$RESTART_HOME/projects"
MARKER3="$TEST_ROOT/restart-marker"
cat > "$FAKEBIN/restart-harness" <<SH
#!/usr/bin/env bash
echo "pid=\$\$" > '$MARKER3'
echo "lock=\$(cat '$RESTART_HOME/state/.lock')" >> '$MARKER3'
exit 0
SH
chmod +x "$FAKEBIN/restart-harness"
# Stale lock (pid 1 as non-harness) so restart may acquire.
printf '1\n' > "$RESTART_HOME/state/.lock"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-p 1 "*|*" -p 1"|*-p" "1"|*"-p 1")
    case "$*" in
      *"comm="*) printf 'init\n' ;;
      *"args="*) printf 'init\n' ;;
    esac
    exit 0
    ;;
  *"comm="*) printf 'bash\n' ;;
  *"args="*) printf 'bash\n' ;;
  *"ppid="*) printf '1\n' ;;
esac
SH
chmod +x "$FAKEBIN/ps"
set +e
PATH="$FAKEBIN:$PATH" FM_HOME="$RESTART_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RESIDENT_HARNESS=codex \
  "$ROOT/bin/fm-resident-restart.sh" --launch restart-harness 2>"$TEST_ROOT/restart.err"
RSTATUS=$?
set -e
[ "$RSTATUS" -eq 0 ] || fail "restart --launch failed: $(cat "$TEST_ROOT/restart.err" 2>/dev/null || true)"
[ -s "$MARKER3" ] || fail "restart --launch did not exec harness"
RPID=$(grep '^pid=' "$MARKER3" | cut -d= -f2)
RLOCK=$(grep '^lock=' "$MARKER3" | cut -d= -f2)
[ "$RPID" = "$RLOCK" ] || fail "restart lock PID != harness PID"
pass "restart --launch publishes self-PID then execs harness"
