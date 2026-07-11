# Watchdog W3 Live Evidence

Date: 2026-07-08.
Worktree: `<home>/.treehouse/firstmate-7bab20/1/firstmate`.
Branch: `fm/pivot-w3-successor-g6`.
Claude Code: `2.1.193`.

## Isolation

The live proof used `CLAUDE_CONFIG_DIR=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/claude-config`.
The live proof used `FM_HOME=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/fm-home`.
The live proof used `FM_WATCHDOG_CLAUDE_SESSION_DIR=$CLAUDE_CONFIG_DIR/projects`.
The live proof used `FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR=$CLAUDE_CONFIG_DIR/token-optimizer/checkpoints`.
The scratch Claude settings set `autoCompactEnabled=false`.
The scratch Claude settings also set `DISABLE_AUTO_COMPACT=1`.
The scratch `.credentials.json` and `.claude.json` copies were mode `600`.
No credential contents are quoted here.

The private tmux server was `tmux -L fm-w3-test`.
The private server contained the test sessions `fm-w3-isolation-probe` and `fm-w3-live`.
The real default tmux server contained the captain session only when checked with `/usr/bin/tmux ls`.
The watchdog and steer commands used a `tmux` shim on `PATH` that always executed `tmux -L fm-w3-test`.

The global Claude project path snapshots showed zero new files during prepare.
The global Claude project path snapshots showed zero new files during the live proof.
One existing global firstmate JSONL changed size and mtime while the proof was running, which is consistent with the captain's real running session and was not a new file.

## Fresh Growth

The predecessor was a fresh Claude session under the scratch config.
The session confirmed the scratch settings via `/status`, including `Setting sources: User settings, Command line arguments`.
The session read scratch text chunks `chunk-1.txt` through `chunk-4.txt` and replied `W3GROW1` through `W3GROW4`.
The session later read scratch text chunks `chunk-5.txt` through `chunk-8.txt` and replied `W3CLEAR5` through `W3CLEAR8`.
These chunks were copied into `fm-scratch/w3-live/growth/` and were not committed.
The evidence excerpts avoid quoting the copied session content.
Claude did not create token-optimizer checkpoint files in the scratch home, so the watchdog parser consumed scratch checkpoint JSON files written under `$FM_WATCHDOG_CLAUDE_CHECKPOINT_DIR` after the live growth turns.

## Compact Rotation

The compact threshold was set to `30`.
After the live growth turns, the scratch checkpoint for session `b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335` reported `context_pct=31`.
The watchdog armed the session, triggered compact, delivered `/compact`, and then detected the compact summary generation in the same Claude JSONL.

```json
{"type":"watchdog_session_armed","sid":"w3-compact","status":"armed","detail":"harness=claude sid=b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335 file=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/claude-config/projects/<claude-project-key>/b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335.jsonl","ts":"2026-07-08T21:19:09Z"}
{"type":"compact_threshold","sid":"w3-compact","status":"triggered","detail":"context_pct=31 threshold=30 sid=b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335","ts":"2026-07-08T21:20:24Z"}
{"type":"steer","sid":"w3-compact","status":"delivered","detail":"backend=tmux attempts=1","ts":"2026-07-08T21:20:24Z"}
{"type":"compact_rotated","sid":"w3-compact","status":"rearmed","detail":"old_sid=b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335 new_sid=b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335 file=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/claude-config/projects/<claude-project-key>/b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335.jsonl compact_generation=afd3c454-7eb0-45ab-8c60-ae7ad2d9a940","ts":"2026-07-08T21:22:06Z"}
```

The pane showed the watchdog-delivered command and Claude's compact result.

```text
❯ /compact complete current task, then /compact
  ⎿  Compacted (ctrl+o to see full summary)
  ⎿  Referenced file fm-scratch/w3-live/growth/chunk-1.txt
  ⎿  Referenced file fm-scratch/w3-live/growth/chunk-2.txt
  ⎿  Referenced file fm-scratch/w3-live/growth/chunk-3.txt
  ⎿  Referenced file fm-scratch/w3-live/growth/chunk-4.txt
```

Claude wrote the compact summary into the same JSONL instead of rotating to a new file.
The W3 code therefore records `compact_generation=...` as the rotation proof for same-file Claude compaction.

## Clear Rotation

The clear threshold was set to `65`.
After the second live growth batch, the scratch checkpoint for session `b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335` reported `context_pct=66`.
The watchdog armed the session, triggered clear, delivered `/clear`, observed a new Claude JSONL, and logged successor takeover.
The first detection pass happened after the scratch retry window had expired, so the scratch config was widened to `compact_pending_retry_sec=900` and the next pass recorded the already-present rotation.

