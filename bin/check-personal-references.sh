#!/usr/bin/env bash
# Fail when tracked text contains known local-operator identifiers.
# Optional allowlist entries in .personal-reference-allowlist are extended regular
# expressions matched against the complete path:line:text finding.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

marker_one='mli''ght'
marker_two='Kei''gyoku'
marker_three='myth''undrin'
marker_four='kun''chen'
pattern="${marker_one}|${marker_two}|${marker_three}|(^|[^[:alnum:]_])${marker_four}([^[:alnum:]_]|$)"
findings=$(git grep -n -I -i -E "$pattern" -- . || true)

allowlist=${PERSONAL_REFERENCE_ALLOWLIST:-.personal-reference-allowlist}
if [ -n "$findings" ] && [ -f "$allowlist" ]; then
  rules=$(mktemp)
  trap 'rm -f "$rules"' EXIT
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$allowlist" > "$rules"
  if [ -s "$rules" ]; then
    if filtered=$(grep -E -v -f "$rules" <<< "$findings"); then
      findings=$filtered
    else
      status=$?
      if [ "$status" -eq 1 ]; then
        findings=
      else
        printf 'Invalid personal-reference allowlist regex in %s.\n' "$allowlist" >&2
        exit "$status"
      fi
    fi
  fi
fi

if [ -n "$findings" ]; then
  printf '%s\n' 'Tracked personal references found:' >&2
  printf '%s\n' "$findings" >&2
  printf '%s\n' "Replace them with placeholders or add a narrow path:line:text regex to $allowlist." >&2
  exit 1
fi

printf '%s\n' 'Personal-reference guard passed.'
