# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `check-personal-references.sh` | Reject tracked text containing known local-operator identifiers, with narrow allowlist support |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-resident-setup.sh`   | Provision Crew Lead contract metadata and local file input directories               |
| `fm-resident-adopt.sh`   | Adopt the current home as a Crew Lead container and validate its metadata            |
| `fm-resident-start.sh`   | Acquire the session lock and publish the current Crew Lead session; optional `--launch` execs the harness after publish |
| `fm-resident-restart.sh` | Re-acquire the session lock and refresh the pointer; optional `--launch` same as start |
| `fm-resident-doctor.sh`  | Validate Crew Lead contract metadata and the current pointer when present            |
| `fm-resident-publish.sh` | Publish one atomic Crew Lead current-state pointer snapshot                          |
| `fm-resident-lib.sh`     | Shared Crew Lead resident-container helpers                                         |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, and branch pruning |
| `fm-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `fm-fleet-snapshot.v1`)   |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and secondmate homes from origin          |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-brief.sh`            | Scaffold ship, scout, secondmate-charter, and Herdr-lab briefs                       |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `fm-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and stale watcher liveness   |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-claim-guard.sh`      | Claim-vs-evidence glass guard composed on the Claude Stop hook (docs/turnend-guard.md) |
| `fm-glass.sh`            | Capture live desktop glass and record the `fm-state/last-glass-capture` freshness marker (docs/turnend-guard.md) |
| `fm-crew-kill-guard.sh`  | Shared crew/scout process-signaling guard predicate (docs/crew-kill-guard.md)       |
| `fm-crew-kill-shim.sh`   | PATH refusal shim installed as `pkill`, `killall`, and `fuser` for crew/scout tasks |
| `fm-crew-tdd-guard.sh`   | Ship-crew TDD pre-execution guard predicate on the kill-guard rails (docs/crew-tdd-guard.md) |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a secondmate home and maintain `data/secondmates.md`       |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-dispatch-select.sh`  | Resolve a matched crew-dispatch rule to one concrete profile, owning `quota-balanced` selection |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inheritable local config to live secondmate homes mid-session          |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`           |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or recorded PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Shared from-firstmate request marker and detector                                    |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with honest status reporting                |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe always-on watcher: absorb benign wakes, queue and exit on actionable ones |
| `fm-steer.sh`            | Deliver one bounded watchdog steer line to a task through `fm-send.sh` |
| `fm-successor.sh`        | Spawn a proven watchdog successor from a handoff and retire the predecessor, halting on any unproven spawn |
| `fm-rotate-resident.sh`   | Manually rotate the current task resident through the watchdog successor path |
| `fm-watchdog-lib.sh`     | Shared watchdog config, metrics, session lookup, embargo, and event helpers |
| `fm-embargo-lift`        | Manually lift one watchdog budget embargo flag |
| `fm-afk-start.sh`        | Enter away mode and run the sub-supervisor daemon as a tracked foreground process    |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local secondmate syncs       |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inheritable-config propagation                        |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes, then assert watcher liveness                  |
| `fm-wake-lib.sh`         | Shared durable wake queue, portable locks, and watcher identity/health helpers       |
| `fm-classify-lib.sh`     | Shared captain-relevant and declared-external-wait wake classification vocabulary    |
| `fm-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, composer capture, and verified submit |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-pr-check.sh`         | Record `pr=` and `pr_head=` for a PR-ready task, then arm the watcher's merge poll   |
| `fm-pr-merge.sh`         | Record PR metadata, then merge a task's PR from its full GitHub URL                  |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task                               |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require scout reports, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared X-mode config, relay, and reply-threading helpers                             |
| `fm-x-poll.sh`           | One bounded X relay poll: stash pending mentions, print `x-mention <request_id>`     |
| `fm-x-reply.sh`          | Post or dry-run preview a composed X-mode reply or follow-up                         |
| `fm-x-dismiss.sh`        | Dismiss a skipped X-mode mention at the relay without replying                       |
| `fm-x-link.sh`           | Link a spawned task to its originating X-mode mention in task meta                   |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for an X-mode-linked task                |
