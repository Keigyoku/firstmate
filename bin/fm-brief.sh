#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context.
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab]
#          [--role <review-crew|smoke-crew|marketing-crew>]
#          [--on-branch <branch> [--pr <n|url>] [--expect-head <sha>]]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --role <review-crew|smoke-crew|marketing-crew> inserts a one-line role-identity
#   load instruction into ship/scout briefs (matches fm-spawn --role). Not valid
#   with --secondmate.
#   --on-branch <branch> scaffolds an existing-branch ship Setup: fetch and check
#   out that branch with no create-branch instruction. Use for review-fix rounds,
#   PR-body corrections, and stacked slices that must land on a branch that
#   already has (or will keep) an existing PR. Default without this flag remains
#   create `fm/<task-id>`. Not valid with --scout or --secondmate.
#   --pr <n|url> (requires --on-branch) names the PR this work updates in place
#   so the crew and delivery gate associate pushes with that PR, not a new one.
#   --expect-head <sha> (requires --on-branch) requires HEAD equal or prefix-match
#   after checkout; mismatch stops with blocked: and the actual sha.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see AGENTS.md project management
# and task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                firstmate reviews, captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Ship briefs also carry the fleet Test-first contract (iron rules F1-F4, A1 RED
# evidence, typed exemptions, Closes #N PR-body guidance); scout briefs do not.
# That block is the one owner of the full TDD contract text; Review Crew and
# docs/crew-tdd-guard.md point at it rather than restating it.
# Ship and scout briefs (including --role variants) also carry the Architecture
# discipline standing order, pointing at the in-repo improve-codebase-architecture
# skill under .agents/skills/; secondmate charters do not.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
ROLE=
ROLE_SET=0
ON_BRANCH=
ON_BRANCH_SET=0
PR_REF=
PR_SET=0
EXPECT_HEAD=
EXPECT_HEAD_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      role) ROLE=$a; ROLE_SET=1 ;;
      on-branch) ON_BRANCH=$a; ON_BRANCH_SET=1 ;;
      pr) PR_REF=$a; PR_SET=1 ;;
      expect-head) EXPECT_HEAD=$a; EXPECT_HEAD_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --role) want_value=role ;;
    --role=*) ROLE=${a#--role=}; ROLE_SET=1 ;;
    --on-branch) want_value=on-branch ;;
    --on-branch=*) ON_BRANCH=${a#--on-branch=}; ON_BRANCH_SET=1 ;;
    --pr) want_value='pr' ;;
    --pr=*) PR_REF=${a#--pr=}; PR_SET=1 ;;
    --expect-head) want_value=expect-head ;;
    --expect-head=*) EXPECT_HEAD=${a#--expect-head=}; EXPECT_HEAD_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "$ROLE_SET" -eq 0 ] || [ -n "$ROLE" ] || { echo "error: --role requires a non-empty value" >&2; exit 1; }
case "$ROLE" in
  ''|review-crew|smoke-crew|marketing-crew) ;;
  *) echo "error: --role must be one of review-crew, smoke-crew, marketing-crew" >&2; exit 1 ;;
esac
[ "$ON_BRANCH_SET" -eq 0 ] || [ -n "$ON_BRANCH" ] || { echo "error: --on-branch requires a non-empty value" >&2; exit 1; }
[ "$PR_SET" -eq 0 ] || [ -n "$PR_REF" ] || { echo "error: --pr requires a non-empty value" >&2; exit 1; }
[ "$EXPECT_HEAD_SET" -eq 0 ] || [ -n "$EXPECT_HEAD" ] || { echo "error: --expect-head requires a non-empty value" >&2; exit 1; }
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$KIND" = secondmate ] && [ -n "$ROLE" ]; then
  echo "error: --role applies only to crewmate ship or scout briefs, not --secondmate" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

if [ -n "$ON_BRANCH" ] && [ "$KIND" != ship ]; then
  echo "error: --on-branch applies only to ship briefs, not --scout or --secondmate" >&2
  exit 1
