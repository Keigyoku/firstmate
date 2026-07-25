# program-pack — Completeness gate

**Fail closed.** The task is not done until every required row is PASS **and**
Phase 10 fresh-eyes is clear. Completeness alone is necessary, not sufficient.

A thin pack that "looks done" is the failure mode this skill exists to kill.
**A beautiful empty section fails harder than a slightly rough README.**

Run this checklist at the end of Phase 9 — **before** fresh-eyes. Paste a
filled copy into `completeness.md` next to the pack (or the durable report).
Any FAIL → fix or `failed:` with the failing rows; never proceed to fresh-eyes
or `done:` with open FAILs.

---

## How to score (evidence quality, not inventory)

| Score | Meaning |
|---|---|
| **PASS** | Present, **specific**, **evidence-backed where claims need evidence**, and usable by a fresh implementation crew |
| **FAIL** | Missing, vague, contradictory, placeholder, unusable, **present-but-thin**, or claim without re-traceable evidence |
| **N/A** | Only where the row explicitly allows N/A and the justification is written |

### Severity principle

| Worse | Better (still may FAIL other rows) |
|---|---|
| Empty or boilerplate section with a correct filename | Rough prose that carries measured evidence and adjudicable examples |
| Exit criteria that cannot fail (always "green") | Fewer slices with probes a stranger can run |
| Parent law paraphrased from memory | One fewer optional flourish, with **quoted** locks |

Do not invent N/A for discomfort. "We were short on context" is FAIL, not N/A.
**File existence without substance is FAIL on the quality rows (C/D/G), not a
PASS on A-rows.** A-rows still check the artifact set exists; C/D/G judge whether
it is real. Both layers must PASS.

---

## Path: full vs mini

| Path | Required sections |
|---|---|
| **Full** | All rows below marked required for full |
| **Mini** | A2–A3 or A3 only as listed; A5, A7; B1–B5; C1, C4-mini; D1–D5; F1–F4; G1–G3; H1; skip A4/A6/A8-full architecture/ledger only if Phase 0 documented mid-size and no captain-grade opens — if opens appear, upgrade to full |

When in doubt, use **full**.

---

## A. Artifact set

Existence only — still required, but **never sufficient**.

| # | Check | Score |
|---|---|---|
| A1 | `README.md` exists with north star, hard rules, dispatch order, pack index, status enum, appetite pointer | |
| A2 | `prd.md` exists with problem, stories, definition of right, non-goals, operator fiction (full path) | |
| A3 | `spec.md` exists with summary, scope boundaries, as-is evidence, behavioral contract, boundaries triple | |
| A4 | `architecture.md` exists with components/seams, flows, failure modes, rabbit holes, end-game compatibility, alternatives (full) | |
| A5 | `implementation-plan.md` exists with dependency graph, slices, appetite/cutting point | |
| A6 | `decision-ledger.md` exists with stable decision IDs and consequences (±) (full; mini N/A only if zero non-trivial decisions) | |
| A7 | `issue-index.md` exists with full GitHub URLs for epic + every slice | |
| A8 | `captain-decisions.md` exists (locks **or** explicit "none required" + why) | |
| A9 | `promotion-report.md` exists with ready-vs-residual, circuit-breaker, related-PR verdict if any (full; mini: short promotion blurb in report OK) | |
| A10 | `fresh-eyes.md` will exist after Phase 10 (Phase 9: mark pending; Phase 10 clear required for done) | |

---

## B. Scope and honesty

| # | Check | Score |
|---|---|---|
| B1 | Explicit **What we are NOT doing** appears in README and/or spec (deferred vs rejected) | |
| B2 | No load-bearing `TBD` / `TODO` / `fill in later` / `…` in spec, architecture, or plan exit criteria | |
| B3 | Parent law / non-reopenable locks listed **with quotes or verbatim excerpts + paths** — not regenerated paraphrase | |
| B4 | **No stop-gap architecture:** every major design states end-game compatibility; no "temporary model we will throw away" without captain lock | |
| B5 | **No human wall-clock** effort language in pack or issue bodies (scope/risk/blast/appetite only) | |
| B6 | Related in-flight PRs get an explicit verdict (land / amend / supersede / ignore) when relevant | |
| B7 | **Rabbit holes** listed (architecture and/or plan) with owning slice or containment | |
| B8 | **Appetite / cutting point** stated (what cuts if exit criteria cannot be met without reopening architecture) | |

---

## C. Evidence and model quality (same severity as missing files)

| # | Check | Score |
|---|---|---|
| C1 | As-is claims cite re-traceable evidence (file:line, command output, measured topology, **quoted** ADR text) | |
| C2 | Defects/risks are grouped into **families** or a **canonical model** when fragmentation is the disease — not only a bug laundry list | |
| C3 | Architecture recommendation is chosen among ≥2 alternatives with trade-offs recorded (full; mini N/A if design is forced by parent law — say so) | |
| C4 | Adversarial self-check (external / mechanism / third-party) was run; confirmed highs amended or justified residual | |
| C5 | **Analyze-requirements:** no unresolved contradictions between pack docs; no silent defaults on load-bearing behavior; actors named | |
| C6 | Non-trivial architecture claims show **in-flight doubt** outcome (CLAIM + evidence + doubt result) or explicit "trivial/unambiguous file:line" waiver per claim | |
| C7 | Operator fiction / definition of right in user language is present and non-vacuous (full; mini: at least definition of right in spec summary) | |

