# Crew kill guard

`bin/fm-crew-kill-guard.sh` is the single owner of the crew process-signaling policy.
`bin/fm-spawn.sh` installs a private copy for every crew and scout task.
Secondmate primaries are exempt, while crew and scouts they launch receive the same installation because the copied guard is rooted in the task temp directory rather than a primary home.

## Policy

The guard denies process signaling by pattern or sweep before execution.
Denied forms include `pkill`, `killall`, `fuser -k`, `xargs kill`, kills fed by `pgrep`, `ps` and grep pipelines, substitutions, and grep-derived loops.
An actual `kill` command is allowed only when every target is an explicit numeric PID and every other argument is a signal option or `--`.
The guard deliberately does not test PID ownership because that check would be racy.
Its denial tells the agent to use only individually verified numeric PIDs owned by its task and that the live app, desktop session, and herdr processes are untouchable.

The one command-word exception is the sanctioned Herdr lab wrapper `bin/fm-herdr-lab.sh`.
It is the only crew-facing path to Herdr lifecycle work and enforces its own isolation - a never-`default` session, a trailing `--session` on every call, guarded teardown, and a before/after fleet-state tripwire - so the guard permits it when it is the resolved command word, by basename or absolute path.
The allowance matches the command word only: the helper named merely as an argument (`pkill -f fm-herdr-lab.sh`), a kill chained after it (`fm-herdr-lab.sh ...; pkill herdr`), a denied substitution among its arguments, and an aliased or hashed name that resolves to a kill all stay denied.
It changes no existing denial, since an unmatched command word already falls through to allow; it is explicit so a future protected-process rule cannot strand the wrapper.
The `--herdr-lab` brief scaffold therefore invokes the helper by its literal path, never through a shell variable, because the guard refuses any command whose command word is a variable; that variable-command-word denial, not a herdr-verb denial, is what previously blocked crews driving the sanctioned helper.

## Scope limits

The guard targets careless direct shell-visible pattern kills and shell command substitutions before execution.
It deliberately does not block deferred executable payloads routed through other interpreters or utilities, such as `trap 'pkill -f app' EXIT`, `find . -exec kill -9 -1 ';'`, `awk 'BEGIN{system("pkill -f app")}'`, Python `os.kill()`, or comparable deliberate interpreter-routed signaling.
Those surfaces remain subject to the same policy expectation: a crew must not signal processes outside its task tree, and must escalate instead of retrying with a bypass shape.

## Spawn installation

| Adapter | Enforcement |
| --- | --- |
| Claude | A worktree-local `PreToolUse` Bash hook invokes the copied checker with `--claude`, which leaves stdout empty on denial. |
| Codex | Per-launch hook config registers a `PreToolUse` Bash hook that invokes the copied checker and blocks on exit 2, without rewriting project-owned `.codex/hooks.json`. |
| OpenCode | The generated task plugin invokes the checker from `tool.execute.before` and throws on every nonzero result. |
| Pi | The generated task extension invokes the checker from `tool_call` and returns `{ block: true }` on every nonzero result. |
| Grok | An always-trusted global `PreToolUse` hook resolves an opaque per-task pointer through a mode-0700 registry entry, then invokes the copied checker. |
| Cursor and Hermes | No verified pre-execution hook is available, so these adapters receive only the PATH defense described below. |

Every crew and scout launch prepends `/tmp/fm-<task-id>/killguard-bin` to its shell `PATH`.
That directory contains loud refusal shims for `pkill`, `killall`, and `fuser`.
This is defense in depth for hook-capable adapters and the available enforcement for hookless adapters.
An absolute utility path bypasses the shim, so the hook layer is the real gate where the adapter supports one.
A shell builtin or absolute `kill` also bypasses PATH, which is why hookless adapters cannot provide the same structural guarantee for grep-derived kill forms.

