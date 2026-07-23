#!/usr/bin/env bash
# Behavior tests for bin/fm-lock-lib.sh (shared git lock staleness proof).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-lock-lib.sh"
[ -f "$LIB" ] || fail "missing bin/fm-lock-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$LIB"

# Note: fm_test_tmproot registers cleanup in the $(...) subshell EXIT, which can
# remove the dir before the parent uses it; recreate with mkdir -p like other suites.

test_fresh_lock_not_stale() {
  local dir lock
  dir=$(fm_test_tmproot fm-lock-fresh)
  mkdir -p "$dir"
  lock="$dir/index.lock"
  : > "$lock" || fail "could not create $lock"
  if fm_lock_is_provably_stale "$lock" "$dir" 30; then
    fail "fresh lock must not be provably stale"
  fi
  pass "fm-lock-lib: fresh lock is not provably stale"
}

test_old_lock_without_holder_is_stale() {
  local dir lock
  dir=$(fm_test_tmproot fm-lock-old)
  mkdir -p "$dir"
  lock="$dir/index.lock"
  : > "$lock" || fail "could not create $lock"
  python3 - "$lock" <<'PY2'
import os, sys, time
path = sys.argv[1]
now = time.time()
os.utime(path, (now - 120, now - 120))
PY2
  if ! fm_lock_is_provably_stale "$lock" "$dir" 30; then
    fail "old lock with no holder should be provably stale"
  fi
  pass "fm-lock-lib: old lock with no holder is provably stale"
}

test_teardown_sources_lock_lib() {
  assert_contains "$(cat "$ROOT/bin/fm-teardown.sh")" 'fm-lock-lib.sh' \
    'teardown must source shared lock-lib'
  assert_contains "$(cat "$ROOT/bin/fm-teardown.sh")" 'fm_lock_is_provably_stale' \
    'teardown must call fm_lock_is_provably_stale rather than only inline proof'
  assert_contains "$(cat "$ROOT/bin/fm-teardown.sh")" 'alternate_home_spelling_for_dir' \
    'teardown must keep /home <-> /var/home path-spelling retry'
  pass "fm-teardown sources lock-lib and keeps path-spelling helper"
}

test_fresh_lock_not_stale
test_old_lock_without_holder_is_stale
test_teardown_sources_lock_lib
