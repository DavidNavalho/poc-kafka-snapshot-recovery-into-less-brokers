# Scenario 06: Compacted Topic Recovery

## Objective

Prove that compacted topics preserve the expected latest value per key after recovery, without relying on the log cleaner to have already physically removed older versions.

## Status

- Phase: 1
- State: Implemented
- Scenario 01, Scenario 02, Scenario 05, and Scenario 08 are prerequisites and already green
- Latest clean run: `20260421T141350Z`
- Delivered automation:
  - `automation/lib/probe_compacted_topic_state.py`
  - `automation/scenarios/scenario-06/assert`
  - `automation/scenarios/scenario-06/report`
  - `automation/tests/scenario_06_assert_test.sh`
  - `automation/tests/scenario_06_report_test.sh`

## Depends On

- Scenario 01 green
- Scenario 02 green
- Scenario 05 green
- Scenario 08 green
- canonical snapshot label `baseline-clean-v3`
- canonical source fixture must include repeated keys and explicit latest-value expectation files
- recovery cluster compose spec
- repo-managed Python toolbox with `confluent-kafka`
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without scenario-specific extensions.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v3/manifest.json`
- `fixtures/scenario-runs/scenario-06/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-06/<run-id>/run.env`
- `fixtures/scenario-runs/scenario-06/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `snapshot-manifest.json.topics[]`
- `snapshot-manifest.json.expectation_files.compacted_latest_values`
- the expectation files referenced by `snapshot-manifest.json.expectation_files.compacted_latest_values`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the compacted-data semantics gate after Scenario 01 proves the metadata path boots, Scenario 02 proves representative topic data is readable, Scenario 05 proves config state survives, and Scenario 08 proves the multi-log-dir layout survives.

It proves:

- the compacted topics still exist after recovery and retain the compaction-related dynamic configs declared in the manifest
- replaying the recovered compacted topics from the beginning reconstructs the exact latest value per key declared in the source expectation files
- the recovery logs do not show narrow, explicit cleaner-failure patterns while those topics are being exercised

It does **not** prove:

- that the log cleaner has already physically compacted older records away on disk
- tombstone semantics beyond preserving the latest logical state
- consumer-group continuity
- transaction-state correctness
- storage-layout safety checks beyond what Scenario 08 already covers

Those belong to other scenarios.

## Concrete Inputs

The Scenario 06 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v3`
- surviving brokers: `0,1,2`
- directory mode: `UNASSIGNED`
- in-scope compacted topics:
  - `recovery.compacted.accounts`
  - `recovery.compacted.orders`
- expected per-topic partition count: `6`
- expected keys per partition: `100`
- expected versions per key in source history: `10`
- expected latest value for every in-scope key: `v09`

Expected latest-value maps must come only from the expectation files referenced by:

- `snapshot-manifest.json.expectation_files.compacted_latest_values["recovery.compacted.accounts"]`
- `snapshot-manifest.json.expectation_files.compacted_latest_values["recovery.compacted.orders"]`

Those relative expectation-file paths must be resolved against:

- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/`

Normalization and timing rules:

- the assert step should consume each compacted topic from the beginning and reconstruct the final latest-value map by keeping the last seen non-null value for each key
- if a future fixture revision introduces tombstones, a null value should delete the key from the reconstructed map rather than be retained as a literal string
- no explicit wait for the log cleaner is required before asserting; the latest-value check is based on full replay semantics, not on physical record removal timing
- compare normalized latest-value maps as sorted JSON objects so consumer ordering does not create false diffs
- preserve the raw replay result and a copied expected JSON file for each topic as artifacts
- allow each replay probe up to `45` seconds to reach partition EOF across all six partitions

## Preconditions

Before `run` starts, all of the following must be true:

1. Scenario 01 is green on the current harness branch.
2. Scenario 02 is green on the current harness branch.
3. Scenario 05 is green on the current harness branch.
4. Scenario 08 is green on the current harness branch.
5. `automation/recovery/prepare scenario-06 <snapshot-label> [run-id]` completed successfully.
6. `run.env` exists under `fixtures/scenario-runs/scenario-06/<run-id>/run.env`.
7. `snapshot-manifest.json` exists in the scenario workdir and contains:
   - both in-scope compacted topics listed above
   - exact topic configs for `cleanup.policy=compact` and `min.cleanable.dirty.ratio=0.1`
   - `expectation_files.compacted_latest_values` entries for both in-scope compacted topics
8. the immutable snapshot root referenced by `SNAPSHOT_SOURCE_ROOT` contains the expectation files referenced by the manifest
9. The workdir was created fresh for this run. A previously failed Scenario 06 workdir must not be reused.

Worktree note:

- generated snapshot data is ignored by Git and does not automatically appear in a new Git worktree
- if Scenario 06 is run from a scenario-specific worktree, point `SNAPSHOTS_ROOT` at the shared snapshot directory before running `prepare`

## Recovery Procedure

### Prepare

