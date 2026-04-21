# Scenario 03: Stray Detection Safety Net

## Objective

Prove two things:

1. the clean happy path does not produce stray directories or stray-related startup failures
2. an explicit metadata assignment fault can force a known partition into Kafka stray handling without losing data, because the recovery config extends `file.delete.delay.ms` to `86400000`

## Status

- Phase: 1
- State: Implemented
- Scenario 01, Scenario 02, Scenario 05, and Scenario 08 are prerequisites and already green
- Canonical fixture revision for this scenario: `baseline-clean-v3`
- Latest clean run: `20260421T154928Z`
- Latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-03-20260421T154928Z.md`
- Delivered automation: `automation/scenarios/scenario-03/assert`, `automation/scenarios/scenario-03/report`
- Supporting tests landed in `automation/tests/scenario_03_assert_test.sh` and `automation/tests/scenario_03_report_test.sh`

## Depends On

- Scenario 01 green
- Scenario 02 green
- Scenario 05 green
- Scenario 08 green
- canonical snapshot label `baseline-clean-v3`
- the shared snapshot rewrite tool must support a deterministic partition-replica fault override
- recovery cluster compose spec
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without a new source-cluster flavor.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v3/manifest.json`
- `fixtures/scenario-runs/scenario-03/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-03/<run-id>/run.env`
- `fixtures/scenario-runs/scenario-03/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `fixtures/scenario-runs/scenario-03/<run-id>/artifacts/rewrite/rewrite-report.json`
- `fixtures/scenario-runs/scenario-03/<run-id>/artifacts/rewrite/<checkpoint-basename>`
- `fixtures/scenario-runs/scenario-03/<run-id>/artifacts/rewrite/00000000000000000000.log`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the first deliberate negative-path harness check after the clean recovery path is already proven by Scenario 01, Scenario 02, Scenario 05, and Scenario 08.

It proves:

- the normal clean-stop recovery path does not accidentally trigger stray handling
- the harness can inject a deterministic metadata assignment fault against an already-correct rewritten snapshot
- Kafka renames the affected on-disk partition directory to `*-stray` for the injected mismatch
- the partition data remains present inside that stray directory while the extended delete-delay window is still open
- restoring the clean rewritten metadata and renaming the stray directory back allows a clean restart

It does **not** prove:

- arbitrary metadata corruption recovery
- rollback after the delete-delay window actually expires
- post-recovery replica reassignment or RF expansion
- crash-consistent or live-snapshot stray handling

Those belong to later negative or operational scenarios.

## Concrete Inputs

The Scenario 03 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v3`
- surviving brokers: `0,1,2`
- directory mode: `UNASSIGNED`
- representative topic for the injected fault and restored read check: `recovery.default.6p`
- injected topic-partition: `recovery.default.6p-0`
- expected recovered owner before fault injection: broker `0`
- expected recovered directory before fault injection:
  - `brokers/broker-0/logdir-0/recovery.default.6p-0`
- injected replica set:
  - `replicas = [8]`
  - `isr = [8]`
  - `leader = 8`
- expected stray path after injected boot:
  - `brokers/broker-0/logdir-0/recovery.default.6p-0.<token>-stray`

The negative case should mutate the already-correct rewritten artifacts from:

- `artifacts/rewrite/<checkpoint-basename>`
- `artifacts/rewrite/00000000000000000000.log`

The negative case must not skip the normal rewrite step entirely. That would test a broader 9-node assignment mismatch, not the narrow stray-safety behavior this scenario is trying to isolate.

Normalization and timing rules:

- treat the positive case as a narrow reuse of the Scenario 01 startup denylist for stray-related failures only
- treat the injected negative case as successful once the target stray directory appears and contains Kafka partition files
- allow up to `45` seconds for the injected stray directory to appear after the negative boot starts
- preserve directory listings before fault injection, after Kafka renames the directory to `<topic>-<partition>.<token>-stray`, and after manual rename-back
- preserve the negative-case recovery logs separately from the happy-path and restored-path logs
- rollback must happen only after the negative cluster is stopped
- the negative workdir is disposable; never reuse it across reruns

## Preconditions

Before `run` starts, all of the following must be true:

1. Scenario 01 is green on the current harness branch.
2. Scenario 02 is green on the current harness branch.
3. Scenario 05 is green on the current harness branch.
4. Scenario 08 is green on the current harness branch.
5. `automation/recovery/prepare scenario-03 <snapshot-label> [run-id]` completed successfully.
6. `automation/recovery/rewrite scenario-03 <run-id>` completed successfully.
7. `automation/recovery/up scenario-03 <run-id>` completed successfully.
8. `run.env` exists under `fixtures/scenario-runs/scenario-03/<run-id>/run.env`.
9. `snapshot-manifest.json` exists in the scenario workdir and contains `recovery.default.6p` with exact `expected_latest_offsets` entries for partitions `0..5`.
10. `artifacts/rewrite/` contains a clean rewritten checkpoint, metadata log, `.index`, `.timeindex`, and rewrite report.
11. The immutable snapshot root referenced by `SNAPSHOT_SOURCE_ROOT` contains `baseline-clean-v3`.
12. The workdir was created fresh for this run. A previously failed Scenario 03 workdir must not be reused.

Worktree note:

- generated snapshot data is ignored by Git and does not automatically appear in a new Git worktree
- if Scenario 03 is run from a scenario-specific worktree, point `SNAPSHOTS_ROOT` at the shared snapshot directory before running `prepare`

## Recovery Procedure

### Prepare

Run:

```bash
SNAPSHOTS_ROOT=<shared-snapshots-root> \
automation/recovery/prepare scenario-03 baseline-clean-v3 [run-id]
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
automation/recovery/rewrite scenario-03 <run-id>
```

### Start

Run:

```bash
automation/recovery/up scenario-03 <run-id>
```

### Assert

Run:

```bash
automation/scenarios/scenario-03/assert <run-id>
```

The assert step must:

1. validate the positive case on the already-running recovery cluster
2. stop that cluster
3. create an isolated negative-path clone of the recovered workdir
4. mutate the clean rewritten checkpoint and metadata log for `recovery.default.6p-0` so the final metadata assigns it to broker `8`
5. boot the negative clone and wait for the target directory to be renamed to `<topic>-<partition>.<token>-stray`
6. capture evidence that the partition data still exists inside the stray directory
7. stop the negative cluster
8. restore the clean rewritten metadata files into the negative clone
9. rename `*-stray` back to the original partition directory name
10. restart the negative clone and verify the restored recovery is clean

### Report

Run:

```bash
automation/scenarios/scenario-03/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-03-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-03 <run-id>
```

If `assert` stops the original recovery project and finishes on the negative clone, teardown should still tolerate an already-stopped base project.

## Assertions

Scenario 03 should fail only on the assertions below.

### A1: Happy-Path Recovery Produces No Stray Directories Or Explicit Stray Startup Failures

Sources:

- `artifacts/assert/positive/recovery-ps.txt`
- `artifacts/assert/positive/recovery.log`
- `artifacts/assert/positive/stray-scan.txt`
- `artifacts/assert/positive/startup-failure-scan.txt`

Pass criteria:

- there are zero `*-stray` directories under `fixtures/scenario-runs/scenario-03/<run-id>/brokers/broker-{0,1,2}/logdir-{0,1}`
- the happy-path recovery log contains no explicit `stray` or `-stray` startup failures
- the check reuses the same narrow denylist style as Scenario 01 instead of failing on every `ERROR` line

### A2: The Injected Metadata Fault Creates The Expected Stray Directory

Sources:

- `artifacts/assert/negative/fault-override-command.txt`
- `artifacts/assert/negative/recovery.log`
- `artifacts/assert/negative/pre-boot.broker-0.logdir-0.txt`
- `artifacts/assert/negative/post-boot.broker-0.logdir-0.txt`
- `artifacts/assert/negative/stray-dirs.txt`

Pass criteria:

- the negative-path helper writes a deterministic override command that targets `recovery.default.6p-0`
- after the injected boot, `brokers/broker-0/logdir-0/recovery.default.6p-0.<token>-stray` exists
- the original non-stray directory name is absent at that point
- the negative recovery log contains at least one narrow stray-handling line for the injected partition

### A3: Data Remains Present Inside The Stray Directory During The Safety Window

Sources:

