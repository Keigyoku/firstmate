# Primary turn-end supervision guard

This is the authoritative contract for the "no turn ends blind" primary guard referenced from AGENTS.md section 8.
The shared predicate lives in `bin/fm-turnend-guard.sh`.
Harness-specific tracked hook files only adapt each verified harness's real turn-end mechanism to that shared predicate.
A related but separate guard, the pre-arm PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`), denies a bad watcher-arm command shape before it runs rather than detecting a blind turn end afterward.
A separate PreToolUse fence (`bin/fm-subagent-pretool-check.sh`, `docs/subagent-guard.md`) blocks primary-session delegation tools that would create unsupervised work outside the fleet.
A related Bash PreToolUse seatbelt (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`) denies persistent top-level shell directory changes in the primary.

## Gap Closed

`bin/fm-guard.sh` is pull-based: it warns whenever some other supervision script happens to run, and prints nothing otherwise.
The primary can otherwise end a turn after handling wakes without resuming supervision, then sit blind until another fleet command happens to run.
On 2026-07-04, that exact gap left a parked no-mistakes gate unwatched for about nine hours.

`bin/fm-turnend-guard.sh` closes the gap by checking the primary's own turn-end path.
When tasks are in flight and there is no live identity-matched watcher with a fresh beacon, or already-delivered wakes remain queued, a harness hook must either block the turn end or force a bounded follow-up turn that tells the primary to resume the session-start supervision protocol for its harness.

## Shared Predicate

