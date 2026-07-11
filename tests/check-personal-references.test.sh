#!/usr/bin/env bash
# Behavior coverage for the tracked-file personal-reference guard.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

repo="$TMP_ROOT/repo"
mkdir -p "$repo/bin"
cp "$ROOT/bin/check-personal-references.sh" "$repo/bin/"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name Test
printf '%s\n' 'neutral content' > "$repo/README.md"
git -C "$repo" add .

(cd "$repo" && bin/check-personal-references.sh) >/dev/null || fail 'neutral tracked text was rejected'

marker='mli''ght'
printf 'local operator: %s\n' "$marker" > "$repo/evidence.txt"
git -C "$repo" add evidence.txt
if (cd "$repo" && bin/check-personal-references.sh) >/dev/null 2>&1; then
  fail 'tracked personal marker was accepted'
fi

printf '%s\n' '^evidence.txt:[0-9]+:local operator: ' > "$repo/.personal-reference-allowlist"
git -C "$repo" add .personal-reference-allowlist
(cd "$repo" && bin/check-personal-references.sh) >/dev/null || fail 'narrow allowlist rule was ignored'

printf '%s\n' "$marker" > "$repo/untracked.txt"
(cd "$repo" && bin/check-personal-references.sh) >/dev/null || fail 'untracked text was scanned'

printf '%s\n' 'PASS: check-personal-references'
