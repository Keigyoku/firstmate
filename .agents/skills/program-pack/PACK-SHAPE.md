# program-pack — Pack shape and templates

Required files and minimum sections. A missing **or thin** required section is a
completeness **FAIL** (see [COMPLETENESS.md](COMPLETENESS.md)). Completeness
scores **evidence quality**, not headers alone.

Calibrate quality against:

- Topology-style packs: measured as-is, defect families, one trust model, ordered
  slices with exit criteria, explicit NOT doing, verdict on related PRs.
- Federation-style packs: parent law, captain locks, ADR linkage, epic + sub-issues.

**Paths:**

| Path | Required files |
|---|---|
| **Full program** | All sections below |
| **Mini-pack** (Phase 0 mid-size) | `spec.md`, `implementation-plan.md`, `issue-index.md`, plus filled `completeness.md` (mini rows) and `fresh-eyes.md`. Optional short README. |

---

## README.md

```markdown
# <Program title> — design pack

**Program:** `program/<slug>`
**Era / phase:** <if project uses one>
**Epic:** [#N](https://github.com/<owner>/<repo>/issues/N)
**Status:** <draft | captain-locked | completeness-pass | fresh-eyes-clear | promoted | obsolete>
**Date:** YYYY-MM-DD
**Owner:** program-pack crew
**Authoring harness:** <claude | codex | grok | …>
**Fresh-eyes harness:** <must differ — see Phase 10>

## North star
<1–3 sentences: what "done" means for the program as a whole>

## Appetite / cutting point
What this program is *worth* cutting to if a slice cannot meet exit criteria
without reopening architecture. Scope-worth envelope — never wall-clock.

## Pack contents
| File | Role |
|---|---|
| prd.md | … |
| … | … |

## Hard rules (seam discipline)
1. …
2. …

## Standing implementation Definition of Done
Pointer: correctness (exit criteria green) · quality (tests/guards) ·
integration · docs/ADRs owned by slice · ship-readiness/rollback for medium+
blast. Distinct from per-slice acceptance criteria.

## Recommended dispatch order
1. …
2. …

## What we are NOT doing
- …

## Provenance
Evidence bases, parent packs, branches, measurement date.
Quoted parent law (paths + excerpts), not regenerated folklore.
```

---

## prd.md

```markdown
# PRD — <Program title>

## Problem
User- or operator-facing problem. Evidence of pain (incidents, failed PRs,
measured growth, security contradiction, etc.).

## Who is affected
Actors (captain, end user, CI, peer host, …).

## Operator fiction (definition of right in user language)
5–8 lines: what a CCD power user / operator would notice as success.
Plain language. If this paragraph is empty or jargon-only, the PRD is thin.

## Definition of right
Observable outcomes that mean the program succeeded. Not a task list.

## User / operator stories
Numbered stories: As a <actor>, I want <capability>, so that <benefit>.
Cover the program surface thoroughly — thin story lists are a smell.

## Non-goals (product)
Mirror of "what we are NOT doing" in product language.

## Hardest objections (preplay)
FAQ-style: strongest reasons this program is wrong, premature, or mis-scoped —
and the answer. Not marketing; adversarial preplay.

## Success metrics (optional)
Prefer measurable contracts (exit criteria families) over vanity metrics.
Never wall-clock.
```

---

## spec.md