- `artifacts/assert/negative/recovery.default.6p-0-stray.contents.txt`
- `artifacts/assert/negative/recovery.default.6p-0-stray.partition-metadata.txt`

Pass criteria:

- the target stray directory still contains Kafka partition files after the negative boot
- `partition.metadata` is still present inside the stray directory
- the directory was inspected before rollback, while the cluster was still within the configured `86400000` delete-delay window

### A4: Restoring The Clean Metadata And Renaming The Directory Back Allows A Clean Restart

Sources:

- `artifacts/assert/restored/recovery.log`
- `artifacts/assert/restored/recovery-ps.txt`
- `artifacts/assert/restored/stray-scan.txt`
- `artifacts/assert/restored/quorum-status.txt`
- `artifacts/assert/restored/topics/recovery.default.6p.describe.txt`
- `artifacts/assert/restored/topics/recovery.default.6p.unavailable.txt`
- `artifacts/assert/restored/samples/recovery.default.6p.p0.count.txt`

Pass criteria:

- the restored cluster boots and `kafka-metadata-quorum --describe --status` succeeds
- there are zero `*-stray` directories after the restored restart
- `recovery.default.6p --unavailable-partitions` is empty
- consuming partition `0` from the beginning yields the manifest-backed expected latest offset for `recovery.default.6p-0`

Implementation note:

- this is the positive-case reuse point from Scenario 01: keep the restored-path validation narrow and focused on readiness, quorum, topic availability, and stray absence instead of duplicating every Scenario 01 assertion verbatim

## Automation Contract

- `prepare`: `automation/recovery/prepare scenario-03 <snapshot-label> [run-id]`
- `run`: `automation/recovery/rewrite scenario-03 <run-id>` then `automation/recovery/up scenario-03 <run-id>`
- `assert`: `automation/scenarios/scenario-03/assert <run-id>`
- `report`: `automation/scenarios/scenario-03/report <run-id>`
- `teardown`: `automation/recovery/down scenario-03 <run-id>`

The new `assert` entrypoint must write at least:

- `artifacts/assert/positive/recovery.log`
- `artifacts/assert/positive/recovery-ps.txt`
- `artifacts/assert/positive/stray-scan.txt`
- `artifacts/assert/positive/startup-failure-scan.txt`
- `artifacts/assert/negative/fault-override-command.txt`
- `artifacts/assert/negative/pre-boot.broker-0.logdir-0.txt`
- `artifacts/assert/negative/post-boot.broker-0.logdir-0.txt`
- `artifacts/assert/negative/stray-dirs.txt`
- `artifacts/assert/negative/recovery.log`
- `artifacts/assert/negative/recovery.default.6p-0-stray.contents.txt`
- `artifacts/assert/negative/recovery.default.6p-0-stray.partition-metadata.txt`
- `artifacts/assert/restored/recovery.log`
- `artifacts/assert/restored/recovery-ps.txt`
- `artifacts/assert/restored/stray-scan.txt`
- `artifacts/assert/restored/quorum-status.txt`
- `artifacts/assert/restored/topics/recovery.default.6p.describe.txt`
- `artifacts/assert/restored/topics/recovery.default.6p.unavailable.txt`
- `artifacts/assert/restored/samples/recovery.default.6p.p0.count.txt`
- `artifacts/assert/assert-summary.json`

The new `report` entrypoint must:

- summarize the happy-path, injected, and restored phases separately
- link to the override command, directory listings, stray evidence, restored quorum output, topic describe output, and recovery logs
- make it obvious whether a failure happened before fault injection, during stray creation, or during rollback/restart

## Manual Fallback

If the automated negative case fails mid-run, stop the negative cluster, restore the clean rewritten checkpoint and metadata log into the affected metadata directories, rename any `*-stray` directories back to their original names, then restart and verify quorum and topic availability manually.

## Report Artifacts

- happy-path stray scan and narrow startup-failure scan output
- negative-path override command and broker-0/logdir-0 directory listings before and after stray rename
- negative-path stray directory contents for `recovery.default.6p-0.<token>-stray`
- restored-path quorum output, topic describe output, unavailable-partition output, and partition `0` consume count
- happy-path, negative-path, and restored-path recovery logs