The guard first scopes itself to a real primary checkout.
When `CLAUDE_PROJECT_DIR` is empty, it falls back to the hook process's physical working directory only after verifying that directory contains `AGENTS.md` and `bin/fm-turnend-guard.sh`.
A secondmate home runs its own primary firstmate session, so a genuine `.fm-secondmate-home` marker force-includes it whether treehouse leased it as a linked worktree or it is a git-cloned plain checkout.
The marker must be a regular non-symlink file whose first line, after all whitespace is removed, contains a non-empty identifier made only of letters, digits, dots, underscores, and dashes (validated under C collation via `bin/fm-primary-scope-lib.sh`).
An unmarked checkout, or one with an invalid marker, falls through to the git-dir check.
That check keeps crewmate and scout worktrees inert because firstmate provisions them as linked git worktrees, where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`.
It also requires `AGENTS.md`, `bin/`, and the effective state directory to exist.

For an in-scope primary checkout, it counts in-flight work from `state/*.meta`.
If no task is in flight, it exits silently.
If work is in flight, it requires `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
That is the same identity-matched live lock and fresh beacon check used by `bin/fm-watch-arm.sh`.
Home and watcher paths are compared by physical identity so logical and physical spellings of the same symlinked directory match.
A stale beacon blocks even if a watcher pid is still live.
A fresh leftover beacon blocks if the watcher lock is missing, dead, or identity-mismatched.
The watcher lock is published by the generic singleton helper before `fm-watch.sh` adds its home, path, and process-identity fields.
The turn-end guard therefore gives a live holder with a fresh beacon and a newly published lock one bounded second to finish those fields, then applies the same identity checks again.
It does not wait for a dead holder, stale beacon, or older identity mismatch.
Pending records in `state/.wake-queue` block the turn end even when the watcher itself is healthy, so the primary must drain already-delivered work before stopping.

Whenever the guard blocks, it appends the complete decision inputs and individual predicate verdicts to the size-capped, gitignored `fm-state/turnend-guard-diagnostics.log`.
The record includes the relevant hook environment, resolved roots, lock contents and physical paths, PID liveness and identity, beacon mtime and age, and queue and watcher verdicts.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repo-root `state/`.
`FM_GUARD_GRACE` controls the beacon freshness window and defaults to 300 seconds.
`FM_TURNEND_LOCK_SETTLE` controls the bounded lock-publication settle window and defaults to 1 second.
The local gitignored file `config/turnend-guard` disables the guard only when its value is exactly `off`.
If `jq` is missing or hook stdin is empty, the guard fails open and exits 0 because it cannot safely read loop-guard fields.

## Harness Integrations

All verified primary harnesses have a tracked integration:

- `claude`: `.claude/settings.json` registers a `Stop` hook command anchored through `CLAUDE_PROJECT_DIR`, with the same verified physical-working-directory fallback as the shared guard.
- `codex`: `.codex/hooks.json` registers a `Stop` hook that reads the hook payload once, anchors the executable to the hook command process working directory, verifies that root is firstmate-shaped and hook-bearing, and pipes the original payload to that checkout's `bin/fm-turnend-guard.sh`.
- `opencode`: `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`, lets the watcher-arm coordinator handle normal idle supervision first, runs the shared guard only when that coordinator does not act, and uses `client.session.promptAsync` to force one follow-up prompt when the guard returns 2.
- `pi`: `.pi/extensions/fm-primary-turnend-guard.ts` listens for `agent_settled`, marks the extension version loaded for session-start checks, runs the shared guard once per logical agent run, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one follow-up prompt when the guard returns 2.
- `grok`: `.grok/hooks/fm-primary-turnend-guard.json` registers a `Stop` hook that invokes `bin/fm-turnend-guard-grok.sh`.
  The adapter runs the shared guard and, when it returns 2, invokes `grok --resume <sessionId> -p <guard-reason>` with `GROK_TURNEND_GUARD_ACTIVE=1`.
  It does not pass `--permission-mode`, so the passive Stop hook cannot grant stronger tool permissions than Grok's resumed-session default.

Claude and Codex support a direct blocking Stop hook.
For those harnesses, exit status 2 plus stderr from `bin/fm-turnend-guard.sh` blocks the stop and feeds the reason back into the model.
Both payloads include `stop_hook_active`; when it is true, the shared guard exits 0 so the harness can end after one forced continuation.

OpenCode, Pi, and Grok expose passive lifecycle callbacks for this purpose.
Their adapters fail open at the hook boundary to avoid corrupting a user session, but they force one follow-up turn when the shared predicate blocks.
Each adapter carries its own in-process or environment loop guard so the forced follow-up does not recursively schedule another follow-up.
Pi keeps that latch active across every internal tool turn and clears it only when the generated guard follow-up reaches `agent_settled`, or immediately when follow-up delivery fails.
If a passive adapter cannot call its SDK method, cannot find `grok`, or cannot recover the Grok session id, it fails open and relies on the pull-based `fm-guard.sh` warning at the next fleet command.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it points back to the active harness protocol instead of hardcoding one background-arm command.

## Empirical Validation

All harnesses were validated on 2026-07-08 in scratch repos or throwaway homes, not against the captain's live primary fleet state.

The residual Claude false-positive fix was validated on 2026-07-12 in a disposable primary-shaped clone and home with Claude Code 2.1.193.
The hermetic reproduction command was `bash tests/fm-turnend-guard.test.sh`.
Its hook-context regression invokes the tracked Stop command shape through `/bin/sh`, starts with a fresh beacon and a live lock PID whose watcher-specific fields are still being populated, and publishes those fields 0.2 seconds later.
Before the bounded settle recheck, that state made `fm_watcher_lock_matches_pid` fail on the temporarily absent fields and produced the false banner.
Observed fixed output was `ok - fm-turnend-guard: Claude /bin/sh Stop context tolerates live lock publication`.
The same run observed `ok - fm-turnend-guard: pending wakes block and produce a self-explaining diagnostic`, while the existing dead-PID and stale-beacon cases continued to block.

The real healthy-hook validation started the tracked watcher in the scratch clone with `bin/fm-watch-arm.sh`, created `state/live-test.meta`, and ran `claude -p 'Reply with exactly OK.' --model haiku --dangerously-skip-permissions --output-format json`.
Observed watcher startup output was `watcher: started pid=3474163 (beacon fresh)`.
Observed Claude output had `subtype=success`, `num_turns=1`, `result=OK`, `stop_reason=end_turn`, and model `claude-haiku-4-5-20251001`; no guard banner or warning diagnostic was produced.
The watcher was allowed to exit naturally after `printf 'failed: scratch watcher exit signal\n' > state/live-test.status`.
Observed watcher output was `signal: <scratch>/repo/state/live-test.status`.

The real blind-hook validation removed the scratch watcher lock, retained in-flight metadata, and ran `claude -p 'Reply with exactly OK. Do not use tools.' --model haiku --dangerously-skip-permissions --output-format json`.
The warning diagnostic recorded `env.CLAUDE_PROJECT_DIR=<scratch>/repo`, `env.FM_HOME=<unset>`, `env.PWD=<scratch>/repo`, and `cwd=<scratch>/repo`.
It also recorded `pid.alive=false`, `predicate.in_flight=2`, `predicate.beacon_fresh=true`, `predicate.queue_pending=false`, and `predicate.watcher_healthy=false`, proving that the genuine blind condition still reached the blocking path in an actual Claude Stop hook.

Claude Code 2.1.204 preserved the existing behavior.
Hook file used: `.claude/settings.json`.
Command run: `claude -p "Say hi in exactly one word." --dangerously-skip-permissions --output-format json` with a scratch Stop hook that printed `SMOKETEST: you must say the word BANANA before stopping` and exited 2.
Observed output: the first stop payload had `stop_hook_active=false`, the stop was blocked, the model continued with `BANANA`, and the second stop payload had `stop_hook_active=true` and was allowed.
Earlier validation on 2026-07-04 also verified that `CLAUDE_PROJECT_DIR` is set to the settings-loaded project root, while the hook command itself runs from the session cwd.

Codex `codex-cli 0.142.1` was validated with a scratch `.codex/hooks.json` Stop hook.
Hook file used: `.codex/hooks.json`.
Command run: `codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Say hi in exactly one word.'`.
Observed output: the first model output was `Hi`, the Stop hook exited 2, Codex logged `hook: Stop Blocked`, the model continued with `CODEXHOOK`, and the second hook call had `stop_hook_active=true`.
The Stop payload included `cwd`.
Command run for root-signal probe: `codex exec --ephemeral --json --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Use the shell tool to run mkdir -p outside && cd outside && pwd, then use the shell tool again to run pwd. Your final answer must include the two observed outputs.'`.
Observed output: the first command printed `<scratch>/outside`, the second command printed `<scratch>`, the Stop hook process `pwd -P` printed `<scratch>`, payload `cwd` printed `<scratch>`, and `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, and `CODEX_CWD` were empty.
The tracked command therefore treats hook process PWD as the hook-loaded firstmate root and does not let payload `cwd` choose an executable.
It still passes the original payload to `bin/fm-turnend-guard.sh`, so the shared loop guard reads `stop_hook_active`.

OpenCode 1.17.6 was validated with project plugins under scratch `.opencode/plugins/`.
Hook file used: `.opencode/plugins/fm-smoke.js` for throw testing and `.opencode/plugins/fm-primary-turnend-guard.js` for follow-up testing.
Command run for passive behavior: `opencode run --print-logs --log-level DEBUG --dangerously-skip-permissions 'Say hi in exactly one word.'`.
Observed output: the plugin received `session.idle`, threw an error, and `opencode run` still exited 0 with `Hi`, proving `session.idle` cannot block directly.
Command run for follow-up behavior: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Say hi in exactly one word.' --print-logs --log-level INFO`.
Observed output: the plugin called `client.session.promptAsync`, the TUI ran a second turn, and the second model output contained `OPENCODEHOOK`.
In noninteractive `opencode run`, `promptAsync` returned successfully but the process exited before displaying the follow-up, so this adapter is trusted for primary TUI sessions and documented as passive/fail-open in headless mode.

Pi 0.80.5 was re-validated on 2026-07-09 in a disposable primary-shaped clone with isolated `PI_CODING_AGENT_DIR`, isolated `FM_HOME`, and tmux socket `fm-pi-q6-lab`.
Hook files used: the tracked `.pi/extensions/fm-primary-turnend-guard.ts` and `.pi/extensions/fm-primary-pi-watch.ts`.
Commands run inside separate interactive turns: `printf PI_E2E_BASH_ONE` through Pi's bash tool, `README.md:1-5` through Pi's read tool, and `printf PI_E2E_BASH_TWO` through Pi's bash tool.
Command used to make the shared predicate unhealthy: `: > "$FM_HOME/state/pi-e2e.meta"`.
The next no-tool prompt produced exactly one `TURN WOULD END BLIND` follow-up, and that follow-up called `fm_watch_arm_pi` once with output `watcher: started Pi extension arm child 1`.
The three earlier tool turns produced no guard follow-up because no work was in flight.
Command used to fire the watcher: `printf 'done: pi e2e watcher fire\n' > "$FM_HOME/state/pi-e2e.status"`.
Observed output after the wake: Pi ran `bin/fm-wake-drain.sh`, read the terminal status, called `fm_watch_arm_pi`, and rendered `watcher: started Pi extension arm child 2`.
The complete pane contained one guard message and zero foreground `bin/fm-watch-arm.sh` bash calls.
`/quit` printed `PI_EXIT=0`, and the second arm process plus its watcher child were both gone afterward.

Grok 0.2.91 was validated with a scratch `GROK_HOME` and symlinked auth/config.
Hook file used for tracked project-hook loading: `<scratch-project>/.grok/hooks/fm-smoke.json`, matching the tracked `.grok/hooks/fm-primary-turnend-guard.json` location.
Command run for project-hook loading: `GROK_HOME="$scratch/grok-home" grok --trust -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the project Stop hook fired under `--trust` and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`.
Hook file used for passive behavior and forced-resume behavior: `$GROK_HOME/hooks/fm-primary-turnend-guard.json` plus `bin/fm-turnend-guard-grok.sh`.
Command run for passive behavior: `GROK_HOME="$scratch/grok-home" grok -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the global Stop hook fired and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`, but exiting 2 did not make the model continue.
Command run for forced resume behavior: the Stop hook ran `GROK_TURNEND_GUARD_ACTIVE=1 GROK_HOME="$scratch/grok-home" grok --resume "$session_id" -p 'SMOKETEST: say exactly GROKRESUMEHOOK...' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the outer turn printed `Hi`, the nested resumed turn printed `GROKRESUMEHOOK`, and the nested Stop hook saw `GROK_TURNEND_GUARD_ACTIVE=1` and did not recurse.
That validation command used `--permission-mode bypassPermissions` only to keep the scratch smoke unattended; the tracked adapter intentionally omits `--permission-mode`.
Project-local Grok hooks did not fire in scratch single mode without a trust grant.
The primary integration therefore requires the primary firstmate checkout to be trusted for Grok hooks, which can be done with `/hooks-trust` or launch-time `--trust`.
If Grok declines to load project hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.

**2026-07-09 update:** grok 0.2.93 broke the `.grok/hooks/fm-primary-turnend-guard.json` Stop hook with `hook not executed: required env var(s) not set: ${root}`, because grok's own `${VAR}` expansion over the raw `command` string does not tolerate a bare local variable assigned earlier in the same `bash -lc` script.
The hook command was fixed to reference `${GROK_WORKSPACE_ROOT:-}` directly everywhere instead of assigning it to `$root` first, and re-validated against grok 0.2.93 to fire and complete cleanly.
See `docs/arm-pretool-check.md`'s "Harness wiring" section for the same Grok expansion requirement; that document's Grok hook shares the same fix.

### Secondmate-home enablement (upstream #505)

A genuinely marked secondmate home is force-included as a guarded primary.
Only unmarked child worktrees fall through to the linked-worktree exemption.
Hermetic coverage lives in `tests/fm-turnend-guard.test.sh` (`test_hook_blocks_in_secondmate_own_home`, `test_hook_blocks_in_treehouse_leased_secondmate_home`, idle/loop/recovery and marker anti-spoof cases).
Physical-identity matching and the settled healthy predicate remain the fork's private turnend evolution and must not regress when this scope widens.

## Tests

`tests/fm-turnend-guard.test.sh` covers the shared predicate, primary scoping, unset `CLAUDE_PROJECT_DIR` fallback, physical identity matching for symlinked home paths, the bounded watcher-lock publication settle window, pending-wake blocking diagnostics, local `config/turnend-guard` disable behavior, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, Pi logical-run latch behavior for no-tool and multi-tool runs, fail-open behavior without `jq`, tracked hook registration for all five harnesses, and the Grok adapter's forced-resume loop guard and permission-mode regression.
The default behavior suite does not invoke live language-model harnesses.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` opts into the isolated interactive Pi regression recorded above.

## Claim-vs-evidence coaching reminder

**This is a reminder, not a gate.** `bin/fm-claim-guard.sh` always exits 0 and never blocks a turn.
Nothing at this hook point can stop an unevidenced claim from reaching the captain, so the guard does not pretend to.
It records one short coaching line, and `bin/fm-claim-coach-inject.sh` delivers it at the start of the next turn so the primary self-corrects.

Do not restore blocking here.
The next section is the measurement showing why it cannot work.

### Why a gate is not achievable at this hook point

A `Stop` hook fires when the turn ENDS - after the assistant message is already written and displayed.
It cannot suppress anything.
Exiting 2 only refuses to let the turn finish, which forces a second message, and the guard's own former remedy text said "resend the claim".
So the unverified claim reached the captain 100% of the time and the guard DUPLICATED it rather than preventing it: the same paragraph twice with a block banner between.

That is precisely the defect class this guard exists to catch - a detector running after the effect it is meant to prevent, reporting enforcement while the harm already happened - previously sitting inside the enforcement mechanism itself.

Measured on Claude Code with `--model haiku`, in a scratch repo with a Stop hook printing distinct tokens to both streams and exiting 0:

- `num_turns=1`; exit 0 correctly forces no continuation.
- Resuming that session and asking the model whether it saw either token returned `NEITHER`.
- The transcript JSONL confirmed it independently: the tokens appear only in `hook_success` attachment rows, carrying `{"stdout":"...","stderr":"..."}`. The session's only `hook_additional_context` row came from `SessionStart`, not from the Stop hook.
- The same lab with a `UserPromptSubmit` hook printing a token on exit 0: the model quoted that token straight back.

**A Stop hook that exits 0 is recorded in the transcript but is never injected into the model's context.**
`UserPromptSubmit` stdout on exit 0 is.
That is the whole reason this is a two-hook design: a single Stop hook can either block (duplicating the claim) or be silent to the agent. Neither is coaching.

### Components

- `bin/fm-glass.sh` is the canonical capture entrypoint.
  It runs `spectacle -b -n -f -o <out>`, prints the absolute capture path, and writes `fm-state/last-glass-capture` as `epoch path`.
  Missing spectacle or a missing Wayland socket degrades with a clear stderr error and exit 1.
- `bin/fm-claim-guard.sh` RECORDS on the primary `Stop` path. Always exit 0.
- `bin/fm-claim-coach-inject.sh` DELIVERS on the primary `UserPromptSubmit` path. Always exit 0, prints at most one line.

### Scope and disable

`.fm-secondmate-home` homes and linked worktrees stay inert; `AGENTS.md`, `bin/`, and the state directory are required.
The injector applies those checks before inspecting pending state, so an out-of-scope invocation leaves the record untouched for the primary.
`stop_hook_active=true` records nothing, so at most one line is produced per turn.
`config/claim-guard` exactly `off` disables both halves.
`FM_CLAIM_GLASS_MAX_AGE` (default 900s) is the glass freshness window; `FM_CLAIM_COACH_MAX_AGE` (default 1800s) is how long a recorded reminder stays deliverable.

### Detection, deliberately coarse

Because a hit now costs one reminder line instead of a round trip, the predicate no longer has to be precise, and noticing too often is cheap.
There is **no** clause splitting, mood exclusion, or quoted-span parsing.
Those existed only to avoid false blocks, and each one leaked evidence across its own span boundary.

A line is recorded when the final assistant text asserts state AND carries none of:

1. A source receipt - a URL, `file.ext:line`, a backticked command or path, or a 7-40 character hex sha containing at least one digit.
2. An explicit unverified/attribution marker, the shape `data/captain.md` mandates when no receipt exists.
3. For rendered-app claims only (`renders`/`rendering`/`rendered`, `adopted`, `booted clean`, `came up clean`), a fresh glass capture.

Glass clears a rendered-state claim and nothing else, so a recent screenshot never silences an unrelated CI or repo claim.
When a whole message contains both a rendered-state assertion and any non-rendered state assertion, the glass exemption is withheld and receipt-kind coaching is recorded.
This mixed-kind check is one flat whole-message match over the existing assertion vocabulary and does not locate or parse clauses.

The recorded line names the instrument that can actually evidence THAT kind of claim: glass for rendered app state, and a cited receipt for everything else.
A screenshot is the wrong instrument for a code, CI, or repo claim.

### The pending record, and why it cannot go stale

`fm-state/claim-coach-pending` holds `{session_id, epoch, line}`.

The injector consumes the record whenever it looks at one - delivering it or discarding it - so nothing is ever left to rot.
Delivery requires BOTH:

- **Same session.** Both the recorded and current session ids must be non-empty and equal; otherwise the record is discarded unshown.
  This stops a missing id, unrelated session, or newly resumed session with a different id from inheriting a nudge.
- **Still fresh.** Older than `FM_CLAIM_COACH_MAX_AGE` is discarded unshown. This covers the same session resumed much later, where the id still matches but the claim is long out of view.

If the session simply ends and the next prompt never comes, the record is scoped to a session that will not return and expires by time regardless.
A reminder about a claim nobody remembers is worse than no reminder, because it teaches the reader to ignore the channel.

### Claude hook composition

`.claude/settings.json` runs the supervision guard then the claim recorder on `Stop`, and the injector on `UserPromptSubmit`.
Only `bin/fm-turnend-guard.sh` can still block a turn; the claim path never does.

### Tests

`tests/fm-claim-guard.test.sh` covers: an unevidenced claim records coaching and never blocks; the non-rendered line does not prescribe a screenshot; receipted, attributed and non-claim messages record nothing; fresh glass clears only a rendered-only claim; mixed rendered and CI claims still require a receipt; `stop_hook_active`; missing transcript; transcript fallback; non-primary scope; `config/claim-guard=off`; the composed Stop shape; settings registration of BOTH hooks; and for the injector - delivers and clears, requires two non-empty equal session ids, never surfaces another session's line, never surfaces an expired line, leaves out-of-scope pending state untouched, and stays silent with nothing pending.

### Empirical validation (2026-07-29)

End-to-end on the live Claude harness in a throwaway primary-shaped home, `--model haiku`, with the tracked scripts and tracked hook wiring.

Turn 1, prompted to emit `Captain, the login defect is fixed and checks passed.`:

```text
num_turns=1        # never blocked, no duplicated message
fm-state/claim-coach-pending:
{"session_id":"28daab2b-...","epoch":1785348591,"line":"claim-coach: last turn asserted state with no receipt - cite a URL, file.ext:line, a backticked command, or a commit sha, or mark the claim unverified."}
```

Turn 2, resuming the same session and asking whether any `claim-coach` text was injected - the model returned the line verbatim:

```text
claim-coach: last turn asserted state with no receipt - cite a URL, file.ext:line, a backticked command, or a commit sha, or mark the claim unverified.
```

The pending record was cleared after delivery.
Both halves are therefore measured: the turn is never blocked, and the reminder actually reaches the agent that can act on it.

`bin/fm-glass.sh` was smoke-tested on the live desktop with spectacle 6.7.1:
`spectacle -b -n -f -o /tmp/fm-glass-smoke-*.png` produced a 7681x2161 PNG and wrote `fm-state/last-glass-capture` as `epoch path`.
