# Claim guard false-positive diagnosis (2026-07-29)

Diagnosis only.
`bin/fm-claim-guard.sh` is unchanged and keeps the false positives described below.
`docs/turnend-guard.md` remains the owner of the claim-guard contract.

The task brief commissioned this diagnosis against a reported subset of three consecutive primary turns on 2026-07-29.
Firstmate subsequently reported the primary session total reaching ten and then sixteen blocks that day, every one a false positive.
This records why that three-turn subset blocked, why the fix requested in the task brief is not implementable as specified, why the replacement that was built was dropped rather than shipped, and what the right seam looks like.

## Method

The incident counts above are reported rather than independently verified here.
The mechanism and every `BLOCK` / `allow` row below are first-hand: each verdict was produced by piping payloads into the real tracked `bin/fm-claim-guard.sh` inside a primary-shaped temp home with a stale glass marker.
No regex was read forward into a conclusion about the mechanism.
The full probe transcript is reproduced in the "Evidence transcript" section.

## Initiating trigger

`message_is_app_state_claim` is a bag-of-words conjunction over the entire message.
One referent token anywhere plus one assertion token anywhere blocks, with no grammatical or positional binding between them.

Established by minimal counterfactual, one token at a time:

```text
BLOCK  Captain, the Vellum crew is still working on the input-route fix; nothing to review yet.
allow  Captain, the crew is still working on the input-route fix; nothing to review yet.
allow  Captain, the Vellum crew is still chewing on the input-route fix; nothing to review yet.
```

Removing only the referent flips it; removing only the assertion flips it.
The subject of "working" is the crew, never Vellum.

Binding is absent entirely, not merely weak:

```text
BLOCK  Captain, I opened the dashboard bookmark you asked about. Separately, the login bug is fixed on the other branch.
```

Two unrelated sentences, referent in the first and assertion in the second, still block.

## Masking condition

The heuristic is byte-identical to its introduction in `44042ca` (2026-07-20); `git show 44042ca:bin/fm-claim-guard.sh` confirms it.
No code change caused the 2026-07-29 burst, so the trigger has been latent since day one.

The mask is the glass marker's freshness window.
Within `FM_CLAIM_GLASS_MAX_AGE` (default 900s) of any capture the guard is globally inert, and the same false positive silently passes:

```text
allow  Captain, the Vellum crew is still working on the input-route fix.   # fresh marker
BLOCK  Captain, the Vellum crew is still working on the input-route fix.   # stale marker
```

On 2026-07-29 the primary's marker read epoch `1785268764` against a session clock of `1785331722`, about 17.5 hours stale, so the latent trigger was exposed for the whole session.

Staleness is a participant, not a bystander, but it is a blunt global mute rather than a claim-specific one: a fresh capture also suppresses genuine unevidenced claims for 15 minutes.

## The scope-changing finding

The guard cannot distinguish a verified claim from an unverified one, and structurally never could.

`data/learnings.md:10` records the three real catches: a flock measurement never reproduced, a "done" that was only a commit, and a defect "reproduced" on a status line alone.
Probing faithful renderings of those three shows the catches were incidental vocabulary collisions rather than classification:

```text
BLOCK  Captain, the flock measurement is fixed - peer discovery settles in 200ms on the daily-driver.
allow  Captain, flock convergence is working now: 200ms across the containers.
BLOCK  Captain, the Vellum sendinput defect is fixed and the work is landed.
allow  Captain, that is done - the app fix is landed on main.
allow  Captain, the crew reproduced the defect - the Vellum terminal repaint bug is confirmed.
allow  Captain, reproduced - the dashboard is dropping the peer list on refresh.
```

Every faithful rendering of catch 3 sails through.
Catch 2 blocks in one phrasing and passes in one other.
Observed recall was two of six renderings blocked; the precision that produced three good catches was luck.

The decisive result is a minimal pair whose two members are the same string:

```text
BLOCK  Captain, the Vellum flake is fixed and checks passed.
```

That message is a false positive when the turn queried the check-runs API and a true positive when the turn relayed a crewmate's word.
The verdict is identical because the distinguishing fact is what the turn did, which is not in the text.

Therefore the brief's two acceptance criteria are jointly unsatisfiable by any predicate over claim vocabulary.
The false-positive fixture and the true-positive fixture are the same message shape; no vocabulary narrowing, proximity rule, or grammatical binding separates them.

## The guard punishes compliant output

Both message shapes the captain's own rules mandate are blocked today:

```text
BLOCK  Captain, the Vellum flake is fixed and checks passed (gh check-runs on 4a91c2f: all green).
BLOCK  Captain, the crew reports the Vellum flake is fixed; unverified, I have not reproduced it.
```

The first carries the source receipt required by `data/captain.md:46`.
The second is the explicit attribution required by the same line and by `data/learnings.md:10`.
`data/learnings.md:10` also records that the guard's screenshot remedy is the wrong instrument for a claim about code or a measurement.

## Where the architecture gives way

`message_is_app_state_claim` is a shallow module.
Its interface is `text -> bool`, nearly as complex as its two-grep implementation, and it discards the one fact the caller needs: which kind of evidence the claim requires.

The caller then hard-wires that single boolean to a single evidence channel, `glass_evidence_fresh`.
There is no seam at which a second evidence kind could attach, so the guard's leverage is capped at the one claim class it can verify, while it is applied to claim classes it structurally cannot verify.

The real question the interface should answer is not "does this need evidence?" but "what kind of evidence does this claim need, and was that kind produced this turn?".

## What was attempted, and what the attempt established

A receipt predicate was built and then dropped.
It replaced "is this an app-state claim?" with "does this assertion carry its source receipt?", on the reasoning that receipt presence, unlike verified-ness, is a property of the text.
It passed its own tests and lifted recall on the three recorded catches from two of six renderings to six of six.

It was dropped anyway, because review found it leaked evidence between unrelated claims, and every attempt to stop the leak relocated it.

**Five successive fixes each moved the boundary, and the leak reappeared at the new boundary.**
That count is the evidence for the conclusion in the next section; it is not a list of unrelated bugs.

Read the count, not just the failures.
One failed attempt says the problem is hard and the next attempt might land it.
A converging series - five fixes, each competently addressing the previous defect, each reproducing it one boundary further out - says the approach is wrong, and that no sixth attempt along the same line will land it either.
That distinction is the entire reason this document exists, and it is why the work was stopped rather than continued.

1. **Whole message, referent and assertion.**
   The original predicate: any app referent token anywhere plus any health verb anywhere, unbound.
   `the Vellum crew is still working` blocked on `vellum` + `working`.
2. **Whole message, assertion and receipt.**
   The receipt rewrite: any receipt anywhere cleared every assertion anywhere.
   `PR merged (https://...); CI is green` passed although the CI half had no receipt.
3. **Clause span.**
   A clause splitter was added.
   It enumerated subjects, so comma-separated clauses and conjunctions still shared one receipt: `PR merged (url), deployment is live` remained a single unit.
4. **Mood exclusion span.**
   A narrow prospective/conditional exclusion was added so `waiting for CI to turn green` would not fire.
   One marker then amnestied its whole clause: `If CI is green, deployment is live` discarded the definite unreceipted second assertion along with the conditional first.
5. **Command string.**
   The seam moved to recording what the turn ran, but the recorder classified commands by regex over the raw command string with no quote or heredoc handling, so `printf '%s\n' '; git status'` recorded a `git-read` although only `printf` executed.

Instances 1, 2, 3 and 5 are literally the same defect: unbound token matching over a span, where content that should not count leaks into the match.
Instance 5 is the important one, because it appeared *after* the seam had supposedly moved off the message text.
The evidence side was still being inferred from a string; only which string had changed.