```markdown
# Spec — <Program title>

Frontmatter or header: program slug, status, date, parent ADRs, tags.

## 1. Summary
2–3 paragraphs: net behavioral change.

## 2. Scope boundaries
### In scope
### Out of scope (deferred) — with why / when it returns
### Out of scope (rejected) — with rationale
### Parent law (not reopenable)
Table: lock ID / ADR · **verbatim quote or short excerpt** · path ·
what it does / does not excuse.
Do not paraphrase from memory.

### Boundaries (Always / Ask first / Never)
| Tier | Rule |
|---|---|
| Always | Crew decides within parent law — list |
| Ask first | Captain / Lavish — list decision IDs |
| Never | Out of program — list |

## 3. As-is (verified)
Evidence: file:line, commands, measurements. No folklore.

## 4. Behavioral contract
Normative requirements. Prefer MUST/SHOULD language.
Prefer scenario / example form where natural:
  WHEN <condition> THE SYSTEM MUST <observable>
  or command-level probe as the example.
Failure surfaces and error contracts.

## 5. Decision locks
Table of provisional + captain locks (IDs stable: e.g. HA1, TM-A).

## 6. Testing / verification contract
What proves each major requirement (probe, unit, smoke, manual dogfood).
Prefer existing seams.

## 7. Risk register
Risk → severity → mitigation → which slice owns it.

## 8. ADR impact
New / amended ADRs or "none — justify".

## 9. References
```

**Required:** §2 must include explicit NOT-doing + quoted parent law. §3 must be
evidence-backed. Boundaries triple must be present on full packs.

---

## architecture.md

```markdown
# Architecture — <Program title>

## Context
How this sits in the system.

## Canonical model
When the problem is fragmentation: **one** trust model / seam / identity story.
Not a pile of local checks.

## Components and seams
Modules, interfaces, ownership. Prefer deep modules (simple interface, rich
behavior) at existing seams.

## Data / control flows
1–3 end-to-end flows (ASCII or mermaid).

## Failure and partial-failure
What degrades; what fails closed.

## Rabbit holes
Implementation explosion risks (what looks small and is not). Which slice
contains each hole; what "stop digging" looks like.

## End-game compatibility
What must remain true when deferred work lands. Explicit statement that v1 is
a **scope** lock, not a throwaway architecture.

## Alternatives considered
Summary of Phase 3 options + why recommendation won.
Include in-flight doubt outcomes for non-trivial claims
(CLAIM → evidence → doubt result).

## Threat / abuse notes (when auth, vault, network, or agents are in blast)
Abuse cases and fail-closed expectations — not a full security audit.
```

A section titled "Architecture" with only context fluff is **FAIL**. Components,
flows, failure modes, and alternatives are load-bearing.

---

## decision-ledger.md

```markdown
# Decision ledger — <Program title>

| ID | Decision | Options considered | Choice | Rationale | Consequences (+) | Consequences (−) | End-game note |
|---|---|---|---|---|---|---|---|
| L1 | … | A / B / C | A | … | … | … | … |

Every row needs both consequence columns. Empty (−) is FAIL unless truly none
(state "none material" explicitly).

## Resolved
## Open (must be empty after captain lock or held via decision-hold)
## Explicit non-decisions
```

---

## implementation-plan.md

```markdown
# Implementation plan — <Program title>

**Style:** Independently shippable slices; RED → GREEN → commit when code.
**Captain locked:** <lock IDs or none>
**Appetite / cutting point:** <what cuts if exit criteria cannot be met without
reopening architecture — scope envelope, not calendar>

## Dependency graph
<code block or mermaid>

## Rabbit holes (plan-level)
| Hole | Risk | Owning slice | Containment |
|---|---|---|---|

## Slice <ID> — <title>  (#issue when filed)

**Goal:** one sentence.

**Ship:** what lands.

**Does not:** boundaries.

**Blast radius:** low | medium | high + which surfaces.

**Depends on:** slice IDs / issues.

**TDD / verification steps:** (when code)
1. RED: …
2. GREEN: …

**Exit criteria:**
- [ ] … (observable)
- [ ] **Example / probe:** <command, scenario, or green/red observation
      a fresh crew can adjudicate — required for every non-optional slice>

**Standing DoD reminder:** exit criteria prove the slice; fleet DoD still
applies at ship (tests/guards, integration, docs, rollback when blast warrants).

**Optional?** yes/no

**Deep-review affordance (high-blast only):** who/what must be human-traced
when this slice lands (optional row; required if blast is high).
```

