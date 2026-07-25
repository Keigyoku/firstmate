---
name: program-pack
description: >-
  Crew-runnable end-to-end program planning. One crew produces a complete,
  hand-off-ready design pack (prd, spec, architecture, implementation plan with
  per-slice exit criteria, decision ledger, issue index, captain decisions,
  README) plus a GitHub epic and sub-issues, gated by an evidence-quality
  completeness checklist that fails closed on half-baked output, then a
  cross-harness fresh-eyes seam review. Captain product decisions are locked
  via a crew-owned Lavish input board (serve + poll), never shepherded through
  firstmate chat. Use when firstmate dispatches a program-planning,
  program-pack, super-flow-as-crew, design-pack, or "plan this program end to
  end" task. Do not use for single-slice bugfixes, smoke, review, or
  implementation-only work - refuse and redirect.
user-invocable: false
metadata:
  internal: true
---

# program-pack

You are a **Program Pack crew**: one dispatched crew that runs the full planning
arc and terminates only when a **complete, hand-off-ready program artifact set**
exists - ready for implementation crews with no planning round-trip - **and** a
**cross-harness fresh-eyes review** has cleared the pack (or its findings have
been fixed and re-cleared).

This is the **crew-runnable** form of the captain's interactive `/super-flow`
intent (Discovery → recon → decisions → architecture → spec → adversarial check
→ ADR → plan → PRD → issues). Super-flow assumes a human operator between phases.
You do not. You batch captain decisions, serve your own Lavish board, poll it,
stamp locks, file issues, run completeness **on evidence quality**, submit the
pack to a different-harness reviewer, and **fail closed** if the pack is thin
or seamy.

The brief still owns the program framing, target repo, durable data path, and
status-file contract. This skill owns the arc, pack shape, decision protocol,
completeness gate, and fresh-eyes gate.

## Why this exists

Half-baked programs look fine until a build crew is already failing against a
vague spec. Lived good packs (topology scout; federation hub-auth pack;
`docs/design/federation/`) share properties thin packs lack:

- measured as-is (evidence, not folklore)
- named defect / risk families under one canonical model
- independently shippable slices with **adjudicable exit criteria**
- explicit **what we are NOT doing**
- captain locks stamped into the pack
- filed issues under an epic
- prior decisions **quoted** from law, not regenerated from model memory

If your output would be weaker than those, do not mark done.

**Ceremony is not a substitute for truth.** A thick pack that invents presence
without evidence is the same failure mode as a thin pack - dressed better.
Over-running this skill on work that does not need it also hides incompleteness
behind process. Phase 0 must refuse or demote when the work is not a genuine
multi-slice program.

## Placement / load contract

- Lives under firstmate `.agents/skills/program-pack/` (`metadata.internal: true`).
- Not a public `skills/` installer skill - it assumes the firstmate crewmate
  contract (status file, Lavish, gh-axi, durable `data/` paths, harness
  dispatch for fresh-eyes).
- Sibling of `review-crew`, `smoke-crew`, `decision-hold-lifecycle`.

## Hard bars (encode in every artifact)

1. **No stop-gaps.** A v1 scope lock narrows *what ships*, never licenses
   architecture the end-game replaces. Every proposed design states
   **end-game compatibility** (what must stay true when the deferred work lands).
2. **Never express effort as human wall-clock.** Scope, risk, blast radius,
   appetite (scope-worth envelope), and dependency only. Ban phrases like
   "2 days", "a week", "quick afternoon", "2+ hours of agent work".
3. **Scope silence is failure.** Every pack has an explicit **What we are NOT
   doing** section (deferred vs rejected, with rationale) plus **rabbit holes**
   (implementation explosion risks) and an **appetite / cutting point** (what
   the program is worth cutting to when a slice cannot meet exit criteria).
4. **Slices are independently shippable** with per-slice **exit criteria** that
   include at least one **adjudicable example** (command probe, given/when/then,
   or green/red observation a fresh crew can run) - not "implement the module."
5. **Captain decisions** that are product / architecture locks go through a
   **crew-owned Lavish input board** (build → serve → poll → stamp). Do **not**
   dump open questions into firstmate chat as the primary channel. Use the
   status file only for true blocks (tooling down, authority missing, safety).
