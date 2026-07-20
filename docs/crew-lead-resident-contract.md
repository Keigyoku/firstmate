# Crew Lead resident producer contract

This document is the reference for the portable state produced by firstmate's Crew Lead integration.
Internal protocol paths retain the ratified `god-node` names.

## Provisioned metadata

`bin/fm-resident-setup.sh` provisions `.god-node/contract.json` with schema `dev.vellum.god-node/1` and `minimum_reader` set to `1`.
This file is tracked template metadata and must not contain per-home instance identity.

Setup also provisions the gitignored `.god-node/provision.json` with schema `dev.vellum.god-node.provision/1`, a UUID-v4 `container_id`, an RFC3339 `created_at`, and `identity_kind` set to `resident-container`.
The container identifier is immutable during ordinary setup and upgrades once present in `provision.json`.
Copies of a tracked home template receive a new identity because `provision.json` is local state.

Setup also atomically writes `.god-node/resident.json` with schema `dev.vellum.resident/1`.
The descriptor is tracked template metadata and declares resident type `firstmate`, the stable producer descriptor version, supported contract major versions, argv-array entrypoints, and the full capability set.
Advertised capabilities are `input.file-v1`, `input.backend-v1`, `transcript.claude-jsonl-v1`, `transcript.codex-jsonl-v1`, and `crew.bridge-v1`.
`crew.bridge-v1` independently gates adopted-crew reconciliation in consumers that treat a readable descriptor as authoritative; setup and every session-lock republication must keep it in the list.
Entrypoint paths are relative to the Crew Lead home.
The adoption entrypoint provisions and validates metadata in place without moving or rewriting private operational data.

Provisioned documents are written to unique same-directory temporary files, validated as JSON, flushed, and renamed into place.
The directory is flushed on a best-effort basis after the rename.

## Current-state pointer

`state/resident-current.json` is the sole mutable current-state pointer and uses schema `dev.vellum.resident-current/1`.
It contains the immutable `container_id`, monotonic unsigned `epoch`, RFC3339 `published_at`, lifecycle, resident type, health heartbeat, and the currently advertised process, backend, conversation, transcript, and input fields.
Absent optional fields mean they are not currently advertised.

The process identity pairs the PID with an opaque creation identity.
Linux producers use `linux-proc-v1:<boot-id>:<proc-start-ticks>`.
Other supported hosts use `ps-lstart-v1:<process-start-time>`.
A consumer must validate both values before treating a PID as the same process.

Claude transcripts use adapter `claude-jsonl-v1` and Codex rollouts use adapter `codex-jsonl-v1`.
The harness session identifier and absolute transcript path are mutable attributes and never replace container identity.
When a complete backend endpoint is available, input uses `backend-v1` with the same workspace and pane identifiers published in `backend`.
Headless operation uses `file-v1` and advertises `inbox/requests` and `inbox/results` relative to the Crew Lead home.

Every semantic publication increments `epoch` while holding `state/resident-current.lock` as a serialization directory.
The publisher writes a coherent JSON snapshot to a unique temporary file in `state/`, flushes it, and renames it over the pointer.
Readers can therefore observe only the old complete document or the new complete document.
Clean shutdown publishes lifecycle `stopped`, increments the epoch, and omits process, backend, and conversation fields instead of deleting the pointer.

The existing `state/.lock` session authority invokes setup and publication after each successful primary lock acquisition.
This deliberately extends the session-lock machinery instead of creating a parallel primary-session tracker.
Adapters and rotation hooks may call `bin/fm-resident-publish.sh` for lifecycle, transcript, backend, or input changes that occur without a new lock acquisition.

## Versioning rules

The integer after the slash in each schema string is its major version.
Readers must fail closed on an unsupported major version or a pointer whose `container_id` differs from `.god-node/provision.json`.
Additive fields within a supported major version may be ignored by readers.
Breaking field or semantic changes require a new major schema and an added entry in the tracked `resident.json` template only when the installed producer supports that version.
An upgrade changes tracked descriptor metadata but never rewrites `provision.json` or resets the pointer epoch.

## Empirical verification

Verification was run on 2026-07-13 against firstmate base commit `4679f18f2b513a76238f67132304b69096411d2b`, jq 1.8.1, and ShellCheck 0.11.0.

Command:

```text
tests/fm-resident-producer.test.sh
```

Output:

```text
ok - provisioning creates local immutable identity and versioned manifest
ok - session lock acquisition fails closed when resident publication fails
ok - publisher lock recovers abandoned owner state
ok - session rotation publishes endpoint, transcript, process identity, and monotonic epoch
ok - failed pre-rename writes leave the previous complete pointer intact
ok - concurrent publishers serialize atomic epoch updates
ok - standalone headless publication uses the file-v1 input baseline
ok - clean stop preserves the pointer while clearing live endpoint fields
```

Command:

```text
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
```

Output:

```text
(no output; exit 0)
```