Run:

```bash
SNAPSHOTS_ROOT=<shared-snapshots-root> \
automation/recovery/prepare scenario-06 baseline-clean-v3 [run-id]
```

If the current worktree already contains `fixtures/snapshots/baseline-clean-v3`, the explicit `SNAPSHOTS_ROOT` override is not required.

Expected outputs:

- `run.env`
- `snapshot-manifest.json`
- `artifacts/prepare/quorum-state.json`
- `artifacts/prepare/selected-checkpoint.json`
- rendered recovery configs for brokers `0`, `1`, and `2`

### Rewrite

Run:

```bash
automation/recovery/rewrite scenario-06 <run-id>
```

### Start

Run:

```bash
automation/recovery/up scenario-06 <run-id>
```

### Assert

Run a scenario-specific assert entrypoint once `up` succeeds:

```bash
automation/scenarios/scenario-06/assert <run-id>
```

The assert step is responsible for all pass/fail checks below and must write its outputs under:

- `fixtures/scenario-runs/scenario-06/<run-id>/artifacts/assert/`

### Report

Run:

```bash
automation/scenarios/scenario-06/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-06-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-06 <run-id>
```

If `up` or `assert` fails, teardown is still required before any rerun.

## Assertions

Scenario 06 should fail only on the assertions below.

### A1: Compacted Topics Retain The Required Dynamic Compaction Configs

Sources:

- `snapshot-manifest.json.topics[]`
- `artifacts/assert/configs/<topic>.config.txt`
- `artifacts/assert/configs/<topic>.normalized.json`

Pass criteria:

- each in-scope compacted topic is present in the manifest
- the normalized recovered dynamic config object exactly equals the manifest `configs` object for that topic
- `cleanup.policy` includes `compact`
- no expected config key is missing and no extra dynamic key appears

### A2: Reconstructed Latest-Value Maps Match The Snapshot Expectation Files Exactly

Sources:

- `${SNAPSHOT_SOURCE_ROOT}/${SNAPSHOT_LABEL}/<expectation-relative-path>`
- `artifacts/assert/compacted/<topic>.expected.json`
- `artifacts/assert/compacted/<topic>.actual.json`
- `artifacts/assert/compacted/<topic>.replay.json`

Pass criteria:

- for each in-scope compacted topic, the copied expected latest-value map exactly equals the reconstructed latest-value map
- no expected key is missing
- no unexpected key appears
- the replay probe reports zero errors and reaches partition EOF on all six partitions

### A3: Recovery Logs Show No Narrow Cleaner-Failure Patterns While Compact Topics Are Exercised

Sources:

- `artifacts/recovery/docker-compose.log`
- `artifacts/assert/cleaner-scan.txt`

Pass criteria:

- the recovery logs do not contain lines matching the scenario denylist for cleaner-related failures
- a log line should fail this assertion only if it indicates an error, exception, or thread exit tied to log cleaning

## Evidence Artifacts

Scenario 06 should retain at least these artifacts:

- `artifacts/assert/configs/<topic>.config.txt`
- `artifacts/assert/configs/<topic>.normalized.json`
- `artifacts/assert/compacted/<topic>.expected.json`
- `artifacts/assert/compacted/<topic>.actual.json`
- `artifacts/assert/compacted/<topic>.replay.json`
- `artifacts/assert/cleaner-scan.txt`
- `artifacts/assert/recovery-ps.txt`
- `artifacts/assert/assert-summary.json`
- `artifacts/recovery/docker-compose.log`

## Automation Contract

- `prepare`: `automation/recovery/prepare scenario-06 <snapshot-label> [run-id]`
- `run`: `automation/recovery/rewrite scenario-06 <run-id>` then `automation/recovery/up scenario-06 <run-id>`
- `assert`: `automation/scenarios/scenario-06/assert <run-id>`
- `report`: `automation/scenarios/scenario-06/report <run-id>`
- `teardown`: `automation/recovery/down scenario-06 <run-id>`

The Scenario 06 assert path should:

- read expectation-file paths from `snapshot-manifest.json` rather than inferring them from topic names
- resolve those expectation files through `SNAPSHOT_SOURCE_ROOT` and copy them into the scenario artifacts for stable reporting
- use a repo-managed containerized helper for replaying compacted topics and reconstructing latest values
- compare normalized JSON artifacts, not raw consumer line order

## Manual Fallback

Consume the compacted topics from the beginning with key printing enabled, reduce the output to the last value per key, and compare that reduced map to the compacted expectation files stored in the immutable snapshot.

## Fault Injection And Rollback

Scenario 06 is a happy-path workload-semantics scenario. No dedicated fault injection is required in this slice.

If the scenario fails after cluster start:

- preserve the config dumps, expected-vs-actual latest-value maps, replay output, and cleaner scan
- run `automation/recovery/down scenario-06 <run-id>`
- rebuild the scenario workdir with a fresh `prepare` and `rewrite` before retrying