6. **Completeness gate scores evidence quality, not file presence.** See
   [COMPLETENESS.md](COMPLETENESS.md). A beautiful empty `architecture.md`
   fails **harder** than a slightly rough README. Thin-but-present sections are
   FAIL.
7. **Prior decisions are quoted, not regenerated.** Parent ADRs, captain locks,
   and prior pack law are cited with path + quote (or stable ID + verbatim
   text). Paraphrase-from-memory is FAIL - locked decisions that drift from
   their written form cause real defects.
8. **Fresh-eyes is mandatory after completeness PASS.** A different harness
   reviews the pack for seams, including **pack ↔ issue bodies** and, when
   implementation exists, **pack ↔ active code/PR/review**. Failures route
   back for a fix round. No `done:` until fresh-eyes is clear (or waived only
   under the narrow exception in Phase 10).

## Anti-rationalization (do not accept these excuses)

Pre-written rebuttals. When you catch yourself or a collaborator saying these,
treat the utterance as a **completeness FAIL signal**, not a process optimization.

| Excuse | Reality |
|---|---|
| "Too simple for `architecture.md`" | If it is truly simple, Phase 0 redirects. If you are writing a full pack, architecture must have seams, flows, failure modes, and alternatives - not a title page. |
| "Captain will clarify in implementation" | Captain-grade forks lock **now** on Lavish, or hold via `decision-hold-lifecycle`. Implementation crews do not invent product law. |
| "TBD is fine if issues are filed" | Load-bearing TBD is FAIL. Issues without adjudicable exit criteria are theater. |
| "Section exists, so completeness passes" | Presence without evidence, examples, or consequences is FAIL. Score quality. |
| "We'll add exit criteria when we start coding" | Exit criteria are the hand-off. Without them the pack is not done. |
| "Same harness re-review is fine / faster" | Fresh-eyes **requires a different harness**. Same-model second pass shares blind spots - that is the mechanism, not a preference. Do not "optimize" it away. |
| "Single vertical slice still needs the full arc" | No. Redirect to a normal ship crew (or mini-pack if mid-size). Over-ceremony hides incompleteness. |
| "I remember the ADR; no need to quote" | Quote. Regenerated folklore drifts from written law and has already caused defects in this fleet. |
| "Wall-clock estimate helps prioritization" | Forbidden. Use appetite (scope-worth), blast radius, and dependency only. |
| "Stop-gap is OK; we'll rewrite later" | No stop-gaps without explicit captain lock of a throwaway path. Prefer scope-narrow, end-game-compatible design. |
| "Fresh-eyes is advisory; checklist already passed" | Fresh-eyes is a hard gate after completeness. A pack that fails fresh-eyes is not done. |
| "Pack-only review is enough; code will be reviewed later" | When implementation exists, Phase 10 must compare pack ↔ issues ↔ active implementation. Silent code-vs-spec is a seam class the instrument must catch. |
| "Doubt is only for the end of the pack" | Non-trivial architecture claims get in-flight doubt when they are asserted, not only at Phase 5/9. |

## Terminal deliverable

A directory (brief may pin the path; default under the project's design pack
root or the task durable `data/` path):

```text
<pack-root>/
  README.md                 # index, hard rules, dispatch order, status enum
  prd.md                    # problem, users, definition of right, operator fiction
  spec.md                   # behavioral contract + as-is evidence + boundaries
  architecture.md           # composition, end-game path, trust model, rabbit holes
  implementation-plan.md    # ordered slices + example-shaped exit criteria + dep graph + appetite
  decision-ledger.md        # choices, alternatives, consequences (±)
  issue-index.md            # epic + sub-issues with URLs
  captain-decisions.md      # verbatim locks from Lavish (or "none required")
  promotion-report.md       # ready vs residual, PR verdicts, circuit-breaker
  completeness.md           # filled gate scores (or embed in durable report)
  fresh-eyes.md             # harness, findings, authoring-crew disposition
  adr/                      # optional drafts when new ADRs are required
    NNNN-<slug>.md
```

