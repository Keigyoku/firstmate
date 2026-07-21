# Crew TDD guard

`bin/fm-crew-tdd-guard.sh` is the single owner of the crew pre-execution TDD gate.
The ship brief (`bin/fm-brief.sh` Test-first section) is the single owner of the full fleet TDD contract text (iron rules F1-F4, vertical slices, typed exemptions, A1 RED evidence shape).
This guard does not restate that contract; it pins authoring order on the same delivery rails as the crew kill guard.

## Status

**Temporary until tuned** (captain lock C2-modified, 2026-07-20).
The escape hatch stays until the denial patterns stop producing hard blocks that need firstmate help.

## Escape hatch (uniform)

Any of these disables the TDD pre-execution layer for ship-crew spawns:

- Environment: `FM_TDD_HOOK_OFF=1` at spawn (hook not installed) or at runtime inside the crew (checker allows every command).
- Config: local gitignored `config/tdd-hook` with exactly `off` (checked at spawn; same shape as `config/turnend-guard` / `config/claim-guard`).

Kill-guard rails are independent and stay installed.

## Spawn installation

`bin/fm-spawn.sh` installs a private copy next to the kill guard under `/tmp/fm-<task-id>/fm-crew-tdd-guard.sh` for every **ship** crew when the hatch is not set.
Scouts (`kind=scout`) are report-only (scratch worktree, no PR) and are **not** installed; they stay outer-gate-only like Cursor/Hermes.
Secondmate primaries are exempt; ship crews they launch still get the copy via the same task-temp install.

| Adapter | Enforcement |
| --- | --- |
| Claude | Second `PreToolUse` Bash hook after the kill guard invokes the copied checker with `--claude`. |
| Codex | Second per-launch `PreToolUse` Bash hook after the kill guard (no project `hooks.json` rewrite). |
| OpenCode | The generated task plugin runs the TDD checker after the kill checker in `tool.execute.before`. |
| Pi | The generated task extension runs the TDD checker after the kill checker on `tool_call`. |
| Grok | Second always-trusted global `PreToolUse` hook with the same opaque per-task pointer pattern as the kill guard (`fm-tdd-guard.d` + `.fm-grok-tddguard`). |
| Cursor and Hermes | **No verified pre-execution hook surface** (PATH-shim only for process signaling; see `docs/crew-kill-guard.md`). These adapters are **outer-gate-only** for TDD: the ship brief contract, Review Crew RED-evidence checklist, and the harness-blind `replay-red` CI still bind them. |

## Policy (v1)

- Always allow test-runner commands (how RED is obtained).
- Always allow when the task has a RED marker (`tdd-red-seen` beside the checker).
- Deny clear production-source shell writes (narrow `sed -i` / redirect patterns) without that marker.
- After a verified RED run, the crew marks RED with:
  `/tmp/fm-<id>/fm-crew-tdd-guard.sh --mark-red`
  or `touch /tmp/fm-<id>/tdd-red-seen`.
- Claude also receives a one-shot allow-path pin pointing at the brief Test-first section and the tdd skill. The pin is `additionalContext` only (no `permissionDecision`), printed on **stdout** with exit 0 so Claude Code actually injects it and it never overrides the kill guard's deny.

The canonical TDD how-to is the captain's `tdd` skill, referenced from the ship brief (Claude crews invoke `/tdd`; other harnesses read `$HOME/.claude/skills/tdd/SKILL.md` and siblings in place). Skills are never copied or symlinked into the worktree.

Scouts, Cursor, and Hermes never see this checker; behavior PRs still must produce RED evidence or take a typed exemption.

## Related

- Contract text: ship brief Test-first block from `bin/fm-brief.sh`.
- Review adjudication: `.agents/skills/review-crew/SKILL.md` red-first checklist.
- Delivery rails: `docs/crew-kill-guard.md`.