## Why the receipt rewrite was dropped rather than shipped

The old guard is **noisy**.
The receipt rewrite is **fail-open**.

A noisy guard costs a rewritten message per false positive, and the reader knows it fired.
A fail-open guard goes quiet while certifying claims nothing checked, and it is worse than the bug it replaces precisely because it *looks* fixed.
One pasted link clearing every other assertion in the message is that failure mode exactly.

Eating false positives is survivable.
A guard that lies quietly is not.
The guard therefore remains as-is, with the false positives documented above intact and unfixed.

## Proposal: self-recording evidence, as a fresh task

Every attempt so far kept evidence as something *inferred from a string* - message text, then clause, then command line.
The class disappears when nothing has to be parsed at all: **the thing that actually ran writes its own record.**

The primitive already exists in this repo, twice:

- `bin/fm-glass.sh` writes `fm-state/last-glass-capture` from inside itself, only when it genuinely ran.
  Nothing infers a screenshot from prose.
- The crew kill guard prepends a shim directory to the shell `PATH` (`/tmp/fm-<task-id>/killguard-bin`) so a real invocation passes through firstmate's own wrapper (`docs/crew-kill-guard.md`).

Combining them: a small set of verification entrypoints - firstmate's own scripts directly, and `git` / `gh` / test runners through a PATH-prepended shim - each append their own evidence record when they actually execute.
The guard then reads records, never text.

**Why this removes the class instead of relocating it.**
There is no span to parse, so there is no boundary to leak across.
A record exists only as a side effect of real execution, so prose cannot forge one: no arrangement of message text, clause structure, or quoted shell argument can produce a record, because writing one requires having run the command.

**The known bypass, stated plainly rather than glossed.**
`docs/crew-kill-guard.md` records that an absolute utility path bypasses a PATH shim.
That limitation applies here too - `/usr/bin/git` would not be recorded.
The difference is the direction of the failure: a missed recording means the guard sees no evidence and **blocks**, producing a false positive, never a false clearance.
Every failure mode of this design degrades toward blocking.
That asymmetry is the whole argument for the seam, and it is the property none of the five attempts above had.

This is a fresh task built on the right seam from the start, not a sixth patch on the wrong one.
It should not be attempted as a continuation of the receipt rewrite.
It is tracked as `fm-claim-guard-self-recording-seam-b3`.

## Evidence transcript

Produced against the tracked guard in a primary-shaped temp home with a stale glass marker.

```text
## Trigger: bag-of-words conjunction, no binding
BLOCK  Captain, the Vellum crew is still working on the input-route fix; nothing to review yet.
allow  Captain, the crew is still working on the input-route fix; nothing to review yet.
allow  Captain, the Vellum crew is still chewing on the input-route fix; nothing to review yet.
BLOCK  Captain, I opened the dashboard bookmark you asked about. Separately, the login bug is fixed on the other branch.

## Three real catches (data/learnings.md:10), faithful renderings
BLOCK  Captain, the flock measurement is fixed - peer discovery settles in 200ms on the daily-driver.
allow  Captain, flock convergence is working now: 200ms across the containers.
BLOCK  Captain, the Vellum sendinput defect is fixed and the work is landed.
allow  Captain, that is done - the app fix is landed on main.
allow  Captain, the crew reproduced the defect - the Vellum terminal repaint bug is confirmed.
allow  Captain, reproduced - the dashboard is dropping the peer list on refresh.

## Minimal pair: identical text, opposite ground truth
BLOCK  Captain, the Vellum flake is fixed and checks passed.

## Guard blocks the two captain-mandated compliant shapes
BLOCK  Captain, the Vellum flake is fixed and checks passed (gh check-runs on 4a91c2f: all green).
BLOCK  Captain, the crew reports the Vellum flake is fixed; unverified, I have not reproduced it.
```