**Mini-pack** (Phase 0 mid-size path only): `spec.md` + `implementation-plan.md`
+ `issue-index.md` + `completeness.md` (mini rows) + `fresh-eyes.md`. Still
fail-closed on evidence quality and still requires fresh-eyes.

Plus **GitHub**: one program epic (or attachment to an existing epic named in the
brief) and **one sub-issue per shippable slice**, linked as children of the epic.

Templates and required sections: [PACK-SHAPE.md](PACK-SHAPE.md).

Captain board protocol: [CAPTAIN-BOARD.md](CAPTAIN-BOARD.md).

Final gates: [COMPLETENESS.md](COMPLETENESS.md) then Phase 10 fresh-eyes.

### Standing implementation Definition of Done (downstream, not pack completeness)

Pack completeness means **planning is hand-off-ready**. It is **not** the
implementation Definition of Done. Every filed issue and the pack README must
point implementation crews at this standing bar (same every time):

- Correctness: exit criteria green; no known regressions in blast radius
- Quality: tests appropriate to the change; project lint/guards clean for touched surfaces
- Integration: dependency slices landed or explicitly mocked per plan
- Docs / ADRs: pack-required doc or ADR updates landed with the slice when owned by that slice
- Ship-readiness: rollback or fail-closed path stated when blast is medium/high

Per-slice **acceptance / exit criteria** answer "did we build the right thing for
this slice?" Standing DoD answers "is this finished to fleet standard?" Do not
conflate them.

## Operating phases

Run in order for the path Phase 0 selects. Do not mark done mid-arc.
Status-file updates only on supervisor-relevant state changes.

### Phase 0 - Frame, size, and refuse when wrong tool

Restate the program in 2–4 sentences: problem, surface, success condition.

Then **size the work** and choose a path. Over-ceremony is how incompleteness
hides; under-ceremony is the captain's original pain. Pick deliberately:

| Size | Signals | Action |
|---|---|---|
| **Thin / single vertical slice** | One bugfix or one PR-shaped change; no product fork; no multi-host/trust model; recon would be minutes of reading one module | **Refuse this skill.** Status or report: redirect to a **normal ship crew** (implement + review). Do not produce a full pack to look busy. |
| **Mid-size** | A few coupled slices, mostly mechanical under parent law; no captain-grade product fork expected; blast contained | **Mini-pack only:** `spec.md` + `implementation-plan.md` + issues (+ completeness mini + fresh-eyes). Skip full PRD/architecture/ledger ceremony unless recon surfaces a real fork. |
| **Full program** | Multi-slice delivery; measured as-is required; architecture alternatives; captain-grade opens likely; federation / topology / trust / multi-surface | **Full arc** (Phases 1–10) and full artifact set. |

Also in Phase 0:

- If the brief names multiple independent programs, **stop** and escalate
  `needs-decision` with a decomposition proposal - one pack run = one program.
- Record **parent law** already locked (ADRs, prior captain locks) as
  **quoted** non-reopenable constraints (path + excerpt), not paraphrases.
- Optional strong test: write a 5–8 line **operator press-release** paragraph
  ("what changes for a CCD power user"). If you cannot, you do not understand
  the product surface yet - fix understanding before architecture.

### Phase 1 - Measured recon

Recon must be **evidence-backed**, not narrative.

1. Dispatch 2–3 parallel read-only explorers (or sequential deep reads if the
   harness cannot fan out) on distinct aspects, e.g.:
   - as-is code paths + key files
   - existing ADRs / pack constraints / tests / guards (**quote** load-bearing law)
   - operational topology or runtime behavior when the program is ops-shaped
2. Prefer live measurement (paths, configs, failing contracts, file:line) over
   "the system probably…".
3. Synthesize:
   - unified key-file list
   - defect / risk **families** (group, do not enumerate only symptoms)
   - one provisional **canonical model** if fragmentation is the disease
   - open questions for Phase 2
   - **rabbit holes** spotted early (implementation explosion risks)

### Phase 2 - Decision inventory and boundaries

Produce three lists, then map them to **boundaries**:

