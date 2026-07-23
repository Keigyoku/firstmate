#!/usr/bin/env bash
# Behavior tests for the bearings projection wrapper over fm-fleet-snapshot.sh.
# Covers the output/token bound, TOON/JSON parity, the local-only default (zero
# GitHub/network calls), the --include-prs opt-in path, graceful degradation on a
# partial PR-fetch failure, fork-native pending_decision surfaces (decision-hold #593 stubbed),
# gates blocked_by string fallback, the four-section chat contract, and report pointers.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fakebin that stubs the local tools the canonical snapshot may reach for, plus a
# gh/gh-axi that RECORDS every call to $NET_LOG so a test can prove the default path
# makes no network call. gh returns one fixture open PR keyed to the ship task.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) case "$*" in *dead-*) exit 1 ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "${FAKE_GH_SLEEP:-0}" = 1 ]; then sleep 30; fi
if [ "${FAKE_GH_MANY:-0}" = 1 ]; then
  cat <<'JSON'
[{"number":1,"title":"One","url":"https://github.com/acme/repo/pull/1","headRefName":"fm/one","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":2,"title":"Two","url":"https://github.com/acme/repo/pull/2","headRefName":"fm/two","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":3,"title":"Three","url":"https://github.com/acme/repo/pull/3","headRefName":"fm/three","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]
JSON
  exit 0
fi
cat <<'JSON'
[{"number":9,"title":"Ship the thing","url":"https://github.com/kunchenguid/firstmate/pull/9","headRefName":"fm/ship-task","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]
JSON
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$home/secondmate-home"
  printf '%s\n' "$home"
}

# Standard fixture: a ship task with a recorded PR, a scout task with a report, a
# secondmate with a MASKED open decision (needs-decision then a later unrelated
# done), and a backlog with a superseded queued item.
write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/ship-wt" "$home/data/scout-x"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] scout-x - Investigate the thing data/scout-x/report.md (repo: firstmate) (kind: scout) (since 2026-07-11)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: firstmate) (kind: ship)
- [ ] dead-gate - Old conditional work (repo: firstmate) (kind: scout)
  NOT REQUIRED - superseded 2026-07-11; kept as reference only.

## Done
- [x] done-a - Landed thing https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF
  printf '# Scout X\n' > "$home/data/scout-x/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'working: building the thing\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-x.meta" \
    "window=firstmate:fm-scout-x" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report ready\n' > "$home/state/scout-x.status"
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=firstmate"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$home/state/mate.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/mate.status"
}

run() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" "$BEARINGS" "$@"
}

test_default_is_bounded_and_local_only() {
  local home fakebin toon json
  home=$(make_home bounded); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Bound: well under the ~50 KB tool-display limit.
  [ "${#toon}" -lt 50000 ] || fail "default TOON must stay under the display bound, got ${#toon}"
  # TOON is materially smaller than the canonical snapshot it projects.
  local canon; canon=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  [ "${#toon}" -lt "${#canon}" ] || fail "projection must be smaller than the canonical snapshot"
  # Local-only: no GitHub/network call on the default path.
  [ ! -s "$home/net.log" ] || fail "default run must make no gh/gh-axi call, got: $(cat "$home/net.log")"
  # Definitive not-requested PR state, never a silent omission.
  assert_contains "$toon" 'prs: "not_requested' "default must state PR checks were not requested"
  assert_contains "$toon" "live PR discovery + checks,\"--include-prs\"" "omitted must mark the dropped live-PR surface"
  # Valid JSON, correct schema.
  printf '%s' "$json" | jq -e '.schema == "fm-bearings.v1"' >/dev/null || fail "json schema wrong"
  pass "default output is bounded, local-only, and marks omitted surfaces"
}

test_toon_json_parity() {
  local home fakebin toon json keys k
  home=$(make_home parity); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Same top-level keys in both representations.
  keys=$(printf '%s' "$json" | jq -r 'keys_unsorted[]')
  for k in $keys; do
    if printf '%s' "$json" | jq -e --arg k "$k" '.[$k] | type == "array"' >/dev/null; then
      local n hdr
      n=$(printf '%s' "$json" | jq --arg k "$k" '.[$k] | length')
      if [ "$n" = 0 ]; then
        assert_contains "$toon" "$k: []" "empty array $k must render as 'key: []'"
      else
        # Header must declare the same count and the same field set.
        hdr=$(printf '%s' "$toon" | grep -E "^$k\[[0-9]+\]\{" || true)
        [ -n "$hdr" ] || fail "TOON missing tabular header for $k"
        assert_contains "$hdr" "[$n]" "TOON $k row count must equal JSON length $n"
        local jfields tfields
        jfields=$(printf '%s' "$json" | jq -r --arg k "$k" '.[$k][0] | keys_unsorted | join(",")')
        tfields=$(printf '%s' "$hdr" | sed -E 's/^[^{]*\{//; s/\}:.*$//; s/"//g')
        [ "$jfields" = "$tfields" ] || fail "TOON $k fields ($tfields) must equal JSON fields ($jfields)"
      fi
    else
      # Scalar: the key must appear as a "key: value" line.
      assert_contains "$toon" "$k: " "TOON must carry scalar field $k"
    fi
  done
  pass "TOON and JSON are parity representations of the same model"
}

test_open_decision_surfaces_end_to_end() {
  # Fork adaptation (no #593 decision-hold, no status_open_decisions fold):
  # a parked needs-decision status surfaces via fleet-snapshot hints.pending_decision.
  local home fakebin json
  home=$(make_home e2e-decision); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/dec-wt"
  fm_write_meta "$home/state/dec-a.meta" \
    "window=firstmate:fm-dec-a" \
    "worktree=$home/projects/dec-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'needs-decision: pick A or B for the rollout\n' > "$home/state/dec-a.status"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.[]; .id == "dec-a" and .verb == "needs-decision")
  ' >/dev/null || fail "a parked needs-decision must surface in decisions_open via status hints: $json"
  pass "a parked needs-decision surfaces end-to-end via fork status hints"
}

test_decision_hold_captain_hold_is_stubbed() {
  # #593 decision-hold is not ported: a free-form backlog hold must NOT invent
  # a captain-hold decisions_open row (that path requires decision-hold machinery).
  local home fakebin json
  home=$(make_home hold-stub); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] hold-item - Waiting on captain (repo: firstmate) (kind: ship)

## Done
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .verb == "captain-hold") | not)
  ' >/dev/null || fail "without #593, decisions_open must not invent captain-hold rows: $json"
  pass "decision-hold captain-hold path is stubbed without #593"
}

