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

## Claim-vs-evidence glass guard

Captain-facing daily-driver app state (render / working / adopted) is proven only by a screenshot of the live desktop glass, never by logs, process census, ports, or API responses.
Prose rules in `data/captain.md` and `data/learnings.md` failed three sessions running because they are advisory at message-composition time.
This section owns the mechanical enforcement layer that closes that gap.

### Components

- `bin/fm-glass.sh` is the canonical capture entrypoint.
  It runs the proven host command `spectacle -b -n -f -o <out>` with `XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` defaulting to the ambient session (or `/run/user/$(id -u)` and `wayland-0`).
  It prints the absolute capture path and writes `fm-state/last-glass-capture` as `epoch path`.
  Missing spectacle or a missing Wayland socket degrades with a clear stderr error and exit 1 (SSH, headless, secondmate homes without a desktop).
- `bin/fm-claim-guard.sh` is the claim-vs-evidence check on the primary Stop-hook path.
  It is a separate script so it does not bloat the supervision predicate; both compose on the same Claude Stop hook.

### Scope and loop guard

Unlike `bin/fm-turnend-guard.sh`, the claim guard retains the narrower main-primary Stop scope: `.fm-secondmate-home` and linked worktrees are inert, while `AGENTS.md`, `bin/`, and the state directory are required.
`stop_hook_active=true` always allows the stop so at most one block fires per turn (shared loop-guard contract with the supervision guard).
`config/claim-guard` exactly `off` disables only this check; absent or any other value leaves it enabled.
`FM_CLAIM_GLASS_MAX_AGE` (default 900 seconds) is the freshness window for `fm-state/last-glass-capture`.

### Claim heuristic

The guard prefers the Stop payload field `last_assistant_message` (Claude Code 2.1.x supplies it on every Stop event).
It falls back to `transcript_path` JSONL only when that field is empty, because the transcript often still lacks the final assistant row at hook time.
Missing, unreadable, or empty message content fails open.
A message is an app-state claim only when BOTH of the following match case-insensitively in that text:

1. An app referent: `vellum`, `daily-driver` / `daily driver`, `the app`, `dashboard`, `glass`, `resident`.
2. A health/state assertion: `work` / `works` / `working`, `render` / `renders` / `rendering` / `rendered`, `adopted`, `booted clean`, `came up clean`, `is up`, `healthy`, `fixed`, `live`.

Both classes are required so pure fleet status ("crew is working") and pure referent mentions ("open the dashboard") do not block.
Word boundaries keep incidental substrings such as `hourglass` out.

### Evidence check

When a claim matches, the guard requires `fm-state/last-glass-capture` with a numeric epoch whose age is within `FM_CLAIM_GLASS_MAX_AGE`.
Missing, malformed, or stale markers block.
Blocking stderr names the remedy: run `bin/fm-glass.sh`, read the image, cite the path, resend the claim.

### Claude Stop-hook composition

`.claude/settings.json` runs the shared supervision guard first, then the claim guard when present:

```sh
payload=$(cat); root=${CLAUDE_PROJECT_DIR:-$(pwd -P)};
if [ -f "$root/AGENTS.md" ] && [ -f "$root/bin/fm-turnend-guard.sh" ]; then
  printf '%s' "$payload" | "$root/bin/fm-turnend-guard.sh" || exit $?;
  if [ -f "$root/bin/fm-claim-guard.sh" ]; then
    printf '%s' "$payload" | "$root/bin/fm-claim-guard.sh";
  fi;
fi
```

Either guard may exit 2; `stop_hook_active` ensures only one forced continuation per turn.
Codex / OpenCode / Pi / Grok adapters are unchanged by this addition (Claude is the daily primary); wiring other harnesses is a follow-up.

### Tests

`tests/fm-claim-guard.test.sh` covers: claim + no/stale evidence blocks; claim + fresh evidence allows; no-claim allows; `stop_hook_active` allows; missing transcript fails open; non-primary scope allows; local `config/claim-guard=off`; composed Stop-hook shape; settings registration; and `fm-glass.sh` marker recording with a stub spectacle.

### Empirical validation (2026-07-20)

Validated on the real Claude harness in a throwaway primary-shaped home under `/tmp/fm-claim-live.*`, not the captain's live fleet state.

- Claude Code: `2.1.193`
- Model: `claude-haiku-4-5-20251001` via `claude -p ... --model haiku --dangerously-skip-permissions --output-format json`
- Scratch layout: plain `git init` primary-shaped repo with tracked `bin/fm-claim-guard.sh`, `bin/fm-turnend-guard.sh`, and a Stop hook that logs `stop_hook_active` / `claim_exit` then runs both guards with `FM_HOME` pointed at the throwaway home.

**RUN1 — stale glass marker (epoch 1577836800):**

```text
stop_active=false msg=Captain, the vellum dashboard is rendering and working.
claim_exit=2
stop_active=true msg=Stop hook executed successfully with no errors. Ready for your next task.
claim_exit=0
```

Observed Claude result: `num_turns=2`, first stop blocked with the `UNVERIFIED APP-STATE CLAIM` banner naming `bin/fm-glass.sh`, second stop allowed via `stop_hook_active=true`.

**RUN2 — fresh glass marker (epoch = now):**

```text
stop_active=false msg=Captain, the vellum dashboard is rendering and working.
claim_exit=0
```

Observed Claude result: `num_turns=1`, claim allowed without a forced continuation.

**Transcript race note:** on the same host, dumping the JSONL at first Stop showed `assistant_types=0` while `last_assistant_message` already held the claim text.
That is why the guard prefers `last_assistant_message` and only falls back to transcript JSONL.

`bin/fm-glass.sh` was also smoke-tested on the live desktop with spectacle 6.7.1:
`spectacle -b -n -f -o /tmp/fm-glass-smoke-*.png` produced a 7681x2161 PNG and wrote `fm-state/last-glass-capture` as `epoch path`.