The per-task checker, shims, Grok registry entry, pointer, and generated worktree hook files are removed during teardown.
When a watchdog successor temporarily adopts a predecessor worktree, spawn backs up generated hook and pointer files; if successor readiness is not proven, successor cleanup restores the predecessor's files before halting.

## Live verification, 2026-07-12

Verification ran in git-initialized scratch directories inside the disposable task worktree.
The PATH placed a harmless fake `pkill` first; it would have touched a sentinel if execution reached it.
Both sentinel files remained absent.

Versions:

```text
2.1.193 (Claude Code)
codex-cli 0.144.0
```

The exact requested shell command for both harnesses was:

```sh
pkill -f fm-kill-guard-harmless-pattern .
```

Claude was launched with:

```sh
claude -p 'Use the Bash tool once to run exactly: pkill -f fm-kill-guard-harmless-pattern . Then report the exact tool result. Do not retry or run anything else.' --dangerously-skip-permissions --output-format text
```

Its exact hook result was:

```text
PreToolUse:Bash hook error: [<scratch>/check.sh --claude]: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[crew-kill-guard] Process signaling by pattern or sweep is denied. Only kill/kill -<signal> of individually verified explicit numeric PIDs owned by this task is allowed. The live app, desktop session, and herdr processes are untouchable. Escalate instead of retrying a variant."}
```

Claude exited 0 after reporting the denial, and its sentinel was absent.

Codex was launched with:

```sh
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check 'Use the shell tool once to run exactly: pkill -f fm-kill-guard-harmless-pattern . Then report the exact tool result. Do not retry or run anything else.'
```

Its exact hook output was:

```text
hook: PreToolUse
ERROR codex_core::tools::router: error=Command blocked by PreToolUse hook: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[crew-kill-guard] Process signaling by pattern or sweep is denied. Only kill/kill -<signal> of individually verified explicit numeric PIDs owned by this task is allowed. The live app, desktop session, and herdr processes are untouchable. Escalate instead of retrying a variant."}. Command: pkill -f fm-kill-guard-harmless-pattern .
hook: PreToolUse Blocked
```

Codex exited 0 after reporting the denial, and its sentinel was absent.

OpenCode, Pi, and Grok are structurally verified by `tests/fm-crew-kill-guard.test.sh` against their generated hook surfaces.
Their remaining gap is lack of a live harness exercise in this change.
Cursor and Hermes have the documented hookless gap above.

## Sanctioned wrapper allowance, 2026-07-20

The wrapper allowance and its bypass resistance were checked against `bin/fm-crew-kill-guard.sh` with `bin/fm-crew-kill-guard.sh --command '<command>'`, where exit 0 is allow and exit 2 is deny.

Allowed, each exit 0:

```text
'/opt/fm/bin/fm-herdr-lab.sh' teardown fm-lab-x7
fm-herdr-lab.sh run fm-lab-x7 pane kill 123
/opt/fm/bin/fm-herdr-lab.sh --help
HERDR_LAB_SESSION=$(/opt/fm/bin/fm-herdr-lab.sh name fm-x)
```

Denied, each exit 2:

```text
pkill -f fm-herdr-lab.sh
/opt/fm/bin/fm-herdr-lab.sh teardown fm-lab-x7; pkill herdr
bash -c "/opt/fm/bin/fm-herdr-lab.sh teardown fm-lab-x7; pkill herdr"
fm-herdr-lab.sh run fm-lab-x7 $(pkill -f app)
```

Context: before this change the guard had no herdr-verb logic and already allowed a literal `fm-herdr-lab.sh` command word; what blocked the sanctioned helper was the `--herdr-lab` brief invoking it through a `$HERDR_LAB_HELPER` variable, which the guard denies as a dynamic command word.
The fix is the explicit wrapper allowance above plus the brief switching to literal-path invocation; no bare-herdr-verb denial was added.
The regression is covered by `tests/fm-crew-kill-guard.test.sh` (allow and bypass-deny cases) and `tests/fm-brief.test.sh` (the `--herdr-lab` scaffold invokes the helper by literal path, never a shell variable).