test_secondmate_status_decisions_preserve_captain_decision() {
  local home mate fakebin json id
  home=$(make_home secondmate-status-decisions)
  mate="$TMP_ROOT/secondmate-status-decisions-home"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf 'mate-status\n' > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  for id in choose-rollout blocked-release; do
    mkdir -p "$mate/projects/$id"
    fm_write_meta "$mate/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$mate/projects/$id" \
      "project=alpha" "harness=codex" "kind=ship" "mode=ship"
  done
  printf 'needs-decision: choose blue or green rollout\n' > "$mate/state/choose-rollout.status"
  printf 'blocked: release credentials need approval\n' > "$mate/state/blocked-release.status"
  printf '%s\n' "- mate-status - delivery (home: $mate; scope: alpha; projects: alpha; added 2026-07-01)" \
    > "$home/data/secondmates.md"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json --all-decisions)
  printf '%s' "$json" | jq -e '
    ([.secondmates[]
      | select(.id == "mate-status" and .state == "captain_decision")
      | select(.doing | contains("choose blue or green rollout") and contains("release credentials need approval"))]
      | length) == 1
      and ([.decisions_open[]
        | select(.owner == "mate-status" and (.verb == "needs-decision" or .verb == "blocked"))]
        | length) == 2
      and (.decisions_open | any(.[]; .owner == "mate-status" and .verb == "captain-hold") | not)
  ' >/dev/null || fail "supported secondmate status decisions must preserve captain_decision without #593: $json"
  pass "secondmate status decisions preserve captain_decision without decision-hold machinery"
}

test_gates_use_string_blocked_by() {
  local home fakebin json
  home=$(make_home blocked-by); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    .gates | any(.[]; .id == "live-gate" and .blocked_by == "ship-task")
  ' >/dev/null || fail "gates must map fork string blocked_by: $json"
  pass "gates fall back to string blocked_by on the fork schema"
}

