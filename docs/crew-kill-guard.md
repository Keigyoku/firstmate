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

## Spawn installation

| Adapter | Enforcement |
| --- | --- |
| Claude | A worktree-local `PreToolUse` Bash hook invokes the copied checker with `--claude`, which leaves stdout empty on denial. |
| Codex | A worktree-local `PreToolUse` Bash hook invokes the copied checker and blocks on exit 2. |
| OpenCode | The generated task plugin invokes the checker from `tool.execute.before` and throws on every nonzero result. |
| Pi | The generated task extension invokes the checker from `tool_call` and returns `{ block: true }` on every nonzero result. |
| Grok | An always-trusted global `PreToolUse` hook resolves an opaque per-task pointer through a mode-0700 registry entry, then invokes the copied checker. |
| Cursor and Hermes | No verified pre-execution hook is available, so these adapters receive only the PATH defense described below. |

Every crew and scout launch prepends `/tmp/fm-<task-id>/killguard-bin` to its shell `PATH`.
That directory contains loud refusal shims for `pkill`, `killall`, and `fuser`.
This is defense in depth for hook-capable adapters and the available enforcement for hookless adapters.
An absolute utility path bypasses the shim, so the hook layer is the real gate where the adapter supports one.
A shell builtin or absolute `kill` also bypasses PATH, which is why hookless adapters cannot provide the same structural guarantee for grep-derived kill forms.

The per-task checker, shims, Grok registry entry, pointer, and generated hook files are removed during teardown.

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