**Forbidden in this file:** human wall-clock estimates ("2 days", "next week",
"30 minutes of agent work").

**Required:** every non-optional slice has exit criteria **and** ≥1 adjudicable
example/probe.

---

## issue-index.md

```markdown
# Issue index — <Program title>

**Epic:** [Title](https://github.com/<owner>/<repo>/issues/N)

| Slice | Issue | Title | Blocked by | Status label |
|---|---|---|---|---|
| A | [#N](url) | … | — | ready-for-agent |

## Filing notes
Tracker, labels, any title drift vs plan.
```

---

## captain-decisions.md

```markdown
# Captain decisions — <Program title>

**Board:** <Lavish URL or path>
**Artifact:** `.lavish/<name>.html`
**Locked:** YYYY-MM-DD

## Locks (verbatim)

| ID | Captain answer (verbatim) | Meaning |
|---|---|---|
| … | … | … |

## Freeform (verbatim)
…

## Crew recommendation vs lock
Table when they diverge — pack follows captain.

## None required
If no board: state why all decisions were provisional under parent law.
```

---

## promotion-report.md

```markdown
# Promotion report — <Program title>

## Locked and ready for implementation crews
## Residual open (must be empty or held)
## Supersedes / relates to PRs
Verdict on related in-flight PRs (land / amend / supersede / ignore) with rationale.
## What becomes parent law
Which pack decisions / ADRs should merge into long-lived project law after ship
(archive mindset — anti drift).
## Circuit breaker
If slice N cannot meet exit criteria without reopening architecture:
- which **lock** would reopen (IDs), vs
- which **scope** cuts (appetite), vs
- kill / re-pack criteria
## Pack location and issue URLs
## Completeness: PASS (link scores)
## Fresh-eyes: clear on harness <name> (link fresh-eyes.md)
```

---

## completeness.md / fresh-eyes.md

Filled gate outputs live next to the pack (or embedded in the durable task
report). Templates: [COMPLETENESS.md](COMPLETENESS.md) and Phase 10 in
[SKILL.md](SKILL.md).

### fresh-eyes.md skeleton

```markdown
# Fresh-eyes review — <Program title>

**Authoring harness:** …
**Review harness:** …   # MUST differ
**Reviewer / task id:** …
**Pack path:** …
**Date:** YYYY-MM-DD

## Findings

| ID | Severity | Seam | Evidence | Disposition |
|---|---|---|---|---|
| FE1 | blocker \| major \| minor \| note | … | … | fixed \| residual \| rejected |

## Exit
- Open blockers/majors: none | list
- Second pass needed: yes/no
- Verdict: CLEAR | NOT CLEAR
```

---

## Issue body template (GitHub)

```markdown
## Parent
Epic: https://github.com/<owner>/<repo>/issues/<epic>

## Pack
<path or durable data path> — slice <ID>

## What to build
End-to-end behaviour or contract this slice makes true.
Not a layer-by-layer chore list.

## Acceptance / exit criteria
- [ ] …
- [ ] Example / probe: …

## Standing Definition of Done
Fleet standing bar still applies: tests/guards for touched surfaces, no known
regressions in blast radius, docs/ADRs this slice owns, rollback/fail-closed
when blast is medium or high. Acceptance criteria ≠ DoD.

## Blocked by
- None — can start immediately
- or full issue URLs

## Blast radius
…

## Out of scope for this issue
…
```

Use `gh-axi` to create issues. Prefer sub-issue / parent relationship when the
tracker supports it; always link the epic in the body.

---

## ADR draft template (when needed)

```markdown
---
title: <Short decision title>
status: proposed
adr: "NNNN"
date: YYYY-MM-DD
---

# NNNN — <Title>

## Status
## Context
## Decision
## Rationale
## Consequences
### Positive
### Negative
## Tradeoffs
## End-game compatibility
## Mechanism verified
## Follow-ups
## References (pack, issues, evidence — quote parent law where superseded)
```