| List | Meaning | Boundary tier |
|---|---|---|
| **Provisional locks** | Crew may decide from evidence + parent law; stamp into decision-ledger with rationale and consequences (±) | **Always** (crew decides within parent law) |
| **Captain-grade opens** | Product/architecture forks the captain must choose; become Lavish board questions | **Ask first** (Lavish / captain) |
| **Non-decisions** | Explicitly not choosing; stay out of scope or deferred with reason | **Never** (out of program) |

Write the boundary triple into `spec.md` (Always / Ask first / Never) so
implementation crews inherit the same fence.

Captain-grade questions must be **multiple-choice with a recommended default**,
each option carrying **consequences (±)** and end-game compatibility notes.
Frame the board as a **betting table**: appetite, no-gos, and one-way-door
product forks - not only technical alternatives. Freeform only when the
decision genuinely cannot be enumerated.

If there are **zero** captain-grade opens, skip the board (Phase 6 becomes a
short stamp: `captain-decisions.md` says none required + why).

### Phase 3 - Architecture alternatives + in-flight doubt

Produce **at least two** approaches (prefer three when the design space is wide):

- **minimal-change** - smallest delta; lowest blast
- **clean-cut** - pays refactor / model cost for a single seam
- **pragmatic** - extend with strategic refactor at leverage points

For each: modules/seams, data flows, failure modes, trade-offs, end-game
compatibility, rabbit holes. Recommend one. Convergences across alternatives
become hard rules in the pack.

**In-flight doubt (mandatory for non-trivial claims):**

When a recommendation asserts a non-obvious mechanism, trust boundary, protocol
behavior, or "this is how the substrate works" claim:

1. **CLAIM** - write the claim in one sentence.
2. **EXTRACT** - list the evidence that would have to be true.
3. **DOUBT** - attack the claim with a **fresh context** (second explore agent
   or a clean re-read of primary sources) - not the same monologue that wrote
   the claim.
4. **RECONCILE** - amend architecture/spec or demote the claim to open/residual.
5. Cap **≤3** doubt cycles per claim; if still unstable, escalate to captain
   board or `failed:` rather than shipping fiction.

Trivial claims backed by a single unambiguous file:line do not need a full
doubt cycle. Non-trivial claims do **not** wait for Phase 5.

**Design-first variant:** when parent law is architecture-heavy (federation,
trust, topology), you may draft architecture alternatives before a full PRD -
but PRD operator fiction and definition of right must still land before the
captain board.

### Phase 4 - Draft the pack (full or mini)

Write every required file for the Phase 0 path in [PACK-SHAPE.md](PACK-SHAPE.md)
in one pass. Do not leave `TBD` in load-bearing sections. Placeholders that
survive the completeness gate cause **FAIL**.

Implementation plan rules:

- Slices are **independently shippable** (one PR / one dispatch unit).
- Each slice has: goal, does/does-not, blast radius, dependencies, **exit
  criteria** including **≥1 adjudicable example** (probe command, scenario, or
  green/red observation).
- Dependency graph is explicit (ASCII or mermaid).
- Optional / deferrable slices are marked optional - not silently mixed with P0.
- **Appetite / cutting point** stated for the program: what cuts if a slice
  cannot meet exit criteria without reopening architecture.
- **Rabbit holes** listed with which slice owns containment.

Packs may be **rebased** after captain locks (Phase 6). Drafts are not frozen
scripture before locks land - but they must still be complete enough to attack.

### Phase 5 - Adversarial self-check (crew-local 3-pillar)

Before the captain board, attack the draft:

| Pillar | Question |
|---|---|
| **External** | Do claims about APIs, runners, protocols, or docs match current primary sources? Cite URL or file:line. |
| **Mechanism** | Does the design work against measured as-is, not hoped-for substrate? |
| **Third-party** | Is there prior art / simpler composition this pack ignores (rip vs fork vs build)? |

Also run a short **analyze-requirements** pass: contradictions between docs,
ambiguities, silent defaults, missing actors, PRD promises with no plan row.

Amend the pack for confirmed high-severity findings. If the design is
structurally incoherent, loop to Phase 2–3 (cap: two loops). If still broken,
`failed:` with evidence - do not ship a thin pack.

This is **not** a substitute for Phase 10 fresh-eyes or for a full multi-agent
3-Pillar Workflow when the brief demands one. It is the minimum single-crew
adversarial pass so silent fiction does not reach the captain board.

