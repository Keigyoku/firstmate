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

### Optional conversation harness and worktree

When known, the pointer also advertises:

| Field | Source | Meaning |
| --- | --- | --- |
| `harness` | `state/<task-id>.meta` `harness=` (or non-empty `FM_CHILD_HARNESS` override) | Conversation harness the agent actually runs on (`claude`, `codex`, `grok`, …) |
| `worktree` | `state/<task-id>.meta` `worktree=` (or non-empty `FM_CHILD_WORKTREE` override) | Absolute task worktree path used for transcript bind and cwd |

These are additive optional fields on `dev.vellum.child-current/1`.
Additive fields within a supported major version may be ignored by readers; breaking field or semantic changes require a new major schema string (same versioning rule as [crew-lead-resident-contract.md](crew-lead-resident-contract.md)).
Absent means not currently advertised: **omit the field**.
Never invent a default harness (in particular never default to `claude`) and never invent a worktree path.
Spawn writes task meta before the first Child Node publish, so a successful birth publish carries the same `harness` and `worktree` values as meta when those keys are present.

Publication holds `state/child-current.lock`, increments epoch for a readable pointer with the matching schema and `container_id`, writes a coherent JSON snapshot to a same-directory temporary file, validates JSON, flushes, and renames into place via `fm_resident_atomic_json`.
Readers observe only the old complete document or the new complete document.

## Spawn integration

`bin/fm-spawn.sh` births a Child Node after recording task meta, for ship, scout, and secondmate kinds:

1. `fm-child-node-setup.sh <id> --kind <kind>`
2. `fm-child-node-publish.sh <id> starting` (backend triple when complete; tmux omits incomplete backend rather than inventing pane ids)

Failure of either step fails the spawn (fail closed).
Dry-run exits before birth.
Scripts are under `bin/fm-child-node-*.sh`; helpers live in `bin/fm-child-node-lib.sh`.
Contract, descriptor, and current-state writes reuse the resident same-directory temporary-file validation and flush steps.
Mutable files use the resident rename-into-place seam, while immutable `provision.json` is published with an exclusive hard link so a concurrent or existing identity cannot be replaced.

## Out of scope (this producer slice)

- Consumer dual-read / adoption (CN-B)
- Attestation-driven resurrection (CN-C)
- Wire rekey to `child:<uuid>` (CN-E)
- Herdr lifecycle control from Vellum

## Empirical verification

Verification was re-run on 2026-07-31 against this branch's producer birth path (including harness/worktree publication), jq, and ShellCheck.

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
```

Command:

```text
shellcheck -x bin/fm-child-node-lib.sh bin/fm-child-node-setup.sh bin/fm-child-node-publish.sh tests/fm-child-node-producer.test.sh
```

Output:

```text
(no output; exit 0)
```
