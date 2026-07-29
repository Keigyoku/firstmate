# Claim guard false-positive diagnosis (2026-07-29)

Diagnosis only.
No production behavior was changed by this document.
`docs/turnend-guard.md` remains the owner of the claim-guard contract.

This records why `bin/fm-claim-guard.sh` blocked three consecutive primary turns on 2026-07-29, and why the fix requested in the task brief is not implementable as specified.

## Method

All verdicts below were produced by piping payloads into the real tracked `bin/fm-claim-guard.sh` inside a primary-shaped temp home with a stale glass marker.
No regex was read forward into a conclusion; every claim here is an observed exit status.
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
Catch 2 blocks in one phrasing and passes in two others.
Recall is near zero; the precision that produced three good catches was luck.

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

## Options, for the decision this needs

- **A. Narrow to glass-only vocabulary.** Drop the ambiguous assertions (`works`, `working`, `fixed`, `live`, `healthy`, `is up`) and keep only unambiguously-rendered ones (`renders`, `rendering`, `rendered`, `adopted`, `booted clean`, `came up clean`). The false positives vanish and the guard becomes exactly what its banner and remedy already claim. It loses all three catches, which were luck and were given the wrong remedy anyway. Smallest change; honest interface.
- **B. Receipt predicate.** Replace "is this an app-state claim" with "does this captain-facing assertion carry a source receipt or an explicit unverified/attribution marker?", which is `data/captain.md:46` verbatim. Catches all three real instances by principle rather than luck, clears the false positives because receipted claims pass, and rewards the exact shapes the guard currently punishes. Widens the firing surface substantially and rewrites the contract and remedy text.
- **C. Evidence-kind seam.** Classify claim to required evidence kind, add per-kind evidence channels on the existing PreToolUse stack (a marker when the turn ran `git ls-remote`, a check-runs query, or a repro command), then match kind to kind. A genuine second adapter at a real seam. Largest build; substantial rewrite of `docs/turnend-guard.md`.

Recommendation is B with A's vocabulary correction folded in, because B enforces what the captain already wrote down and converts the guard from luck-based to principle-based.
The choice is not the crewmate's to make: all three change a documented contract on the captain's daily driver, and B and C widen when the primary gets blocked.

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
