# Watchdog W2 Live Evidence

Date: 2026-07-08.
Worktree: `<home>/.treehouse/firstmate-7bab20/1/firstmate`.
Claude Code: `2.1.193`.
tmux: `3.6b`.

The live gate used a scratch tmux session named `fm-w2-live-2-957334`.
The scratch session ran `claude --dangerously-skip-permissions` from this disposable worktree.
The watcher was run with `FM_HOME` and `FM_ROOT_OVERRIDE` both set to this worktree.
The local scratch config set `compact_at_context_pct` to `1` and was removed after the run.
No primary firstmate home state or watcher lock was used.

The watcher command was:

```sh
FM_HOME="$PWD" FM_ROOT_OVERRIDE="$PWD" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=9999 FM_HEARTBEAT=9999 FM_STEER_BACKOFF_SEC=1 timeout 120s bin/fm-watch.sh
```

Observed `fm-state/watchdog.events` lines:

```json
{"type":"compact_threshold","sid":"w2-live","status":"triggered","detail":"context_pct=9.8 threshold=1 sid=2838f062-8ce5-4909-b39c-40182e43e1f5","ts":"2026-07-08T17:42:42Z"}
{"type":"steer","sid":"w2-live","status":"delivered","detail":"backend=tmux attempts=1","ts":"2026-07-08T17:42:42Z"}
{"type":"compact_rotated","sid":"w2-live","status":"rearmed","detail":"old_sid=2838f062-8ce5-4909-b39c-40182e43e1f5 new_sid=e7090117-43e0-45cd-8634-efb890c55220 file=<home>/.claude/projects/<claude-project-key>/e7090117-43e0-45cd-8634-efb890c55220.jsonl","ts":"2026-07-08T17:42:45Z"}
```

Observed pane excerpt:

```text
❯ /compact complete current task, then /compact
  ⎿  Not enough messages to compact.
```

The slash command was delivered by the watcher without human input after the watcher started.
Claude reported too little scratch-session history to compact, but the watchdog still observed the new Claude JSONL session file and logged the re-arm event.
