# Recovery Harness Handoff

## Purpose

This file captures the current implementation state of the Docker-based Kafka recovery harness so work can resume on another machine without reconstructing context from the full session.

## Current State

The repo is no longer spec-only. The current state is:

- recovery validation docs are organized under `docs/recovery/`
- the canonical source fixture and rewrite-tool contracts are pinned in the docs
- the source-cluster and recovery-cluster Docker Compose files exist
- the source-cluster lifecycle scripts exist
- the recovery preparation, rewrite, startup, and teardown scripts exist
- the snapshot rewrite tool exists behind `bin/snapshot-rewrite-tool` and is implemented under `tooling/snapshot-rewrite/`
- Scenario 01 is fully automated and passed cleanly on 2026-04-21 with run ID `20260421T084355Z`
- Scenario 02 is fully automated and passed cleanly on 2026-04-21 with run ID `20260421T095313Z`
- Scenario 05 is fully automated and passed cleanly on 2026-04-21 with run ID `20260421T113800Z`
- Scenario 08 is fully automated and passed cleanly on 2026-04-21 with run ID `20260421T131900Z`
- the harness now supports worktree-friendly root overrides so scenario work can run from a dedicated Git worktree while still pointing at shared snapshot artifacts

Use [`scenario-implementation-roadmap.md`](./scenario-implementation-roadmap.md) as the authoritative execution plan. Scenario 01, Scenario 02, Scenario 05, and Scenario 08 are now the completed anchors; Scenario 04 is the next implementation target.

## Implemented Files

### Compose

- `compose/source-cluster.compose.yml`
- `compose/recovery-cluster.compose.yml`

### Snapshot Rewrite Tool

- `bin/snapshot-rewrite-tool`
- `tooling/snapshot-rewrite.Dockerfile`
- `tooling/snapshot-rewrite/`

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

### Targeted Recovery Tests

- `automation/tests/common_roots_override_test.sh`
- `automation/tests/rewrite_cleanup_test.sh`
- `automation/tests/source_render_configs_test.sh`
- `automation/tests/scenario_01_assert_test.sh`
- `automation/tests/scenario_01_report_test.sh`
- `automation/tests/scenario_02_assert_test.sh`
- `automation/tests/scenario_02_report_test.sh`
- `automation/tests/scenario_05_assert_test.sh`
- `automation/tests/scenario_05_report_test.sh`
- `automation/tests/scenario_08_assert_test.sh`
- `automation/tests/scenario_08_report_test.sh`
- `automation/tests/compose_network_isolation_test.sh`

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

The recovery tooling currently:

- copies brokers `0`, `1`, and `2` from an immutable snapshot into a disposable scenario work directory
- stages the copied source metadata log into the scenario workdir during `prepare` so later rewrite steps do not depend on direct container access to an external snapshot root
- captures `quorum-state` metadata and deterministically selects the input `.checkpoint`
- renders recovery config overlays for the 3-node target
- deletes copied metadata log state that must not be replayed directly
- resets copied metadata snapshot directories so stale side files are not replayed
- invokes the snapshot rewrite tool through the stable `bin/snapshot-rewrite-tool` entrypoint
- installs the rewritten checkpoint, metadata log, sidecar indexes, `leader-epoch-checkpoint`, and `quorum-state` into the copied metadata directories
- starts and stops the 3-node recovery cluster from the copied working data

## What Has Been Verified

These checks were completed successfully:

- shell syntax: `bash -n` across the new scripts
- Python syntax: `python3 -m py_compile` across the Python helpers
- helper behavior: fixture JSON generation, checkpoint-tool CLI help, and sample deterministic payload generation
- recovery cleanup helper behavior via `automation/tests/rewrite_cleanup_test.sh`
- compose network isolation guard via `automation/tests/compose_network_isolation_test.sh`
- real Scenario 01 recovery boot, assert, and report after:
  - `automation/recovery/down`
  - `automation/recovery/rewrite`
  - `automation/recovery/up`
  - `automation/scenarios/scenario-01/assert`
  - `automation/scenarios/scenario-01/report`
- real Scenario 02 recovery boot, assert, and report after:
  - `SNAPSHOTS_ROOT=<shared-snapshots-root> automation/recovery/prepare scenario-02 baseline-clean-v1 20260421T095313Z`
  - `automation/recovery/rewrite scenario-02 20260421T095313Z`
  - `automation/recovery/up scenario-02 20260421T095313Z`
  - `automation/scenarios/scenario-02/assert 20260421T095313Z`
  - `automation/scenarios/scenario-02/report 20260421T095313Z`
- containerized `tooling/snapshot-rewrite` Maven test suite after the Scenario 05 metadata-log boundary fix
- real Scenario 05 recovery boot, assert, and report after:
  - `automation/recovery/prepare scenario-05 baseline-clean-v2 20260421T113800Z`
  - `automation/recovery/rewrite scenario-05 20260421T113800Z`
  - `automation/recovery/up scenario-05 20260421T113800Z`
  - `automation/scenarios/scenario-05/assert 20260421T113800Z`
  - `automation/scenarios/scenario-05/report 20260421T113800Z`
