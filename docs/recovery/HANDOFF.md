# Recovery Harness Handoff

## Purpose

This file captures the current implementation state of the Docker-based Kafka recovery harness so work can resume on another machine without reconstructing context from the full session.

## Current State

The repo is no longer spec-only. The first implementation pass of the harness foundation is in place:

- recovery validation docs are organized under `docs/recovery/`
- the canonical source fixture and rewrite-tool contracts are pinned in the docs
- the source-cluster and recovery-cluster Docker Compose files exist
- the source-cluster lifecycle scripts exist
- the recovery preparation and startup scaffolding exists
- generated fixture data paths are ignored via `.gitignore`

## Implemented Files

### Compose

- `compose/source-cluster.compose.yml`
- `compose/recovery-cluster.compose.yml`

### Shared Automation Helpers

- `automation/lib/common.sh`
- `automation/lib/source_fixture.py`
- `automation/lib/checkpoint_tool.py`
- `automation/lib/generate_fixture_records.py`
- `automation/lib/seed_transactions.py`

### Source Cluster Commands

- `automation/source-cluster/up`
- `automation/source-cluster/seed`
- `automation/source-cluster/validate`
- `automation/source-cluster/stop`
- `automation/source-cluster/snapshot`

### Recovery Commands

- `automation/recovery/prepare`
- `automation/recovery/rewrite`
- `automation/recovery/up`
- `automation/recovery/down`

## What The Current Automation Does

### Source Cluster

The source-cluster automation currently:

- creates the expected host directory layout under `fixtures/source-cluster/live/`
- renders readable `server.properties` overlays for each broker under `rendered-config/`
- starts a 9-node combined `broker,controller` KRaft cluster on Confluent `cp-kafka:8.1.0`
- creates the pinned topic set from `source-fixture-spec.md`
- seeds deterministic non-transactional data by explicit partition
- seeds deterministic compacted-topic keys and values
- attempts to seed transactional data using the Python `confluent-kafka` client
- attempts to set the pinned consumer-group offsets
- applies the pinned dynamic broker override for broker `0`
- validates topic existence, partition counts, replication factor, offsets, configs, consumer-group state, and transactional read-committed visibility
- creates an immutable clean-stop snapshot set under `fixtures/snapshots/<label>/`
- writes `manifest.json` and compacted-topic expectation files into the snapshot set

### Recovery

The recovery scaffolding currently:

- copies brokers `0`, `1`, and `2` from an immutable snapshot into a disposable scenario work directory
- captures `quorum-state` metadata and deterministically selects the input `.checkpoint`
- renders recovery config overlays for the 3-node target
- deletes copied metadata log state that must not be replayed directly
- prepares invocation of the snapshot rewrite tool
- installs the rewritten checkpoint into the copied metadata directories
- starts and stops the 3-node recovery cluster from the copied working data

## What Has Been Verified

These checks were completed successfully:

- shell syntax: `bash -n` across the new scripts
- Python syntax: `python3 -m py_compile` across the Python helpers
- helper behavior: fixture JSON generation, checkpoint-tool CLI help, and sample deterministic payload generation

These checks were **not** completed yet:

- actual Docker Compose rendering against a live Docker engine
- actual source-cluster startup
- actual fixture seeding against Confluent 8.1 containers
- actual snapshot capture
- actual recovery-cluster startup

## Known Gaps

### Major Missing Piece

- the actual snapshot rewrite binary is still not implemented
- `automation/recovery/rewrite` expects an executable at `bin/snapshot-rewrite-tool` or `SNAPSHOT_REWRITE_TOOL`

### Runtime Risks To Validate First

- the Docker engine must allow access to the local Docker socket for `docker compose`
- the Python package `confluent-kafka` must be installed on the host for transactional fixture seeding
- `kafka-consumer-groups --reset-offsets` may not be sufficient to materialize the pinned offsets unless the empty groups are first created in a way Confluent 8.1 accepts
- Kafka CLI names can vary slightly across images, so any command-path mismatch should be fixed from real container output rather than guessed

## First Commands To Run On The New Machine

From repo root:

```bash
automation/source-cluster/up
automation/source-cluster/seed
automation/source-cluster/validate
automation/source-cluster/stop
automation/source-cluster/snapshot baseline-clean-v1
```

If the source fixture succeeds, the next checkpoint is:

```bash
automation/recovery/prepare scenario-01 baseline-clean-v1
automation/recovery/rewrite scenario-01 <run-id>
automation/recovery/up scenario-01 <run-id>
```

`<run-id>` is written into `fixtures/scenario-runs/scenario-01/<run-id>/run.env` by `automation/recovery/prepare`.

## Recommended Resume Order

1. Verify Docker access from the new machine.
2. Run the source-cluster smoke path.
3. Fix any Confluent 8.1 runtime mismatches in the seed and validate scripts.
4. Capture the first real run artifacts under `fixtures/source-cluster/artifacts/`.
5. Implement `bin/snapshot-rewrite-tool`.
6. Run Scenario 01 end to end.

## Main Docs To Read Before Resuming

- `docs/recovery/README.md`
- `docs/recovery/TODO.md`
- `docs/recovery/harness-spec.md`
- `docs/recovery/source-fixture-spec.md`
- `docs/recovery/rewrite-tool-spec.md`
- `docs/recovery/scenarios/scenario-01-quorum-and-metadata.md`
- `final-recovery-plan.md`

## Git Notes

- current branch: `main`
- remote: `origin`
- local `.claude/` contains Claude worktree metadata and should stay out of normal repo commits

