# Scenario 08: Multiple Log Directories

## Objective

Prove that the recovery works when each broker uses two `log.dirs`, and that the rewritten metadata can load partitions regardless of which disk they live on.

## Status

- Phase: 1
- State: Implemented
- Scenario 01, Scenario 02, and Scenario 05 are prerequisites and already green
- Latest clean run: `20260421T131900Z`
- Latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-08-20260421T131900Z.md`
- Delivered automation: `automation/scenarios/scenario-08/assert`, `automation/scenarios/scenario-08/report`
- Supporting tests landed in `automation/tests/scenario_08_assert_test.sh` and `automation/tests/scenario_08_report_test.sh`

## Depends On

- Scenario 01 green
- Scenario 02 green
- Scenario 05 green
- canonical snapshot label `baseline-clean-v2`
- canonical source fixture must already use two `log.dirs` per broker
- source manifest must record `cluster.log_dirs_per_broker = 2`
- recovery cluster compose spec
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without scenario-specific extensions.

This scenario relies on the canonical cluster being multi-log-dir from the start. No separate source-cluster flavor should be required.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v2/manifest.json`
- `fixtures/scenario-runs/scenario-08/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-08/<run-id>/run.env`
- `fixtures/scenario-runs/scenario-08/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `run.env` values:
  - `SNAPSHOT_SOURCE_ROOT`
  - `SNAPSHOT_LABEL`
  - `WORKDIR`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the storage-layout gate after Scenario 01 proves the metadata path boots, Scenario 02 proves representative data is readable, and Scenario 05 proves config state survives.

It proves:

- every surviving broker still has valid user partition directories under both recovered `log.dirs`
- the recovered `logdir-0` and `logdir-1` identities remain consistent with the source snapshot and with the broker they belong to
- the happy-path recovery does not produce stray directories or multi-disk identity failures
- representative partitions whose replicas are distributed across both disk roots remain readable from the beginning

It does **not** prove:

- consumer-group continuity
- compacted-topic latest-value semantics
- transaction-state correctness
- deliberate stray fault injection and repair
- post-recovery partition reassignment or expansion

Those belong to Scenarios 03, 04, 06, 07, and 10.

## Concrete Inputs

The Scenario 08 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v2`
- surviving brokers: `0,1,2`
- directory mode: `UNASSIGNED`
- in-scope recovery log directories:
  - `logdir-0`
  - `logdir-1`
- representative multi-disk readability topic:
  - `recovery.default.6p`
- representative multi-disk partition placements from the canonical source snapshot:
  - broker `0`, `logdir-0`: `recovery.default.6p-1`
  - broker `0`, `logdir-1`: `recovery.default.6p-4`
  - broker `1`, `logdir-0`: `recovery.default.6p-5`
  - broker `1`, `logdir-1`: `recovery.default.6p-2`
  - broker `2`, `logdir-0`: `recovery.default.6p-0`
  - broker `2`, `logdir-1`: `recovery.default.6p-3`

Expected latest offsets for `recovery.default.6p` must come only from `snapshot-manifest.json.topics[].expected_latest_offsets`.

Expected on-disk user partition directory sets and `meta.properties` contents must come from the immutable source snapshot referenced by:

- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/logdir-0`
- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/logdir-1`
- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/metadata`

Normalization rules:

- compare partition directory names only, not per-file checksums inside each partition directory
- compare only topic-partition directories and ignore maintenance files such as:
  - `.kafka_cleanshutdown`
  - `bootstrap.checkpoint`
  - `cleaner-offset-checkpoint`
  - `log-start-offset-checkpoint`
  - `recovery-point-offset-checkpoint`
  - `replication-offset-checkpoint`
- preserve raw directory listings and raw `meta.properties` files as artifacts
- `meta.properties` comparisons should normalize comment lines away before key comparison

## Assertions

## Preconditions

Before `run` starts, all of the following must be true:

1. Scenario 01 is green on the current harness branch.
2. Scenario 02 is green on the current harness branch.
3. Scenario 05 is green on the current harness branch.
4. `automation/recovery/prepare scenario-08 <snapshot-label> [run-id]` completed successfully.
5. `run.env` exists under `fixtures/scenario-runs/scenario-08/<run-id>/run.env`.
6. `snapshot-manifest.json` exists in the scenario workdir and contains:
   - `cluster.log_dirs_per_broker = 2`
   - the topic `recovery.default.6p`
   - exact `expected_latest_offsets` entries for partitions `0..5`
7. The immutable source snapshot referenced by `SNAPSHOT_SOURCE_ROOT` contains `logdir-0` and `logdir-1` for brokers `0`, `1`, and `2`.
8. The workdir was created fresh for this run. A previously failed Scenario 08 workdir must not be reused.

Worktree note:

- generated snapshot data is ignored by Git and does not automatically appear in a new Git worktree
- if Scenario 08 is run from a scenario-specific worktree, point `SNAPSHOTS_ROOT` at the shared snapshot directory before running `prepare`

## Recovery Procedure

### Prepare

Run:

```bash
SNAPSHOTS_ROOT=<shared-snapshots-root> \
automation/recovery/prepare scenario-08 baseline-clean-v2 [run-id]
```

If the current worktree already contains `fixtures/snapshots/baseline-clean-v2`, the explicit `SNAPSHOTS_ROOT` override is not required.

Expected outputs:

- `run.env`
- `snapshot-manifest.json`
- `artifacts/prepare/quorum-state.json`
- `artifacts/prepare/selected-checkpoint.json`
- rendered recovery configs for brokers `0`, `1`, and `2`

### Rewrite

Run:

```bash
automation/recovery/rewrite scenario-08 <run-id>
```

### Start

Run:

```bash
automation/recovery/up scenario-08 <run-id>
```

### Assert

Run a scenario-specific assert entrypoint once `up` succeeds:

```bash
automation/scenarios/scenario-08/assert <run-id>
```

The assert step is responsible for all pass/fail checks below and must write its outputs under:

- `fixtures/scenario-runs/scenario-08/<run-id>/artifacts/assert/`

### Report

Run:

```bash
automation/scenarios/scenario-08/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-08-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-08 <run-id>
```

If `up` or `assert` fails, teardown is still required before any rerun.

## Assertions

Scenario 08 should fail only on the assertions below.

### A1: Recovered User Partition Directories Match The Source Snapshot Across Both Log Dirs

Sources:

- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/logdir-0`
- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/logdir-1`
- `fixtures/scenario-runs/scenario-08/<run-id>/brokers/broker-<id>/logdir-0`
- `fixtures/scenario-runs/scenario-08/<run-id>/brokers/broker-<id>/logdir-1`
- `artifacts/assert/logdirs/broker-<id>.logdir-<n>.source-partitions.txt`
- `artifacts/assert/logdirs/broker-<id>.logdir-<n>.recovered-partitions.txt`

Pass criteria:

- for each surviving broker `0`, `1`, and `2`, the recovered user partition directory-name set under `logdir-0` exactly equals the source snapshot set
- for each surviving broker `0`, `1`, and `2`, the recovered user partition directory-name set under `logdir-1` exactly equals the source snapshot set
- neither recovered logdir is empty of user partition directories

### A2: Meta.Properties Identity Remains Consistent Across Both Recovered Log Dirs

Sources:

- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/logdir-0/meta.properties`
- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/logdir-1/meta.properties`
- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/brokers/broker-<id>/metadata/meta.properties`
- `artifacts/assert/meta/broker-<id>.logdir-0.meta.properties`
- `artifacts/assert/meta/broker-<id>.logdir-1.meta.properties`
- `artifacts/assert/meta/broker-<id>.metadata.meta.properties`
- `snapshot-manifest.json`

Pass criteria:

- for each surviving broker `0`, `1`, and `2`, recovered `logdir-0/meta.properties` exactly matches the source snapshot file after comment normalization
- for each surviving broker `0`, `1`, and `2`, recovered `logdir-1/meta.properties` exactly matches the source snapshot file after comment normalization
- recovered `cluster.id` equals `snapshot-manifest.json.cluster.cluster_id`
- recovered `node.id` equals the broker ID for both logdirs
- recovered `directory.id` is non-empty in both logdirs and the two logdirs for a broker do not share the same `directory.id`

### A3: Happy-Path Recovery Produces No Stray Directories Or Multi-Disk Identity Failures

Sources:

- `artifacts/recovery/docker-compose.log`
- `artifacts/assert/stray-scan.txt`
- `artifacts/assert/startup-failure-scan.txt`

Pass criteria:

- there are zero `*-stray` directories under `fixtures/scenario-runs/scenario-08/<run-id>/brokers/broker-{0,1,2}/logdir-{0,1}`
- recovery logs contain no explicit stray-handling lines
- recovery logs contain no explicit `meta.properties` identity failure lines

Implementation note:

- reuse the narrow denylist style from Scenario 01 rather than failing on every `ERROR` line

### A4: Representative Multi-Disk Partitions Remain Readable From The Beginning

Sources:

- `snapshot-manifest.json.topics[].expected_latest_offsets`
- `artifacts/assert/topics/recovery.default.6p.describe.txt`
- `artifacts/assert/topics/recovery.default.6p.unavailable.txt`
- `artifacts/assert/samples/recovery.default.6p.p<partition>.count.txt`
- `artifacts/assert/samples/recovery.default.6p.p<partition>.preview.txt`

Pass criteria:

- `recovery.default.6p` describes successfully
- `recovery.default.6p --unavailable-partitions` is empty
- partitions `0..5` are all consumable from the beginning
- the consumed record count for each partition exactly equals the manifest-backed expected latest offset

This topic is the scenario’s representative read probe because the canonical snapshot places one partition on each surviving broker/logdir pair.

## Automation Contract

- `prepare`: `automation/recovery/prepare scenario-08 <snapshot-label> [run-id]`
- `run`: `automation/recovery/rewrite scenario-08 <run-id>` then `automation/recovery/up scenario-08 <run-id>`
- `assert`: `automation/scenarios/scenario-08/assert <run-id>`
- `report`: `automation/scenarios/scenario-08/report <run-id>`
- `teardown`: `automation/recovery/down scenario-08 <run-id>`

The new `assert` entrypoint must write at least:

- `artifacts/assert/logdirs/broker-<id>.logdir-<n>.source-partitions.txt`
- `artifacts/assert/logdirs/broker-<id>.logdir-<n>.recovered-partitions.txt`
- `artifacts/assert/meta/broker-<id>.logdir-0.meta.properties`
- `artifacts/assert/meta/broker-<id>.logdir-1.meta.properties`
- `artifacts/assert/meta/broker-<id>.metadata.meta.properties`
- `artifacts/assert/startup-failure-scan.txt`
- `artifacts/assert/stray-scan.txt`
- `artifacts/assert/topics/recovery.default.6p.describe.txt`
- `artifacts/assert/topics/recovery.default.6p.unavailable.txt`
- `artifacts/assert/samples/recovery.default.6p.p<partition>.count.txt`
- `artifacts/assert/samples/recovery.default.6p.p<partition>.preview.txt`
- `artifacts/assert/assert-summary.json`

The new `report` entrypoint must:

- summarize the per-broker multi-disk evidence at a human-readable level
- link to the logdir listings, `meta.properties` extracts, topic describe output, sample consume outputs, and recovery logs
- identify whether any mismatch was due to directory-set drift, identity drift, stray evidence, or read failures

## Manual Fallback

Inspect both source and recovered log-directory roots directly on disk, compare the `meta.properties` files, then run topic describe and per-partition consume checks for `recovery.default.6p`.

## Report Artifacts

- per-broker directory listings for both source and recovered log dirs
- `meta.properties` extracts for both log dirs and the metadata dir
- stray scan output and narrow startup failure scan output
- topic describe and unavailable-partition output for `recovery.default.6p`
- per-partition consume counts and previews for `recovery.default.6p`