test_gates_distinguish_empty_normalized_blockers_from_absent() {
  local home mate fakebin json legacy_json shim
  home=$(make_home resolved-blockers)
  mate="$TMP_ROOT/resolved-blockers-mate"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf 'mate-resolved\n' > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] main-gate - Main gate blocked-by: main-done (repo: firstmate) (kind: ship)

## Done
- [x] main-done - Main dependency (repo: firstmate) (kind: ship)
EOF
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] mate-gate - Mate gate blocked-by: mate-done (repo: firstmate) (kind: ship)

## Done
- [x] mate-done - Mate dependency (repo: firstmate) (kind: ship)
EOF
  printf '%s\n' "- mate-resolved - delivery (home: $mate; scope: firstmate; projects: firstmate; added 2026-07-01)" \
    > "$home/data/secondmates.md"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json --all-queued)
  printf '%s' "$json" | jq -e '
    ([.gates[] | select(.id == "main-gate" and .owner == "(main)" and .blocked_by == "-")] | length) == 1
      and ([.gates[] | select(.id == "mate-gate" and .owner == "mate-resolved" and .blocked_by == "-")] | length) == 1
  ' >/dev/null || fail "present-empty normalized blockers must not fall back to resolved raw dependencies: $json"

  shim="$home/bearings-shim"
  mkdir -p "$shim"
  cp "$BEARINGS" "$shim/fm-bearings-snapshot.sh"
  cat > "$shim/fm-fleet-snapshot.sh" <<EOF
#!/usr/bin/env bash
"$ROOT/bin/fm-fleet-snapshot.sh" "\$@" | jq '
  (.backlog.records[] | select(.id == "main-gate")) |= del(.unresolved_blocker_ids)
  | (.secondmate_current.records[].queued[] | select(.id == "mate-gate")) |= del(.unresolved_blocker_ids)
'
EOF
  chmod +x "$shim/fm-fleet-snapshot.sh"
  legacy_json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z \
    NET_LOG="$home/net.log" "$shim/fm-bearings-snapshot.sh" --json --all-queued)
  printf '%s' "$legacy_json" | jq -e '
    ([.gates[] | select(.id == "main-gate" and .owner == "(main)" and .blocked_by == "main-done")] | length) == 1
      and ([.gates[] | select(.id == "mate-gate" and .owner == "mate-resolved" and .blocked_by == "mate-done")] | length) == 1
  ' >/dev/null || fail "absent normalized blockers must retain the raw blocked_by compatibility fallback: $legacy_json"
  pass "gates use normalized empty blockers and retain the absent-field fallback in both homes"
}

test_chat_contract_four_sections() {
  local skill body headings report_headings expected
  skill="$ROOT/.agents/skills/bearings/SKILL.md"
  [ -f "$skill" ] || fail "bearings SKILL.md missing at $skill"
  body=$(awk '/^## Chat-response contract$/{capture=1; next} capture && /^## /{exit} capture' "$skill")
  headings=$(printf '%s\n' "$body" | sed -nE "s/^[0-9]+\. \*\*([^*]+)\*\*.*/\1/p")
  expected=$(printf '%s\n' "Captain's Call" "Recently Landed" "Underway" "Charted Next")
  [ "$headings" = "$expected" ] || fail "chat contract must contain exactly four numbered sections in fixed order, got: $headings"
  assert_contains "$body" "Nothing needs your action right now" "Captain's Call empty-state sentence"
  assert_contains "$body" "No recent completions are in the current baseline" "Recently Landed empty-state sentence"
  assert_contains "$body" "Nothing is underway" "Underway empty-state sentence"
  assert_contains "$body" "Nothing is queued" "Charted Next empty-state sentence"
  report_headings=$(sed -nE 's/^   - \*\*(Captain.s Call|Recently Landed|Underway|Charted Next)\*\*.*/\1/p' "$skill")
  [ "$report_headings" = "$expected" ] || fail "detailed report contract must contain the same four complete sections, got: $report_headings"
  grep -Eq 'since the (prior|last) report|Nothing has landed since|unchanged delta' "$skill" \
    && fail "bearings contract still contains prior-report delta wording"
  # shellcheck disable=SC2016
  assert_contains "$(cat "$skill")" 'Never read an earlier `data/status-report-*.md`' "prior reports must not influence current output"
  assert_contains "$(cat "$skill")" "bounded current recent-completions baseline" "Recently Landed must be a current baseline"
  assert_contains "$body" "no At Anchor section" "the At Anchor exclusion must be documented"
  assert_contains "$body" "materially shorter" "the chat must be materially shorter than the report file"
  assert_contains "$body" "links to" "the chat must link to the report file"
  pass "the /bearings skill states the four-section chat contract in order, with empty-states and the At Anchor exclusion"
}

