# Child Node producer contract

This document is the reference for the portable Child Node state produced by firstmate on crew and secondmate spawn (CN-P).
It deliberately mirrors the Crew Lead resident pattern in [crew-lead-resident-contract.md](crew-lead-resident-contract.md).
Schema strings and layout follow the captain-locked Child Node program (Q-CN1 home under the Crew Lead home; parent link is God Node provision identity).

## On-disk layout (captain lock Q-CN1)

Under the Crew Lead home (`FM_HOME`):

```text
crews/<task-id>/
  .child-node/
    contract.json      # dev.vellum.child-node/1
    provision.json     # dev.vellum.child-node.provision/1 (immutable container_id)
    child.json         # dev.vellum.child/1 (static descriptor + parent link)
  state/
    child-current.json # dev.vellum.child-current/1 (atomic live pointer)
```

`crews/` is local operational data and is gitignored.
Identity lives under the producer home so it survives worktree recycle.

## Provisioned metadata

`bin/fm-child-node-setup.sh <task-id> [--kind ship|scout|secondmate]` provisions:

| Document | Schema | Mutability |
| --- | --- | --- |
| `contract.json` | `dev.vellum.child-node/1` with `minimum_reader: 1` | Written only when absent; must not hold instance identity fields |
| `provision.json` | Complete shape defined only by `fm_child_node_provision_shape_jq` / `fm_child_node_provision_valid` in `bin/fm-child-node-lib.sh` | Immutable once the complete shape is present; incomplete docs are refused, not published as valid |
| `child.json` | `dev.vellum.child/1` | Static descriptor; may be rewritten like `resident.json` |

`child_type` is `firstmate-crew` (ship), `firstmate-scout` (scout), or `firstmate-secondmate` (secondmate).
Ship and secondmate share the same birth contract; secondmate is not a special case.

### Parent link (durable)

`child.json` carries:

```json
"parent": {
  "kind": "god-node",
  "container_id": "<God Node provision UUID>",
  "home_hint": "<absolute FM_HOME>"
}
```

`parent.container_id` is the **God Node provision** `container_id` from `.god-node/provision.json`.
It is never a soft `god:` session wire id alone.
Session ids can re-materialize after restart; the provision UUID is the durable parent.

### Idempotency and clobber policy

Respawn, recovery, and a reused task id must not destroy a live identity:

| File | When present and valid | When present and invalid | When absent |
| --- | --- | --- | --- |
| `contract.json` | Leave; require the supported schema and reader version and reject instance identity fields | Fail closed (do not overwrite) | Create |
| `provision.json` | Keep forever when the complete shape validates | **Refuse** (do not overwrite; do not treat partial docs as valid identity) | Exclusive-create complete shape |
| `child.json` | Rewrite static descriptor | Replace with the generated descriptor | Create |
| `child-current.json` | Increment epoch when its schema and `container_id` match the provision | Publish a replacement at epoch 1 | First publish epoch 1 |

This is deliberate: unconditional writes that clobber existing provision content are forbidden.
A present non-provision document is an error, not a recreate signal.

## Current-state pointer

`bin/fm-child-node-publish.sh <task-id> [lifecycle]` publishes `state/child-current.json` with schema `dev.vellum.child-current/1`.

Required fields: `container_id`, `parent_container_id`, `epoch`, `published_at`, `lifecycle`, `child_type`, `task_id`.
`parent_container_id` must match both the God Node provision id and `child.json` parent; mismatch fails closed.

Lifecycle values: `starting`, `ready`, `waiting`, `blocked`, `degraded`, `stopped`, `failed`, `done`.
Birth publish uses `starting`.
Optional backend, process (pid + creation_identity), status verb, and attestation method fields follow the resident pointer rules: PID alone is never liveness truth.

### Nested conversation (full transcript bind) and top-level identity hints

The real consumer interface is the nested `conversation` object plus optional top-level identity hints.
This is the contract ruled by the Vellum-side class fix (vellum main after PR 955): consumers bind Chat through `conversation` and treat top-level `harness`/`worktree` as per-field hints only.

#### Nested `conversation` (required for zero-meta transcript bind)

When every field is knowable, publish:

```json
"conversation": {
  "harness": "<claude|codex|grok|…>",
  "session_id": "<harness session id>",
  "transcript": {
    "adapter": "<ADR 0056 adapter id, e.g. grok-chat-history-v1>",
    "id": "<same as session_id>",
    "path": "</absolute/physical/path/to/journal>"
  }
}
```

Rules:

- Publish **only** when harness, session_id, adapter, and a **verified-real** absolute transcript path are all known.
- Discovery reuses the resident multi-harness helpers (`fm_resident_discover_transcript`, ADR 0056 adapters).
- Paths are canonicalized to the physical spelling (`pwd -P` / `fm_resident_canonical_path`); prefer `/var/home` over a `/home` symlink.
- **Omit the entire `conversation` object** when any field is unknown - never invent a session id or path.
- Full conversation is often unknowable at birth (`starting`); it completes when the session artifact becomes real.
- The natural completion path is a later publish with lifecycle omitted (preserves prior lifecycle/backend/status) on status or turn-end, via `fm_child_node_try_refresh` from the watcher signal scan.
- Env overrides for tests: `FM_CHILD_SESSION_ID`, `FM_CHILD_TRANSCRIPT` (path must exist).