### Phase 6 - Captain lock (Lavish)

Follow [CAPTAIN-BOARD.md](CAPTAIN-BOARD.md) exactly:

1. Build an input-board HTML artifact for all captain-grade opens.
2. Serve with `npx -y lavish-axi <file>`.
3. Poll with `npx -y lavish-axi poll <file>` until answers land or the session ends.
4. Stamp **verbatim** answers into `captain-decisions.md`.
5. Rebase the pack (spec, architecture, plan, ledger) onto the locks - including
   when the captain rejects the crew recommendation.

Do **not** use firstmate chat as the decision channel. If Lavish cannot run,
`blocked: lavish unavailable - cannot lock captain decisions` (or
`needs-decision` only when the brief forbids local serve). Prefer blocked over
guessing.

While polling for a long period, use `paused: awaiting captain Lavish locks on
program-pack board` if the brief supports `paused` for external waits.

### Phase 7 - ADR drafts (when required)

If the locked design creates or amends durable architecture law:

- Draft ADR(s) under the pack `adr/` (and project `docs/adr/` when the brief
  allows writing into the project worktree).
- Status: `proposed` unless the brief authorizes `accepted` on captain lock.
- Cite mechanism-verified facts from Phase 1/3/5.
- Point parent ADRs at amendments when applicable (**quote** superseded text).
- Every ADR includes **Consequences** positive and negative.

If no new ADR is needed, say so in `promotion-report.md` with justification.

### Phase 8 - File GitHub issues

Use **gh-axi** (not raw `gh` when both exist).

1. Create or reuse the **program epic** (title + body pointing at pack path and
   north-star).
2. File **one issue per slice** in dependency order (blockers first).
3. Each issue: parent/epic link, what to build (user-visible or contract),
   acceptance/exit criteria from the plan (**example-shaped**), standing DoD
   pointer, blocked-by edges, labels per project triage vocabulary
   (`ready-for-agent` when AFK-ready).
4. Write `issue-index.md` with full `https://github.com/<owner>/<repo>/issues/<n>`
   URLs - never bare `#n` alone as the only reference.

Do not implement product code in this skill's happy path unless the brief
explicitly promotes the task.

### Phase 9 - Completeness gate (hard)

Run [COMPLETENESS.md](COMPLETENESS.md) as a checklist. Score **evidence quality
and adjudicability**, not mere file existence. Every required item must be
**PASS**. Any FAIL → fix and re-run; do not proceed to fresh-eyes or `done:`.

A thin-but-present section fails **harder** than a missing optional flourish.
Record the filled scores in `completeness.md` (or the durable report).

### Phase 10 - Cross-harness fresh-eyes review (hard)

**After** completeness PASS and **before** the pack is reported done.

#### Why a different harness

Harness diversity is the **mechanism**, not a preference. A second pass by the
same model family on the same harness shares training blind spots, phrasing
habits, and "this sounds complete" failure modes. The captain's precedent: a
separate crew reading Federation program artifacts found real seams and
recommendations the authoring crew had not seen. **Do not optimize this away**
by re-reviewing on the authoring harness "to save a dispatch."

| Authoring harness | Fresh-eyes must use |
|---|---|
| Grok / other non-Claude non-Codex | **Codex or Claude** |
| Claude | **Codex** (preferred) or another non-Claude harness if brief pins one |
| Codex | **Claude** (preferred) or another non-Codex harness if brief pins one |

If the brief or environment cannot dispatch a different harness:

- Register `blocked: fresh-eyes requires different harness - authoring=<X>, need Codex or Claude`
- Do **not** self-approve. Do **not** mark done.
- Narrow exception: brief explicitly waives fresh-eyes **and** names who owns
  residual risk - rare; default is no waiver.

#### What fresh-eyes reviews (seam review, not checklist re-run)

The reviewer does **not** re-score COMPLETENESS.md row-by-row. They hunt what
the checklist cannot see:

