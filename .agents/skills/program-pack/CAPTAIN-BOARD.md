# program-pack — Captain decision board protocol

Fleet standing rule: the crew that produces captain-grade open questions
**builds its own Lavish input board, serves it, polls it, and stamps the pack
locked with his answers.** Questions do not get shepherded through firstmate
chat as the primary decision channel.

This board is the fleet **betting table**: appetite, no-gos, and one-way-door
product forks — not only technical multiple-choice trivia.

This document is the operational procedure. Skill body: [SKILL.md](SKILL.md).

---

## When a board is required

Build a board if Phase 2 produced any **captain-grade opens** — product forks,
architecture picks, sequencing against live PRs, security model choices, scope
locks, or appetite/cutting-point bets the crew must not invent.

Skip the board only when every decision is:

- constrained by parent law already locked (**quoted**, not paraphrased), **and**
- mechanical from measured evidence, **and**
- recorded as provisional in the decision ledger with rationale and
  consequences (±).

Then `captain-decisions.md` must say **none required** and why.

---

## Board construction

1. Create HTML under `.lavish/<program-slug>-captain-lock.html` in the worktree
   (or the durable data path if the brief forbids project writes).
2. Open the Lavish **input** playbook before authoring:
   `npx -y lavish-axi playbook input`
   Also open `comparison` and/or `plan` playbooks when the board includes
   trade-off matrices or sequencing.
3. Design source: prefer project design tokens if the pack is product-facing;
   otherwise Tailwind v4 + DaisyUI CDN via `npx -y lavish-axi design`.

### Required board content

- **Header:** program title, why a lock is needed now, pack path, related PR/epic.
- **Parent law strip:** non-reopenable constraints with **short quotes + paths**
  (do not re-litigate; do not regenerate from memory).
- **Verified problem:** short evidence (not a second novel).
- **Appetite / no-gos strip:** what this bet is worth cutting to; what is never
  in scope for this program.
- **One section per decision ID** (stable IDs: `HA1`, `TM-A`, `SEQ-1`, …):
  - Question in plain language
  - Multiple-choice options (A/B/C…) each with **consequences (+ and −)** and
    **end-game compatibility**
  - **Crew recommendation** pre-selected where the input control allows
  - Freeform only when options cannot cover the decision
- **What locking enables:** "after answers, pack rebases and issues stay valid /
  get title fixes; fresh-eyes still runs on the locked pack".

### Decision quality bar

Bad question: "Thoughts on auth?"  
Good question: "HA1 — list fan-out credential model" with options ambient /
subject-hop / capability-tokens, consequences for each, and a recommended default.

Every option must state whether it is a stop-gap. Stop-gaps require explicit
captain acceptance and an end-game path — prefer designs that are scope-narrow
but end-game compatible.

Frame one-way doors explicitly: "this choice is expensive to reverse because…"

---

## Serve and poll

```bash
# serve / open session
npx -y lavish-axi .lavish/<program-slug>-captain-lock.html

# long-poll for answers (do not kill; re-run if harness times out)
npx -y lavish-axi poll .lavish/<program-slug>-captain-lock.html
```

While waiting:

- Prefer status `paused: awaiting captain Lavish locks on <board>` when the
  wait is expected to clear without supervisor intervention.
- Do **not** paste the full question set into firstmate chat.
- A short status line that the board URL is live is enough if the brief asks
  for visibility; Bearings / captain surfaces own how the human finds it.

If Lavish cannot bind/serve:

- `blocked: lavish unavailable — cannot complete captain lock for program-pack`
- Do not invent locks.
- Optionally register each open via `decision-hold-lifecycle` /
  `bin/fm-decision-hold.sh hold` so teardown cannot erase the opens.

---

## Stamp and rebase

When poll returns answers:

1. Write `captain-decisions.md` with **verbatim** answers, board URL, timestamp.
2. Table: crew recommendation vs captain choice when they differ.
3. **Rebase** the pack onto locks:
   - `decision-ledger.md` — mark locked; fill consequences from chosen option
   - `spec.md` / `architecture.md` — normative path follows captain
   - `implementation-plan.md` — slice order, shape, and appetite follow captain
   - issue titles/bodies — update if pre-filed under a rejected default
4. End the Lavish session: `npx -y lavish-axi end .lavish/<file>.html` when done.
5. Never leave the pack recommending A while locks say C.
6. After rebase, completeness (Phase 9) and fresh-eyes (Phase 10) still run —
   locks do not skip gates.

---

## Teardown safety

If the task may tear down before answers land:

1. Inventory captain-grade opens.
2. Register durable holds per `decision-hold-lifecycle` (stable keys).
3. Complete the hold inventory (`complete` with keys, or `--none` only if truly none).
4. Report path must still list the opens and hold identities.

A pack without locks and without holds is **incomplete** — completeness E1 FAIL.

---

## Anti-patterns

| Anti-pattern | Do instead |
|---|---|
| Dumping opens into firstmate chat for the captain to reply in-thread | Lavish board |
| Asking open-ended essay questions | Multiple choice + recommended default + consequences |
| Filing issues that assume the recommendation before lock, then never updating | Rebase issues after lock or file after lock |
| Marking done while poll is empty | `paused` / wait / holds |
| Silent default to crew preference when captain is unreachable | blocked or holds — not silent lock |
| Betting only on technical options, never appetite/no-gos | Include appetite strip and cutting-point question when scope is elastic |
| Regenerating parent law on the board from memory | Quote ADRs/locks with paths |