- real Scenario 08 recovery boot, assert, and report after:
  - `SNAPSHOTS_ROOT=/private/tmp/poc-kafka-snapshot-recovery-scenario-05/fixtures/snapshots automation/recovery/prepare scenario-08 baseline-clean-v2 20260421T131900Z`
  - `automation/recovery/rewrite scenario-08 20260421T131900Z`
  - `automation/recovery/up scenario-08 20260421T131900Z`
  - `automation/scenarios/scenario-08/assert 20260421T131900Z`
  - `automation/scenarios/scenario-08/report 20260421T131900Z`

Important runtime detail:

- do not reuse a recovery workdir after a failed startup attempt
- failed boots can contaminate copied metadata state with new epochs
- the safe retry path is to rerun `prepare` and `rewrite`, or rebuild the scenario run directory, before the next `up`

## Known Gaps

- Scenarios 03, 04, 06, 07, 10, 11, and 12 are still planned work
- Scenario 03 still needs an explicit, reproducible fault-injection mechanism
- Scenario 07 still needs a no-host-dependency transactional probe
- Scenario 11 and Scenario 12 still need a report bundle convention and normalized diff strategy
- Scenario 09 remains intentionally deferred until the clean-stop suite is green

## Important Fixes Already Landed

- source and recovery Compose stacks no longer pin the same shared Docker network name
- copied metadata snapshot directories are now cleaned more aggressively before rewritten state is installed
- stale files such as `leader-epoch-checkpoint`, `quorum-state`, and leftover index files are not preserved in the rewritten metadata snapshot directory
- rewritten metadata logs now regenerate Kafka `.index` and `.timeindex` sidecars
- ELR state is now cleared during checkpoint and metadata-log rewrite so recovered controllers do not emit overlapping `ISR`/`ELR` errors
- worktree-based runs can point at shared snapshots via `SNAPSHOTS_ROOT`, and `prepare` now stages the source metadata log locally so `rewrite` stays container-safe even when the snapshots live outside the worktree
- the source fixture now lowers metadata snapshot thresholds so clean-stop snapshots reliably include real KRaft `.checkpoint` files
- metadata-log rewrite now treats checkpoint offsets as Kafka snapshot end offsets, so batches whose `baseOffset` equals the checkpoint boundary are preserved instead of rejected
- `prepare` now treats the broker that owns the selected checkpoint as the canonical metadata-log source when copied surviving brokers disagree byte-for-byte

These fixes matter because an earlier shared-network setup allowed recovery brokers to resolve source-cluster hostnames and join the wrong Raft peer, which looked like mysterious epoch jumps rather than an obvious wiring failure.

## First Commands To Run On The New Machine

From repo root:

```bash
sed -n '1,220p' AGENTS.md
sed -n '1,260p' docs/recovery/scenario-implementation-roadmap.md
sed -n '1,220p' docs/recovery/scenarios/scenario-04-consumer-offset-continuity.md
```

The latest green reports are:

```bash
sed -n '1,220p' docs/recovery/reports/runs/2026-04-21-scenario-01-20260421T084355Z.md
sed -n '1,220p' docs/recovery/reports/runs/2026-04-21-scenario-02-20260421T095313Z.md
sed -n '1,220p' docs/recovery/reports/runs/2026-04-21-scenario-05-20260421T113800Z.md
sed -n '1,220p' docs/recovery/reports/runs/2026-04-21-scenario-08-20260421T131900Z.md
```

Then resume from the next scenario:

```bash
sed -n '1,260p' docs/recovery/scenarios/scenario-04-consumer-offset-continuity.md
```

`<run-id>` is written into `fixtures/scenario-runs/<scenario-id>/<run-id>/run.env` by `automation/recovery/prepare`.

## Recommended Resume Order

1. Read `AGENTS.md`.
2. Read [`scenario-implementation-roadmap.md`](./scenario-implementation-roadmap.md).
3. Reconcile the scenario file being worked on with the roadmap and the current working tree.
4. Do the scenario-specific spec pass before code changes.
5. Implement the smallest failing-test slice.
6. Only then move to the next scenario in the roadmap order.

## Main Docs To Read Before Resuming

- [`AGENTS.md`](../../AGENTS.md)
- `docs/recovery/README.md`
- `docs/recovery/TODO.md`
- `docs/recovery/scenario-implementation-roadmap.md`
- `docs/recovery/harness-spec.md`
- `docs/recovery/source-fixture-spec.md`
- `docs/recovery/rewrite-tool-spec.md`
- `docs/recovery/scenarios/scenario-01-quorum-and-metadata.md`
- `docs/recovery/scenarios/scenario-05-config-preservation.md`
- `docs/recovery/scenarios/scenario-08-multiple-log-directories.md`
- `final-recovery-plan.md`

## Git Notes

- current branch in the active Scenario 08 worktree: `scenario-08`
- remote: `origin`
- local `.claude/` contains Claude worktree metadata and should stay out of normal repo commits