```json
{"type":"watchdog_session_armed","sid":"w3-clear","status":"armed","detail":"harness=claude sid=b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335 file=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/claude-config/projects/<claude-project-key>/b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335.jsonl","ts":"2026-07-08T21:24:35Z"}
{"type":"clear_threshold","sid":"w3-clear","status":"triggered","detail":"context_pct=66 threshold=65 sid=b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335","ts":"2026-07-08T21:24:40Z"}
{"type":"steer","sid":"w3-clear","status":"delivered","detail":"backend=tmux attempts=1","ts":"2026-07-08T21:24:40Z"}
{"type":"clear_rotated","sid":"w3-clear","status":"successor_takeover","detail":"old_sid=b1cc2ddb-e2c8-4fb6-b8a0-8aaa53fd2335 new_sid=3ef87fdb-e3d5-4744-92c7-29630a2c6b17 file=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/claude-config/projects/<claude-project-key>/3ef87fdb-e3d5-4744-92c7-29630a2c6b17.jsonl","ts":"2026-07-08T21:26:15Z"}
{"type":"successor_complete","sid":"w3-clear","status":"succeeded","detail":"reason=clear_rotated","ts":"2026-07-08T21:26:15Z"}
```

The pane showed the watchdog-delivered clear command and a new Claude banner immediately afterward.

```text
❯ /clear complete current task, then /clear
```

The new scratch JSONL was `3ef87fdb-e3d5-4744-92c7-29630a2c6b17.jsonl`.
The clear proof used a scratch spawn double because the separate real successor proof had already started a real Claude successor.
The clear proof still exercised the live predecessor, live `/clear`, rotation detection, handoff creation, successor event path, and predecessor-retire call path.

## Successor Spawn

The live successor proof used a forced rc4 steer in the isolated tmux server.
The original live excerpt below predates the unique per-trigger handoff fix and honestly preserves the then-current `fm-state/handoff-latest.md` path.
Current production code writes each trigger to `fm-state/handoffs/handoff-<task>-<timestamp>-<pid>.md`, optionally refreshes `fm-state/handoff-latest.md` as a convenience pointer, and passes the unique handoff path to `fm-successor.sh`.
Successor spawn must consume the unique per-trigger handoff file, not the shared latest pointer.

```json
{"type":"successor_spawn","sid":"w3-successor","status":"started","detail":"successor=w3-successor-next handoff=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/fm-home/fm-state/handoff-latest.md brief=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/fm-home/data/w3-successor-next/brief.md","ts":"2026-07-08T21:10:49Z"}
{"type":"successor_spawn","sid":"w3-successor","status":"succeeded","detail":"successor=w3-successor-next handoff=<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/fm-home/fm-state/handoff-latest.md","ts":"2026-07-08T21:10:49Z"}
{"type":"predecessor_retired","sid":"w3-successor","status":"closed","detail":"successor=w3-successor-next","ts":"2026-07-08T21:10:49Z"}
{"type":"successor_complete","sid":"w3-successor","status":"succeeded","detail":"reason=steer_undeliverable","ts":"2026-07-08T21:10:49Z"}
```

The final successor pane excerpt also predates the unique per-trigger handoff fix, so its path is historical evidence rather than the current handoff contract.
The prompt still demonstrates that the successor received and read the handoff content in its first turn.

```text
You are a successor session for `w3-successor-next`.
Read and continue from this handoff artifact:
`<home>/.treehouse/firstmate-7bab20/1/firstmate/fm-scratch/w3-live/fm-home/fm-state/handoff-latest.md`.
Predecessor: `w3-successor`.
Reason: steer_undeliverable.
Context percent: 50.
Steer rc: 4.
```

The successor then read the handoff artifact and identified itself as the spawned successor.
One rerun had duplicate stale metas in the scratch home and produced a duplicate-spawn failure on the second meta, so the final evidence above uses the clean successful successor event chain plus the corrected first-prompt excerpt.

## Negative Halt Path

The automated negative path is covered by `tests/watchdog/test-successor.sh`.
That test asserts a failed successor spawn writes `fm-state/watchdog.halt`, writes `fm-state/steer-failure-<ts>.md`, and causes the watch loop to exit without busy-loop retry.

The focused watchdog tests passed after the W3 changes.

```text
tests/watchdog/test-steer.sh
tests/watchdog/test-successor.sh
tests/watchdog/test-metrics.sh
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh tests/watchdog/*.sh
```