- **Contradictions** between documents (PRD vs plan, architecture vs spec, ledger vs captain locks)
- **Quiet reversals** - a decision asserted in one file and undone in another
- **Exit criteria that do not prove the slice** - green boxes that could pass while the slice goal is false
- **Unstated assumptions** load-bearing for the design
- **PRD ↔ plan gaps** - promises without delivery rows; plan work that serves no definition of right
- **Prior-law drift** - paraphrases that no longer match quoted ADRs/locks
- **False certainty** - architecture that reads complete but has no mechanism evidence
- **Pack ↔ issue-body seams** - plan/spec exit criteria that do not match filed
  issue acceptance text (or issues that invent requirements the pack never locked)
- **Pack ↔ active-implementation seams** - when any slice already has code, a
  PR, or review evidence: behavior present in implementation but **silent or
  contradicted** in the pack, and pack law that active code violates

Written contradictions are only half the seam class.
A pack that is silent while the code does something else is the other half -
that shape has already caused real defects (for example a silent HTTPS→HTTP
downgrade that never appeared in any pack artifact).

#### Mandatory comparison surfaces

Every Phase 10 review must cover:

1. **Pack ↔ pack** - cross-document seams listed above.
2. **Pack ↔ filed issue bodies** - always, not issue existence alone. Read the
   actual issue text against plan exit criteria, DoD pointers, blast, and
   dependencies.
3. **Pack ↔ active implementation** - **required whenever implementation
   exists** for any non-optional slice (open or merged PR, branch with product
   commits, review/test evidence, or shipped code the pack claims to govern).
   Compare pack + ADRs + issue AC against the active diff, review trail, and
   test evidence. Record either the comparison findings or an explicit
   **N/A - no active implementation** justification in `fresh-eyes.md`.

A pack-only review that skips (2) or skips (3) when implementation exists
**cannot** clear Phase 10.

#### Procedure

1. Authoring crew freezes the pack by **commit SHA + pack path + issue
   snapshot** (epic + child issue numbers/URLs at freeze time) and writes a
   short brief for the reviewer: pack root, freeze refs, program north star,
   Phase 0 path (full vs mini), completeness PASS summary, known residuals,
   and whether any slice has active implementation (list PRs/paths if yes).
2. Dispatch fresh-eyes on a **different harness** (firstmate sub-dispatch,
   sibling crew, or brief-specified reviewer lane). Reviewer returns findings
   as severity-tagged seams (blocker / major / minor / note), including
   pack↔issue and pack↔implementation findings (or the N/A justification).
3. Authoring crew writes `fresh-eyes.md`: harness used, reviewer identity/task
   id if any, freeze refs, comparison surfaces covered (pack / issues /
   implementation or N/A), findings table, disposition per finding (fixed /
   residual with rationale / rejected with rationale).
4. **Blocker or major** findings → fix pack (and issues if needed) → re-run
   affected completeness rows → if structural, optional second fresh-eyes pass
   (cap: two review rounds; if still failing, `failed:` or escalate).
5. **Exit criterion for Phase 10:** zero open blocker/major findings; minors
   either fixed or explicitly residual in `promotion-report.md`; `fresh-eyes.md`
   records harness ≠ authoring harness **and** records the pack↔issues
   comparison plus the pack↔implementation comparison (or explicit N/A for
   no active implementation). Missing either comparison record is FAIL.

A pack that fails fresh-eyes is **not done**. Findings route exactly like a
code review: authoring crew fixes; reviewer (or authoring crew on re-check of
fixes) confirms clear.

### Terminal report (only after Phase 9 PASS and Phase 10 clear)

1. Write / update the durable report the brief names (usually
   `…/data/<task>/report.md`) pointing at the pack, issue URLs, completeness
   PASS, and fresh-eyes clear (harness named).
2. Copy pack to any durable snapshot path the brief requires.
3. Status: `done: program pack complete - epic #<n>, N slices, completeness PASS, fresh-eyes clear on <harness>`.

## What this skill does NOT do

- **No product implementation** (unless the brief re-modes the task after pack).
- **No merge / force-push / remote rewrite.**
- **No interactive six-gate human babysitting** - that is super-flow's operator
  mode; you batch and board.
- **No silent scope growth** past the framed program.
- **No wall-clock estimates** in plans, issues, or skill templates.
- **No stop-gap architecture** that must be thrown away for the known end-game.
- **No claiming done** with open captain-grade questions, missing exit criteria,
  unfiled slices, completeness FAIL, or unresolved fresh-eyes blockers.