test_report_pointers_surface() {
  local home fakebin json
  home=$(make_home reports); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e --arg p "$home/data/scout-x/report.md" '
    .reports | any(.[]; .id == "scout-x" and .path == $p)
  ' >/dev/null || fail "current scout report pointer must surface: $json"
  pass "current report pointers surface"
}

test_underway_only_includes_working_in_flight_tasks() {
  local home fakebin json state
  home=$(make_home underway-state); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  for state in failed parked queued; do
    mkdir -p "$home/projects/$state-wt"
    fm_write_meta "$home/state/$state-task.meta" \
      "window=firstmate:fm-$state-task" \
      "worktree=$home/projects/$state-wt" \
      "project=firstmate" \
      "harness=codex" \
      "kind=ship" \
      "mode=no-mistakes"
  done
  printf 'failed: validation failed\n' > "$home/state/failed-task.status"
  printf 'needs-decision: choose a rollout\n' > "$home/state/parked-task.status"
  printf 'working: queued item should stay queued\n' > "$home/state/queued-task.status"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship)

## Queued
- [ ] queued-task - Queued task with retained metadata (repo: firstmate) (kind: ship)

## Done
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] == ["ship-task"])
  ' >/dev/null || fail "Underway must contain only working tasks in the fork in-flight backlog role: $json"
  pass "Underway excludes terminal, parked, and queued retained metadata"
}

test_superseded_queued_item_dropped_by_default() {
  local home fakebin json
  home=$(make_home superseded); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.gates | any(.[]; .id == "live-gate")) and (.gates | any(.[]; .id == "dead-gate") | not)
  ' >/dev/null || fail "default gates must include live and drop superseded: $json"
  json=$(run "$home" "$fakebin" --json --all-queued)
  printf '%s' "$json" | jq -e '.gates | any(.[]; .id == "dead-gate")' >/dev/null \
    || fail "--all-queued must restore the superseded item"
  pass "superseded queued items are dropped by default and restored with --all-queued"
}

test_include_prs_is_the_only_fetch_path() {
  local home fakebin json
  home=$(make_home prs); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(run "$home" "$fakebin" --include-prs --json)
  # Now gh WAS called, exactly for pr list.
  grep -q '^gh pr list ' "$home/net.log" || fail "--include-prs must call gh pr list"
  printf '%s' "$json" | jq -e '
    .prs | startswith("checked")
  ' >/dev/null || fail "--include-prs must report checked PR state"
  printf '%s' "$json" | jq -e '
    .candidate_prs | any(.[]; .num == "9" and .task == "ship-task" and .checks == "passing" and .review == "APPROVED")
  ' >/dev/null || fail "candidate_prs must carry the fetched PR cross-referenced to its task: $json"
  pass "--include-prs is the only path that fetches, and it enriches correctly"
}

test_partial_github_failure_degrades() {
  local home fakebin json rc
  home=$(make_home partial); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FAKE_GH_FAIL=1 run "$home" "$fakebin" --include-prs --json); rc=$?
  expect_code 0 "$rc" "a PR-fetch failure must not crash the view"
  printf '%s' "$json" | jq -e '
    .schema == "fm-bearings.v1"
      and (.candidate_prs | length) == 0
      and (.prs | test("unavailable"))
      and (.in_flight | length) > 0
  ' >/dev/null || fail "on gh failure the view must still emit, with an unavailable note: $json"
  pass "a partial GitHub failure degrades gracefully"
}