fi

if [ -n "$PR_REF" ] && [ -z "$ON_BRANCH" ]; then
  echo "error: --pr requires --on-branch" >&2
  exit 1
fi

if [ -n "$EXPECT_HEAD" ] && [ -z "$ON_BRANCH" ]; then
  echo "error: --expect-head requires --on-branch" >&2
  exit 1
fi

MODE=
if [ "$KIND" = ship ]; then
  REPO=${POS[1]}
  read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF
  if [ "$MODE" = local-only ] && [ -n "$PR_REF" ]; then
    echo "error: --pr is not valid for local-only projects" >&2
    exit 1
  fi
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a secondmate: a persistent domain supervisor managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate (your supervisor) is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; when told to wait, stand by, hold, or park, append \`$PAUSED_VERB: {what you are waiting for}\` and then idle; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text; the '"$HERDR_LAB_HELPER"' and '"$ID"' break-outs interpolate the concrete helper path and task id at scaffold time, while the $(...) and $HERDR_LAB_SESSION snippets must reach the reading agent verbatim to expand at crew runtime.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'Invoke the helper by the literal path shown in every command below; never assign it to a shell variable and call `"$var"`. The crew command guard refuses any command whose command word is a variable, so a variable-invoked helper (even a `--help` probe) is denied, while the literal helper path is allowed.' \
'' \
'1. Generate the session name with `HERDR_LAB_SESSION=$('"$HERDR_LAB_HELPER"' name '"$ID"')`.' \
'   Install `trap "'"$HERDR_LAB_HELPER"' teardown $HERDR_LAB_SESSION" EXIT` before provisioning, then provision only with `'"$HERDR_LAB_HELPER"' provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `'"$HERDR_LAB_HELPER"' run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `'"$HERDR_LAB_HELPER"' teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `'"$HERDR_LAB_HELPER"' stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
HERDR_SECTION=$(cat <<'EOF'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
)
fi

ROLE_SECTION=
if [ -n "$ROLE" ]; then
  ROLE_SKILL_ABS="$FM_ROOT/.agents/skills/$ROLE/SKILL.md"
  ROLE_SECTION=$(cat <<EOF
# Role identity
Load your role identity: \`/$ROLE\` (or read \`$ROLE_SKILL_ABS\` in full).
EOF
)
fi

# Architecture discipline (fleet standing order): every ship/scout crew brief.
# Points at the in-repo vendored skill via FM_ROOT (same path pattern as role
# skills), not a captain user-level ~/.claude/skills path.
# shellcheck disable=SC2016 # intentional: brief prose for the crewmate; only ARCH_SKILL_DIR expands.
ARCH_SKILL_DIR="$FM_ROOT/.agents/skills/improve-codebase-architecture"
ARCH_SECTION=$(cat <<EOF
# Architecture discipline (fleet standing order)

Live by the in-repo \`improve-codebase-architecture\` skill while scouting, reviewing, and implementing.

- On the \`claude\` harness: invoke \`/improve-codebase-architecture\` (or read
  \`$ARCH_SKILL_DIR/SKILL.md\`,
  \`$ARCH_SKILL_DIR/LANGUAGE.md\`,
  \`$ARCH_SKILL_DIR/INTERFACE-DESIGN.md\`, and
  \`$ARCH_SKILL_DIR/DEEPENING.md\` in full).
- On any other harness: read \`$ARCH_SKILL_DIR/SKILL.md\` and its
  siblings \`$ARCH_SKILL_DIR/LANGUAGE.md\`,
  \`$ARCH_SKILL_DIR/INTERFACE-DESIGN.md\`, and
  \`$ARCH_SKILL_DIR/DEEPENING.md\` via that absolute path.
- Never copy or symlink skills into the worktree; read them in place.

Use its vocabulary exactly - module, interface, implementation, depth, seam, adapter, leverage, locality; not "component", "service", "boundary".
EOF
)

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$ROLE_SECTION

$ARCH_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. When told to wait, stand by, hold, or park, append
   \`$PAUSED_VERB: {what you are waiting for}\` and then idle - do not stay silent without that line.
   Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.

# Fleet TDD contract (one owner of the full text).
# Source: vellum-tdd-adoption-scout report sec 6.1-6.2 + captain locks A1 (2026-07-20).
# Scout briefs stay report-only and never receive this block.
# Quoted heredoc keeps apostrophes safe outside the ship-mode $(cat <<EOF) bodies.
# shellcheck disable=SC2016 # intentional: this is brief prose for the crewmate, not shell to expand here.
TDD_DOD=$(cat <<'EOF'
# Test-first (fleet standing order)

This fleet develops **red then green**.
Gates verify end state; you still own authoring order.

## How-to (canonical)

The iron rules below are the **contract**. The captain's `tdd` skill is the
canonical **how-to** (red-green-refactor, test design, mocking boundaries).

- On the `claude` harness: invoke `/tdd` at task start (user-level skill).
- On any other harness: read `__HOME__/.claude/skills/tdd/SKILL.md` and its
  siblings `__HOME__/.claude/skills/tdd/tests.md` and
  `__HOME__/.claude/skills/tdd/mocking.md` via that absolute path.
- Never copy or symlink skills into the worktree; read them in place.

## Iron rules (fleet)

F1. NO BEHAVIOR CHANGE WITHOUT A FAILING TEST FIRST
    (or a typed exemption from the scope table).

F2. RED IS NOT OPTIONAL THEATRE
    You must run the test, see non-zero, and record why it failed
    (missing behavior - not compile typo you then fixed without re-RED).

F3. VERTICAL SLICES ONLY
    One behavior -> one RED -> one GREEN. No bulk-test-then-bulk-impl.

F4. TESTS ASSERT OBSERVABLE BEHAVIOR
    Public API / CLI / HTTP / UI contract. No assert-on-mock-call-counts
    as the sole oracle. Mock system boundaries only.

## Required for behavior work (features, fixes, behavior-changing refactors)

1. **RED:** Write the smallest failing test (or extend an existing suite) that would catch the bug/missed behavior.
2. **Run it** with the project normal runner (Rust: `cargo test -p <crate> <filter>` in distrobox; JS: `node --test` / `vitest run`; bash: `tests/*.test.sh`).
3. **Record RED evidence** (A1: squash merges make history independent; the artifact is the durable proof): exit non-zero + the assertion/message that proves the *behavior* is missing (not a typo you fixed without re-running). Put it in the PR body or `.no-mistakes/evidence/` when used.
4. **GREEN:** Minimal production change to pass. Re-run the same test + relevant package suite.
5. **Do not** claim complete on green-without-RED, or on local green without the delivery mode real ship signal (PR URL / ready-in-branch).

## Vertical slices

One behavior per RED->GREEN cycle.
Do **not** write a bulk suite then implement everything.

## Typed exemptions (must state in PR/commit body)

- docs/comment-only; pure formatting with no behavior risk
- pure renames/moves with compiler as oracle (prefer `cargo check` / typecheck evidence)
- pure refactor with characterization tests that stay green (no intentional behavior change)
- generated/vendored code you did not author
- exploratory spike **thrown away** before real implementation (spike commits must not ship)

## Evidence shape (PR body or `.no-mistakes/evidence/` when used)

### RED
- command:
- exit code:
- relevant failure excerpt (<=30 lines):

### GREEN
- command:
- exit code:
- notes:

If RED evidence is missing for a non-exempt behavior PR, Review Crew REDs the round.

## PR body

When the task is issue-driven (a linked GitHub issue or an explicit issue number in the brief), include a `Closes #N` line in the PR body so merge closes the issue.
EOF
)
# Expand the absolute captain-skill path (the heredoc above is single-quoted).
TDD_DOD=${TDD_DOD//__HOME__/$HOME}

NEED_DOCTOR=0
case "$MODE" in
  direct-PR)
    if [ -n "$ON_BRANCH" ]; then
      RULE1="1. Never push to the default branch (push only \`$ON_BRANCH\`). Never merge a PR. Never open a new PR; push updates the existing PR on that branch in place."
      DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you push the existing branch yourself, without the no-mistakes pipeline.
The task is complete only when committed on \`$ON_BRANCH\`.
When it is implemented and committed, push \`$ON_BRANCH\` (updating the existing PR in place; do not open a new PR) with \`gh-axi\` as needed, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The captain reviews and merges the PR; firstmate relays it.

$TDD_DOD
EOF
)
    else
      RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
      DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The captain reviews and merges the PR; firstmate relays it.

$TDD_DOD
EOF
)
    fi
    ;;
  local-only)
    if [ -n "$ON_BRANCH" ]; then
      RULE1="1. Never push to any remote and never open a PR. Work only on \`$ON_BRANCH\`; firstmate handles the merge into local \`main\`."
      DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on branch \`$ON_BRANCH\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep the branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch $ON_BRANCH\` to the status file and stop.
Firstmate then reviews your branch diff, the captain approves, and firstmate merges it into local \`main\`.

$TDD_DOD
EOF
)
    else
      RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
      DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
Firstmate then reviews your branch diff, the captain approves, and firstmate merges it into local \`main\`.

$TDD_DOD
EOF
)
    fi
    ;;
  *)  # no-mistakes (default)
    NEED_DOCTOR=1
    if [ -n "$ON_BRANCH" ]; then
      RULE1="1. Never push to the default branch. Never merge a PR. Never open a new PR; push only \`$ON_BRANCH\` so the existing PR updates in place."
      DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on \`$ON_BRANCH\`.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate on that same branch.
The pipeline must update the existing PR for \`$ON_BRANCH\`, not open a replacement PR on a task-named branch.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.

$TDD_DOD
EOF
)
    else
      RULE1='1. Never push to the default branch. Never merge a PR.'
      DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.

$TDD_DOD
EOF
)
    fi
    ;;
esac

# Compose Setup intro + numbered first actions. Existing-branch mode must never
# emit a create-branch instruction (git checkout -b / "create your branch").
SETUP_STEP=1
if [ -n "$ON_BRANCH" ]; then
  ON_BRANCH_Q=$(shell_quote "$ON_BRANCH")
  ON_REMOTE_REF_Q=$(shell_quote "origin/$ON_BRANCH")
  ON_REMOTE_HEAD_REF_Q=$(shell_quote "refs/heads/$ON_BRANCH")
  SETUP_INTRO="You are in a disposable git worktree of $REPO. This task continues existing branch \`$ON_BRANCH\`; do not create a new branch."
  if [ "$MODE" = local-only ]; then
    SETUP_STEPS="${SETUP_STEP}. First action: check out the existing local branch \`$ON_BRANCH\` (do NOT create a new branch):
   Run \`git switch -- $ON_BRANCH_Q\`."
  else
    SETUP_STEPS="${SETUP_STEP}. First action: fetch and check out the existing branch \`$ON_BRANCH\` (do NOT create a new branch):
   Run \`git fetch origin $ON_BRANCH_Q && git checkout -B $ON_BRANCH_Q $ON_REMOTE_REF_Q\`."
  fi
  SETUP_STEPS="$SETUP_STEPS
   If checkout refuses because another linked worktree already has \`$ON_BRANCH\` checked out, use \`git worktree list --porcelain\` to identify its path, append \`blocked: branch $ON_BRANCH_Q is checked out in another worktree at <path>; firstmate must free it\`, and stop.
   Do not use a detached HEAD, force-steal the branch, or create a differently named fallback branch. Delivery associates the PR with the local branch name, so the local name must remain \`$ON_BRANCH\`.
   Immediately after checkout, \`test \"\$(git rev-parse --abbrev-ref HEAD)\" = $ON_BRANCH_Q\` must succeed. If it does not, append \`blocked: wrong branch, expected $ON_BRANCH_Q got <actual>\` and stop."
  SETUP_STEP=$((SETUP_STEP + 1))
  if [ -n "$EXPECT_HEAD" ]; then
    EXPECT_HEAD_Q=$(shell_quote "$EXPECT_HEAD")
    SETUP_STEPS="$SETUP_STEPS
${SETUP_STEP}. Assert the expected head: \`case \"\$(git rev-parse HEAD)\" in $EXPECT_HEAD_Q*) true ;; *) false ;; esac\` must succeed. If it does not, append \`blocked: unexpected HEAD, expected $EXPECT_HEAD_Q got <actual-sha>\` and stop. Do not reset the branch to force a match - report the actual sha and stop."
    SETUP_STEP=$((SETUP_STEP + 1))
  fi
  if [ -n "$PR_REF" ]; then
    case "$PR_REF" in
      *://*) PR_DISPLAY=$PR_REF ;;
      ''|*[!0-9]*) PR_DISPLAY=$PR_REF ;;
      *) PR_DISPLAY="PR #$PR_REF" ;;
    esac
    PR_DISPLAY_Q=$(shell_quote "$PR_DISPLAY")
    SETUP_STEPS="$SETUP_STEPS
${SETUP_STEP}. PR association (authoritative): this work updates $PR_DISPLAY. Pushing \`$ON_BRANCH\` updates that PR in place. Do not open a new PR. If the delivery gate claims no PR exists for this branch, append \`blocked: gate claims no PR for $ON_BRANCH_Q (expected $PR_DISPLAY_Q)\` and stop - do not open a replacement PR."
    SETUP_STEP=$((SETUP_STEP + 1))
  fi
  if [ "$MODE" != local-only ]; then
    SETUP_STEPS="$SETUP_STEPS
${SETUP_STEP}. Branch custody: Never force-push. After work starts, never reset (hard or mixed) this shared branch to discard history. If a push is refused because a stale pipeline holds custody, abort that stale run by id from the PR body (\`no-mistakes axi abort --run <id>\`), then push again. After every successful push, confirm the remote tip with \`git ls-remote origin $ON_REMOTE_HEAD_REF_Q\` and ensure it matches your local HEAD. If you still cannot push without force, append \`needs-decision:\` or \`blocked:\` and stop."
    SETUP_STEP=$((SETUP_STEP + 1))
    case "$MODE" in
      direct-PR) DELIVERY_ACTION="pushing or updating the PR" ;;
      *) DELIVERY_ACTION="invoking /no-mistakes" ;;
    esac
    SETUP_STEPS="$SETUP_STEPS
${SETUP_STEP}. Delivery pre-flight: immediately before $DELIVERY_ACTION, \`test \"\$(git rev-parse --abbrev-ref HEAD)\" = $ON_BRANCH_Q\` must succeed. If it does not, append \`blocked: wrong local branch for delivery gate, expected $ON_BRANCH_Q got <actual>\` and stop - do not proceed."
    SETUP_STEP=$((SETUP_STEP + 1))
  fi
else
  SETUP_INTRO="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch."
  SETUP_STEPS="${SETUP_STEP}. First action: create your branch: \`git checkout -b fm/$ID\`"
  SETUP_STEP=$((SETUP_STEP + 1))
fi
if [ "$NEED_DOCTOR" -eq 1 ]; then
  SETUP_STEPS="$SETUP_STEPS
${SETUP_STEP}. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
fi

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$ROLE_SECTION

$ARCH_SECTION

$HERDR_SECTION

# Setup
$SETUP_INTRO

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

$SETUP_STEPS

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. When told to wait, stand by, hold, or park, append
   \`$PAUSED_VERB: {what you are waiting for}\` and then idle - do not stay silent without that line.
   Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
if [ -n "$ON_BRANCH" ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE, on-branch=$ON_BRANCH; replace {TASK})"
else
  echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
fi