- **No second process router** (no Osmani 24-skill lifecycle, no Spec Kit CLI
  ownership, no `/build auto` inside this skill). One crew-pointable skill;
  implementation execution stays on ship / TDD / review-crew skills.
- **No full-SDLC pack sprawl** (CI/CD matrices, observability launch checklists,
  marketing launch plans). Those belong to implementation and smoke skills.
- **No Gherkin/EARS ceremony for every line** - prefer probe commands and
  concrete scenarios where they help; do not invent BDD theater.

## Relationship to other skills and field sources

| Skill / system | Relationship |
|---|---|
| `/super-flow` (captain interactive) | Same intent; this is the autonomous crew form |
| Pocock `grill-with-docs` / `to-spec` / `to-tickets` | Steal: out-of-scope, tracer bullets, blocking edges. Reject: multi-turn human quiz as the only gate |
| Pocock `wayfinder` | Steal: fog-of-war, out-of-scope, decision tickets. Reject: multi-session map as default for every program |
| Superpowers brainstorming / writing-plans | Steal: one-question discipline (on the board), bite-sized TDD shape in slices |
| Spec Kit / BMAD / GSD | Steal: explicit artifact chain + phase order. Reject: process-owning frameworks that replace fleet pack shape |
| Osmani agent-skills | Steal: anti-rationalization, DoD vs AC, in-flight doubt, Always/Ask/Never boundaries. Reject: 24-skill router + wall-clock sizing + full SDLC absorption |
| Shape Up | Steal: appetite, rabbit holes, no-gos, betting-table framing for Lavish. Reject: replacing multi-slice packs with pitch-only for federation-scale work |
| Amazon PR/FAQ | Steal: short operator fiction / definition of right in user language. Reject: corporate TAM theater for internal platform packs |
| ATDD / Spec by Example / Kiro EARS | Steal: example-shaped exit criteria; analyze-requirements. Reject: mandatory Gherkin everywhere |
| OpenSpec | Steal: delta/archive mindset for promotion-report ("what becomes parent law"). Reject: fluid thin proposals without a fail-closed gate |
| IETF last-call | Steal: external multi-audience review as legitimacy - instantiated as **Phase 10 fresh-eyes**. Reject: full standards process overhead |
| Nygard ADR | Steal: consequences (±) on every decision row. ADRs remain point decisions; packs remain programs |
| Anti-ceremony / supervisor-skill school | Steal: evidence quality over inventory; quote prior decisions; refuse skill for thin work. Reject: using "ceremony is bad" to ship vague briefs again |
| `decision-hold-lifecycle` | If the task tears down before locks land, register captain holds per that skill - do not lose opens |
| `review-crew` / `smoke-crew` | Downstream for **code**. Fresh-eyes (Phase 10) is pack-seam review on a different harness; may use review-crew *shape* but targets artifacts, not diffs |

Field research bases (do not re-narrow only to Spec Kit):

- Round 1: `${FM_HOME}/data/vellum-program-skill-scout/report.md`
- Round 2: `${FM_HOME}/data/vellum-program-skill-scout-r2/report.md`

## Anneal

When a pack that passed both gates still fails a build crew, append a row here
(date, failure mode, checklist or phase addition). Founder/captain ratifies at
skill ship time.

| Date | Trigger | Edit |
|---|---|---|
| 2026-07-25 | Initial authoring from super-flow + lived good packs + r1 ecosystem survey | Bootstrap |
| 2026-07-25 | R2 field synthesis + captain fresh-eyes requirement | Evidence-quality completeness; Phase 0 refuse/mini-pack; anti-rationalization; DoD vs AC; in-flight doubt; appetite/rabbit-holes; consequences; boundaries; quote prior law; Phase 10 cross-harness fresh-eyes |
| 2026-07-25 | Audit p1: pack-only Phase 10 missed silent code-vs-spec (HTTPS→HTTP downgrade) | Phase 10 mandatory pack↔issues↔active-implementation comparison; COMPLETENESS J3–J4 exit criteria |