test_perl_fallback_bounds_github_call() {
  local home fakebin toolbin cmd json started elapsed
  home=$(make_home perl-timeout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toolbin="$home/toolbin"
  mkdir -p "$toolbin"
  for cmd in bash dirname basename jq date sed git grep tail cut tr head sort wc perl sleep cat find; do
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  started=$(date +%s)
  json=$(PATH="$fakebin:$toolbin" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z \
    FM_BEARINGS_PR_TIMEOUT=1 NET_LOG="$home/net.log" FAKE_GH_SLEEP=1 "$BEARINGS" --include-prs --json)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] || fail "Perl fallback did not bound a stalled gh call (${elapsed}s)"
  printf '%s' "$json" | jq -e '.prs | test("unavailable")' >/dev/null \
    || fail "timed-out gh call did not fail soft: $json"
  pass "Perl fallback bounds stalled GitHub calls without coreutils timeout"
}

write_large_fixture() {  # <home> <count>
  # dead-* endpoints fail the fake tmux probe (unhealthy_endpoints caps).
  # decisions_open still surfaces from last_event needs-decision text without #593.
  local home=$1 count=$2 i id
  : > "$home/data/backlog.md"
  printf '## Queued\n' >> "$home/data/backlog.md"
  i=1
  while [ "$i" -le "$count" ]; do
    id="dead-$i"
    mkdir -p "$home/projects/$id" "$home/projects/work-$i" "$home/projects/decision-$i" "$home/data/$id"
    printf '# Report\n' > "$home/data/$id/report.md"
    printf -- '- [ ] gate-%s - Gate %s blocked-by: task-%s (repo: repo-%s) (kind: ship)\n' "$i" "$i" "$i" "$i" >> "$home/data/backlog.md"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id" \
      "project=repo-$i" \
      "harness=codex" \
      "kind=scout" \
      "mode=scout" \
      "pr=https://github.com/acme/repo-$i/pull/$i"
    printf 'failed: endpoint unavailable\n' > "$home/state/$id.status"
    fm_write_meta "$home/state/work-$i.meta" \
      "window=firstmate:fm-work-$i" \
      "worktree=$home/projects/work-$i" \
      "project=repo-$i" \
      "harness=codex" \
      "kind=ship" \
      "mode=no-mistakes"
    printf 'working: progressing item %s\n' "$i" > "$home/state/work-$i.status"
    fm_write_meta "$home/state/decision-$i.meta" \
      "window=firstmate:fm-decision-$i" \
      "worktree=$home/projects/decision-$i" \
      "project=repo-$i" \
      "harness=codex" \
      "kind=ship" \
      "mode=no-mistakes"
    printf 'needs-decision [key=q%s]: choose %s\n' "$i" "$i" > "$home/state/decision-$i.status"
    i=$((i + 1))
  done
}

test_section_caps_and_expansion_flags() {
  local home fakebin json expanded
  home=$(make_home caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight|length) == 2 and (.decisions_open|length) == 2 and (.gates|length) == 2
    and (.reports|length) == 2 and (.recorded_prs|length) == 2 and (.unhealthy_endpoints|length) == 2
    and ([.omitted[].surface] | index("in_flight showing 2 of 5") != null)
    and ([.omitted[].surface] | index("decisions_open showing 2 of 5") != null)
    and ([.omitted[].surface] | index("gates showing 2 of 5") != null)
    and ([.omitted[].surface] | index("reports showing 2 of 5") != null)
    and ([.omitted[].surface] | index("recorded_prs showing 2 of 5") != null)
    and ([.omitted[].surface] | index("unhealthy_endpoints showing 2 of 5") != null)
  ' >/dev/null || fail "section caps or counted omissions are wrong: $json"
  expanded=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json --all-in-flight --all-decisions --all-queued \
      --all-reports --all-recorded-prs --all-unhealthy)
  printf '%s' "$expanded" | jq -e '
    (.in_flight|length) == 5 and (.decisions_open|length) == 5 and (.gates|length) == 5
    and (.reports|length) == 5 and (.recorded_prs|length) == 5 and (.unhealthy_endpoints|length) == 5
  ' >/dev/null || fail "section expansion flags did not reveal full sets: $expanded"
  pass "all fleet-sized sections are capped with counted opt-in expansion"
}

