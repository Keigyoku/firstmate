#!/usr/bin/env bash
# Pins that fleet-local operational dirs are ignored as directories (fail-closed),
# not as fail-open per-file enumerations. New files under those dirs must stay
# private without a .gitignore edit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# config/ is LOCAL per AGENTS.md / CONTRIBUTING.md. Directory ignore, not a file list.
grep -qxF 'config/' "$ROOT/.gitignore" \
  || fail ".gitignore must ignore the whole config/ directory (not a per-file list)"

# Fail-open regression: a never-listed config path must already be ignored.
git -C "$ROOT" check-ignore -q config/never-listed-scratch-file \
  || fail "config/never-listed-scratch-file must be ignored without editing .gitignore"
git -C "$ROOT" check-ignore -q config/cloudflare.env \
  || fail "config/cloudflare.env must be ignored"
git -C "$ROOT" check-ignore -q config/tdd-hook \
  || fail "config/tdd-hook must be ignored (documented LOCAL; was missing from old per-file list)"

# No tracked material under config/ — if this ever changes, add an explicit ! exception.
tracked=$(git -C "$ROOT" ls-files 'config/**' 'config/*' 2>/dev/null || true)
[ -z "$tracked" ] \
  || fail "tracked files under config/ would be ignored by config/; un-ignore with ! if intentional: $tracked"

# state/ already directory-ignored (runtime markers land here, never under bin/).
grep -qxF 'state/' "$ROOT/.gitignore" \
  || fail ".gitignore must ignore the whole state/ directory"
git -C "$ROOT" check-ignore -q state/tdd-red-seen \
  || fail "state/tdd-red-seen must be ignored"

pass "local operational dirs are directory-ignored (config/, state/)"