**Scoring note for C-rows:** If an A-row file exists but C1/C5 fail for its
content, overall is FAIL. Do not "PASS A4, FAIL C1" and then shrug — both count;
zero FAILs required.

---

## D. Slices and shippability

| # | Check | Score |
|---|---|---|
| D1 | Every non-optional slice is **independently shippable** (own PR / dispatch unit) | |
| D2 | Every non-optional slice has **exit criteria** a fresh crew can adjudicate green/red **including ≥1 example/probe** (command, scenario, or observable) — "implement X" alone is FAIL | |
| D3 | Dependency edges are explicit; no hidden "do everything in one PR" coupling unless labeled as expand-contract exception | |
| D4 | Optional / later slices are marked optional; P0 path is clear | |
| D5 | Blast radius stated per slice | |
| D6 | High-blast slices name a **deep-review affordance** (what a human supervisor must still trace) | |

---

## E. Captain decisions

| # | Check | Score |
|---|---|---|
| E1 | All captain-grade opens were either locked on a Lavish board **or** registered as durable captain holds per `decision-hold-lifecycle` before teardown | |
| E2 | Locks are **verbatim** in `captain-decisions.md` with board path/URL | |
| E3 | Pack (spec/plan/architecture/ledger) was **rebased** onto locks when captain diverged from recommendation | |
| E4 | No product fork left as "implementation crew will figure it out" | |

---

## F. Issues

| # | Check | Score |
|---|---|---|
| F1 | Program epic exists (created or brief-named) with full URL | |
| F2 | One GitHub issue per non-optional slice, filed as child/sub-issue of the epic (or body-linked if tracker lacks nesting) | |
| F3 | Issue bodies carry exit criteria (**example-shaped**), standing DoD pointer, and blocked-by edges | |
| F4 | `issue-index.md` matches filed issues (no phantom slice without issue; no orphan issue without plan row) | |

---

## G. Hand-off readiness (the bar that matters)

| # | Check | Score |
|---|---|---|
| G1 | A fresh implementation crew can start slice 1 **without** asking "what does done look like?" | |
| G2 | A fresh implementation crew can refuse out-of-scope work using only the pack (Always / Ask / Never + NOT-doing) | |
| G3 | Durable report (task `report.md` or equivalent) points at pack path + epic + completeness scores | |
| G4 | Self-score: would this pack survive comparison to the federation pack / topology scout bar **on evidence**, not on file count? If no → FAIL G4 and strengthen | |
| G5 | Standing **implementation DoD** is pointed from README and/or issues (distinct from per-slice AC) | |

---

## H. Decision quality

| # | Check | Score |
|---|---|---|
| H1 | Every decision-ledger row (when ledger required) has **consequences (+)** and **consequences (−)** | |
| H2 | Boundaries Always / Ask first / Never present in spec (full; mini: equivalent fence in scope section) | |
| H3 | Promotion-report **circuit breaker** present: reopen lock vs cut scope vs kill (full; mini: short form OK) | |

---

## After this gate: Phase 10

Completeness **PASS** unlocks **cross-harness fresh-eyes** (SKILL.md Phase 10).
Fresh-eyes is **not** a re-run of this checklist — it is a separate hard gate:

- Different harness from authoring
- Seam review (contradictions, quiet reversals, non-proving exits, unstated
  assumptions, PRD↔plan gaps, **pack↔issue-body**, and **pack↔active
  implementation when implementation exists**)
- Findings fixed like a code review
- `fresh-eyes.md` CLEAR required before `done:`

| # | Check (terminal, after Phase 10) | Score |
|---|---|---|
| J1 | `fresh-eyes.md` exists; review harness ≠ authoring harness; freeze refs recorded (pack path + commit SHA + issue snapshot) | |
| J2 | Zero open blocker/major findings; residuals listed in promotion-report | |
| J3 | Pack ↔ filed **issue bodies** compared (not issue existence alone); seams fixed or residual with rationale | |
| J4 | Pack ↔ **active implementation** compared whenever any non-optional slice has code, a PR, review/test evidence, or shipped behavior the pack claims to govern; silent code-vs-spec and code-vs-pack contradictions score FAIL. If no active implementation exists, score **N/A** only with that justification written in `fresh-eyes.md` | |

J1–J4 are checked at task close, not as a substitute for Phase 9.
**OVERALL task done requires J1–J4 PASS** (J4 may be N/A with written justification).
A pack-only review that skips J3, or skips J4 when implementation exists, is FAIL.

---

## Verdict (Phase 9)

```text
Path: full | mini
Required rows total: …
PASS: …
FAIL: …   ← list IDs
N/A: …

OVERALL: PASS | FAIL
```

**OVERALL PASS** only if zero FAIL on required rows for the chosen path.

On FAIL, do not append `done:` and do not start fresh-eyes until fixed. Either
repair or append `failed: completeness gate — <failing ids>`.

On PASS, proceed to Phase 10. Task-level `done:` only after J1–J4 CLEAR
(J4 may be N/A with written no-implementation justification).