test_secondmate_caps_reach_omitted_and_all_flags_expand() {
  local home mate fakebin json expanded id
  home=$(make_home secondmate-caps)
  mate="$TMP_ROOT/secondmate-caps-home"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf 'mate-caps\n' > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] active-one - Active one (repo: alpha) (kind: ship)
- [ ] active-two - Active two (repo: alpha) (kind: ship)

## Queued
- [ ] gate-one - Gate one blocked-by: active-one - waiting (repo: alpha) (kind: ship)
- [ ] gate-two - Gate two blocked-by: active-two - waiting (repo: alpha) (kind: ship)

## Done
EOF
  for id in active-one active-two; do
    mkdir -p "$mate/projects/$id"
    fm_write_meta "$mate/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$mate/projects/$id" \
      "project=alpha" "harness=codex" "kind=ship" "mode=ship"
    printf 'working: progressing %s\n' "$id" > "$mate/state/$id.status"
  done
  for id in decision-one decision-two; do
    mkdir -p "$mate/projects/$id"
    fm_write_meta "$mate/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$mate/projects/$id" \
      "project=alpha" "harness=codex" "kind=ship" "mode=ship"
    printf 'needs-decision: choose for %s\n' "$id" > "$mate/state/$id.status"
  done
  for id in dead-one dead-two; do
    mkdir -p "$mate/projects/$id"
    fm_write_meta "$mate/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$mate/projects/$id" \
      "project=alpha" "harness=codex" "kind=ship" "mode=ship"
    printf 'failed: endpoint unavailable\n' > "$mate/state/$id.status"
  done
  printf '%s\n' "- mate-caps - delivery (home: $mate; scope: alpha; projects: alpha; added 2026-07-01)" \
    > "$home/data/secondmates.md"
  fakebin=$(make_fakebin "$home")
  json=$(FM_SNAPSHOT_SECONDMATE_CHILDREN=1 FM_SNAPSHOT_SECONDMATE_QUEUED=1 \
    FM_SNAPSHOT_SECONDMATE_DECISIONS=1 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.omitted[] | select(.surface == "secondmate mate-caps active_children showing 1 of 2" and .reveal == "--all-in-flight")] | length) == 1
      and ([.omitted[] | select(.surface == "secondmate mate-caps decisions_open showing 1 of 2" and .reveal == "--all-decisions")] | length) == 1
      and ([.omitted[] | select(.surface == "secondmate mate-caps holds showing 1 of 2" and .reveal == "--all-queued")] | length) == 1
      and ([.omitted[] | select(.surface == "secondmate mate-caps queued showing 1 of 2" and .reveal == "--all-queued")] | length) == 1
      and ([.omitted[] | select(.surface == "secondmate mate-caps endpoints showing 1 of 6" and .reveal == "--all-unhealthy")] | length) == 1
  ' >/dev/null || fail "Bearings did not surface per-home snapshot truncation: $json"
  expanded=$(FM_SNAPSHOT_SECONDMATE_CHILDREN=1 FM_SNAPSHOT_SECONDMATE_QUEUED=1 \
    FM_SNAPSHOT_SECONDMATE_DECISIONS=1 run "$home" "$fakebin" --json \
      --all-in-flight --all-decisions --all-queued --all-unhealthy)
  printf '%s' "$expanded" | jq -e '
    ([.secondmates[] | select(.id == "mate-caps" and .state == "captain_decision")] | length) == 1
      and (.in_flight | any(.[]; .id == "mate-caps") | not)
      and ([.decisions_open[] | select(.owner == "mate-caps")] | length) == 2
      and ([.gates[] | select(.owner == "mate-caps")] | length) == 2
      and ([.unhealthy_endpoints[] | select(.id == "mate-caps/dead-one" or .id == "mate-caps/dead-two")] | length) == 2
      and ([.omitted[] | select(.surface | startswith("secondmate mate-caps "))] | length) == 0
  ' >/dev/null || fail "Bearings all flags did not lift their secondmate snapshot caps: $expanded"
  pass "Bearings surfaces per-home truncation and expands secondmate data with all flags"
}