Harness alone is not enough for durable transcript bind.
Top-level `harness` alone is not enough (firstmate PR #50 shape was insufficient for Chat: the then-shipped consumer only read nested `conversation`, so serde dropped the top-level fields unread).

#### Additive top-level identity hints

When known, the pointer also advertises:

| Field | Source | Meaning |
| --- | --- | --- |
| `harness` | `state/<task-id>.meta` `harness=` (or non-empty `FM_CHILD_HARNESS` override) | Conversation harness the agent actually runs on (`claude`, `codex`, `grok`, …) |
| `worktree` | `state/<task-id>.meta` `worktree=` (or non-empty `FM_CHILD_WORKTREE` override) | Absolute task worktree path (physical spelling when the path exists) |

Consumers prefer `conversation.harness` over top-level `harness` when both are present.
These are additive optional fields on `dev.vellum.child-current/1`.
Additive fields within a supported major version may be ignored by readers; breaking field or semantic changes require a new major schema string (same versioning rule as [crew-lead-resident-contract.md](crew-lead-resident-contract.md)).
Absent means not currently advertised: **omit the field**.
Never invent a default harness (in particular never default to `claude`) and never invent a worktree path.
Spawn writes task meta before the first Child Node publish, so a successful birth publish carries the same `harness` and `worktree` values as meta when those keys are present.

#### History (firstmate PR #50)

PR #50 published only top-level `harness`/`worktree` and claimed e2e success without a consumer-side deserialize of nested `conversation`.
That was a composed-path failure: the producer feed did not match the consumer-ruled bind contract.
Top-level hints are retained as salvageable additive identity; this producer slice completes the nested `conversation` publish the consumer needs for Chat.

Publication holds `state/child-current.lock`, increments epoch for a readable pointer with the matching schema and `container_id`, writes a coherent JSON snapshot to a same-directory temporary file, validates JSON, flushes, and renames into place via `fm_resident_atomic_json`.
Readers observe only the old complete document or the new complete document.
When lifecycle is omitted on a later publish and a matching pointer exists, the previous lifecycle is preserved (conversation-completion refresh).
On a lifecycle-omitted refresh, prior backend, attestation, status, and process objects are preserved verbatim when their corresponding env values are omitted.
An explicit lifecycle transition never inherits those prior objects.
Fresh backend triples and status verbs receive the new publication timestamp; carried observations retain their original timestamps.
An inherited process keeps its original pid and creation identity as one pair and is never re-observed by pid.

## Spawn integration

`bin/fm-spawn.sh` births a Child Node after recording task meta, for ship, scout, and secondmate kinds:

1. `fm-child-node-setup.sh <id> --kind <kind>`
2. `fm-child-node-publish.sh <id> starting` (backend triple when complete; tmux omits incomplete backend rather than inventing pane ids; nested conversation only if a journal is already real)

Failure of either step fails the spawn (fail closed).
Dry-run exits before birth.
After birth, `bin/fm-watch.sh` best-effort refreshes the Child Node pointer on status and turn-end signals (`fm_child_node_try_refresh`) so nested conversation completes when the session artifact appears.
Scripts are under `bin/fm-child-node-*.sh`; helpers live in `bin/fm-child-node-lib.sh`.
Contract, descriptor, and current-state writes reuse the resident same-directory temporary-file validation and flush steps.
Mutable files use the resident rename-into-place seam, while immutable `provision.json` is published with an exclusive hard link so a concurrent or existing identity cannot be replaced.

## Out of scope (this producer slice)

- Consumer dual-read / adoption (CN-B)
- Attestation-driven resurrection (CN-C)
- Wire rekey to `child:<uuid>` (CN-E)
- Herdr lifecycle control from Vellum

## Empirical verification

Verification was re-run on 2026-07-31 against this branch's producer birth and conversation-completion path (nested `conversation` + top-level hints), a consumer-shape fixture mirroring Vellum `ChildCurrent`/`ChildConversation`, jq, and ShellCheck.

Command:

```text
tests/fm-child-node-producer.test.sh
```

Output:

```text
ok - setup writes contract, provision, and child under crews/<task>/.child-node/
ok - parent link is God Node provision container_id
ok - complete provision shape is required; half-formed docs are refused not published as valid
ok - idempotent setup preserves identity and refuses clobber of invalid provision
ok - first child-current pointer publishes with durable parent and monotonic epoch
ok - failed pre-rename writes leave the previous complete child-current intact
ok - secondmate path uses the same Child Node birth contract
ok - fm-spawn ship birth writes Child Node docs and first current
ok - fm-spawn secondmate birth writes Child Node docs under crews/<task>
ok - child-current publishes non-claude harness and worktree from task meta
ok - unknown harness and worktree are omitted, never fabricated
ok - fm-spawn non-claude harness and worktree match child-current
ok - child-current publishes nested conversation; consumer shape deserializes it
ok - unknown transcript omits conversation; top-level hints still published
ok - birth-then-complete publish preserves prior observed objects verbatim
ok - explicit lifecycle transition does not inherit stale observed objects
ok - known transcript extracts session without unrelated worktree
ok - fm-spawn birth-then-complete: nested conversation arrives for consumer read
```

Command:

```text
shellcheck -x bin/fm-child-node-lib.sh bin/fm-child-node-setup.sh bin/fm-child-node-publish.sh bin/fm-watch.sh tests/fm-child-node-producer.test.sh
```

Output:

```text
(no output; exit 0)
```