test_pr_repository_cap_and_expansion() {
  local home fakebin json expanded
  home=$(make_home repo-caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 2 ] || fail "default PR repository cap was not enforced"
  printf '%s' "$json" | jq -e '
    [.omitted[] | select(.surface == "PR repositories showing 2 of 5" and .reveal == "--all-pr-repos")] | length == 1
  ' >/dev/null || fail "PR repository truncation was not recorded: $json"
  : > "$home/net.log"
  expanded=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --all-pr-repos --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 5 ] || fail "--all-pr-repos did not reveal every repository"
  printf '%s' "$expanded" | jq -e '.candidate_prs | length == 5' >/dev/null \
    || fail "expanded PR repository set did not enrich every repository: $expanded"
  pass "live PR enrichment caps repositories with counted expansion"
}

test_per_repository_pr_cap_is_disclosed() {
  local home fakebin json toon
  home=$(make_home pr-row-cap); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs --json)
  toon=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs)
  printf '%s' "$json" | jq -e '
    (.candidate_prs | length) == 2
    and (.prs | test("2 shown, at least 3 open; capped in 1 repo"))
    and ([.omitted[] | select(.surface == "candidate_prs showing 2 of at least 3; capped in 1 repo(s)" and .reveal == "raise FM_BEARINGS_PR_LIMIT")] | length) == 1
  ' >/dev/null || fail "per-repository PR truncation was not disclosed: $json"
  assert_contains "$toon" 'candidate_prs showing 2 of at least 3' "TOON did not preserve PR truncation disclosure"
  pass "per-repository open-PR caps are disclosed with an expansion knob"
}

install_failing_jq() {  # <fakebin> <model|toon>
  local fakebin=$1 phase=$2 real
  real=$(command -v jq)
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'def trunc'*) [ "$phase" = model ] && exit 9 ;;
  *'def q:'*) [ "$phase" = toon ] && exit 9 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/jq"
}

test_projection_and_toon_fail_closed() {
  local home fakebin out err rc
  home=$(make_home fail-closed); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  install_failing_jq "$fakebin" model
  err="$home/model.err"
  out=$(run "$home" "$fakebin" --json 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "projection failure exited successfully"
  [ -z "$out" ] || fail "projection failure emitted output"
  grep -F 'projection failed' "$err" >/dev/null || fail "projection failure lacked a diagnostic"
  install_failing_jq "$fakebin" toon
  err="$home/toon.err"
  out=$(run "$home" "$fakebin" 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "TOON rendering failure exited successfully"
  [ -z "$out" ] || fail "TOON rendering failure emitted output"
  grep -F 'TOON rendering failed' "$err" >/dev/null || fail "TOON failure lacked a diagnostic"
  pass "projection and TOON rendering failures exit nonzero with diagnostics"
}

# The Lavish-103 defect, end to end: a COMPLETED scout that raised a decision and
# then finished (done), whose report body reads like that decision, must surface as
# a report POINTER only - never in decisions_open. Report prose must never open or
# reopen a pending decision; only the keyed durable state does.
test_completed_scout_report_not_pending() {
  local home fakebin json
  home=$(make_home completed-scout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/lav-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/lav-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B; this needs a captain decision.\n' > "$home/data/lavish-103/report.md"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "lavish-103") | not)
      and (.reports | any(.[]; .id == "lavish-103"))
  ' >/dev/null || fail "completed scout must be a report pointer, never a pending decision: $json"
  pass "a completed scout with decision-like report prose is a pointer, not pending"
}

test_default_is_bounded_and_local_only
test_toon_json_parity
test_completed_scout_report_not_pending
test_open_decision_surfaces_end_to_end
test_decision_hold_captain_hold_is_stubbed
test_secondmate_status_decisions_preserve_captain_decision
test_gates_use_string_blocked_by
test_gates_distinguish_empty_normalized_blockers_from_absent
test_report_pointers_surface
test_underway_only_includes_working_in_flight_tasks
test_superseded_queued_item_dropped_by_default
test_include_prs_is_the_only_fetch_path
test_partial_github_failure_degrades
test_perl_fallback_bounds_github_call
test_section_caps_and_expansion_flags
test_secondmate_caps_reach_omitted_and_all_flags_expand
test_pr_repository_cap_and_expansion
test_per_repository_pr_cap_is_disclosed
test_projection_and_toon_fail_closed
test_chat_contract_four_sections
