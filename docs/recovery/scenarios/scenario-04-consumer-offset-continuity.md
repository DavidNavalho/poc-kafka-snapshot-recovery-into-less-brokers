# Scenario 04: Consumer Offset Continuity

## Objective

Prove that canonical consumer groups survive recovery with their committed offsets intact, and that real consumers resume from those inherited positions rather than from the beginning or end of the topic.

## Status

- Phase: 1
- State: Implemented
- Scenario 01, Scenario 02, Scenario 05, and Scenario 08 are prerequisites and already green
- Latest clean run: `20260421T134100Z`
- Latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-04-20260421T134100Z.md`
- Delivered automation: `automation/scenarios/scenario-04/assert`, `automation/scenarios/scenario-04/report`
- Supporting helpers landed in `automation/lib/common.sh` and `automation/lib/probe_consumer_group_resume.py`

## Depends On

- Scenario 01 green
- Scenario 02 green
- Scenario 05 green
- Scenario 08 green
- canonical snapshot label `baseline-clean-v2`
- source manifest must record committed offsets for the canonical consumer groups
- recovery cluster compose spec
- repo-managed Python toolbox with `confluent-kafka`
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without scenario-specific extensions.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v2/manifest.json`
- `fixtures/scenario-runs/scenario-04/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-04/<run-id>/run.env`
- `fixtures/scenario-runs/scenario-04/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `snapshot-manifest.json.topics[]`
- `snapshot-manifest.json.consumer_groups[]`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the consumer-state gate after Scenario 01 proves the metadata path boots, Scenario 02 proves representative partition data is readable, Scenario 05 proves config state survives, and Scenario 08 proves the multi-log-dir layout survives recovery.

It proves:

- the expected canonical consumer groups still exist after recovery
- the recovered committed offsets for those groups exactly match the snapshot manifest
- a real consumer using the recovered group ID starts from the inherited committed offsets on every partition
- no partition silently resets to the beginning or skips ahead during the first resumed read

It does **not** prove:

- active consumer rebalances under multi-member load
- lag monitoring accuracy beyond the captured offsets
- transaction-aware consumer semantics
- post-recovery offset commits or further consumer progress
- negative-path fault injection for missing or corrupted `__consumer_offsets`

Those belong to later workload or negative scenarios.

## Concrete Inputs

The Scenario 04 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v2`
- surviving brokers: `0,1,2`
- directory mode: `UNASSIGNED`
- in-scope topic: `recovery.consumer.test`
- in-scope topic partition count: `12`
- in-scope consumer groups:
  - `recovery.group.25` with expected committed offset `2000` on partitions `0..11`
  - `recovery.group.50` with expected committed offset `4000` on partitions `0..11`
  - `recovery.group.75` with expected committed offset `6000` on partitions `0..11`

Expected committed offsets must come only from `snapshot-manifest.json.consumer_groups[]`.

Normalization and timing rules:

- compare only the manifest-declared partitions for `recovery.consumer.test`
- preserve raw `kafka-consumer-groups --describe` output for each group as an artifact
- normalize recovered committed offsets into sorted JSON objects keyed by partition ID so CLI formatting does not create false diffs
- treat the acceptable committed-offset drift after recovery as exact equality; no offset drift is allowed in the clean-stop happy path
- allow a stabilization wait of up to `60` seconds, checked every `2` seconds, for `__consumer_offsets` to surface all expected group partitions after recovery boot
- allow each resumed-consumer probe up to `45` seconds to observe the first message from every partition
- resume probes must use the recovered group IDs and must not auto-commit new offsets during the assertion step

## Preconditions

Before `run` starts, all of the following must be true:

1. Scenario 01 is green on the current harness branch.
2. Scenario 02 is green on the current harness branch.
3. Scenario 05 is green on the current harness branch.
4. Scenario 08 is green on the current harness branch.
5. `automation/recovery/prepare scenario-04 <snapshot-label> [run-id]` completed successfully.
6. `run.env` exists under `fixtures/scenario-runs/scenario-04/<run-id>/run.env`.
7. `snapshot-manifest.json` exists in the scenario workdir and contains:
   - the topic `recovery.consumer.test`
   - `partitions = 12` for that topic
   - exactly the three canonical consumer groups listed above
   - exact `expected_committed_offsets` entries for partitions `0..11` on each group
8. The workdir was created fresh for this run. A previously failed Scenario 04 workdir must not be reused.

Worktree note:

- generated snapshot data is ignored by Git and does not automatically appear in a new Git worktree
- if Scenario 04 is run from a scenario-specific worktree, point `SNAPSHOTS_ROOT` at the shared snapshot directory before running `prepare`

## Recovery Procedure

### Prepare

Run:

```bash
SNAPSHOTS_ROOT=<shared-snapshots-root> \
automation/recovery/prepare scenario-04 baseline-clean-v2 [run-id]
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
automation/recovery/rewrite scenario-04 <run-id>
```

### Start

Run:

```bash
automation/recovery/up scenario-04 <run-id>
```

### Assert

Run a scenario-specific assert entrypoint once `up` succeeds:

```bash
automation/scenarios/scenario-04/assert <run-id>
```

The assert step is responsible for all pass/fail checks below and must write its outputs under:

- `fixtures/scenario-runs/scenario-04/<run-id>/artifacts/assert/`

### Report

Run:

```bash
automation/scenarios/scenario-04/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-04-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-04 <run-id>
```

If `up` or `assert` fails, teardown is still required before any rerun.

## Assertions

Scenario 04 should fail only on the assertions below.

### A1: Canonical Consumer Groups Are Present And Fully Described

Sources:

- `snapshot-manifest.json.consumer_groups[]`
- `artifacts/assert/groups/<group-id>.describe.txt`
- `artifacts/assert/groups/<group-id>.committed.json`

Pass criteria:

- each canonical group is present in `snapshot-manifest.json.consumer_groups[]`
- `kafka-consumer-groups --describe` succeeds for each canonical group
- each group describes exactly partitions `0..11` for `recovery.consumer.test`
- every described partition reports a numeric committed offset, not a missing or placeholder value

### A2: Recovered Committed Offsets Match The Manifest Exactly

Sources:

- `snapshot-manifest.json.consumer_groups[]`
- `artifacts/assert/groups/<group-id>.expected.json`
- `artifacts/assert/groups/<group-id>.committed.json`

Pass criteria:

- for each canonical group, the normalized recovered committed offset map exactly equals the manifest `expected_committed_offsets` map
- no expected partition is missing
- no unexpected partition appears

### A3: Resumed Consumers Start Exactly At The Inherited Offsets

Sources:

- `snapshot-manifest.json.consumer_groups[]`
- `artifacts/assert/probes/<group-id>.resume.json`

Pass criteria:

- each resumed-consumer probe observes the first consumed message for partitions `0..11`
- for each canonical group, the probe `first_seen_offsets` map exactly equals the manifest `expected_committed_offsets` map
- no partition is reported as missing
- the probe reports no consumer errors and no auto-reset fallback

## Evidence Artifacts

Scenario 04 should retain at least these artifacts:

- `artifacts/assert/groups/<group-id>.describe.txt`
- `artifacts/assert/groups/<group-id>.expected.json`
- `artifacts/assert/groups/<group-id>.committed.json`
- `artifacts/assert/probes/<group-id>.resume.json`
- `artifacts/assert/recovery-ps.txt`
- `artifacts/assert/assert-summary.json`
- `artifacts/recovery/docker-compose.log`

## Automation Contract

- `prepare`: `automation/recovery/prepare scenario-04 <snapshot-label> [run-id]`
- `run`: `automation/recovery/rewrite scenario-04 <run-id>` then `automation/recovery/up scenario-04 <run-id>`
- `assert`: `automation/scenarios/scenario-04/assert <run-id>`
- `report`: `automation/scenarios/scenario-04/report <run-id>`
- `teardown`: `automation/recovery/down scenario-04 <run-id>`

The Scenario 04 assert path should:

- compare recovered committed offsets to the manifest before any resumed-consumer probe runs
- use a repo-managed containerized helper for resumed consumption rather than host-installed Python packages
- write normalized JSON artifacts that the report step can quote without reparsing raw CLI output

## Manual Fallback

Use `kafka-consumer-groups.sh --describe` against the recovery cluster and then run a single consumer with one of the recovered group IDs against `recovery.consumer.test` to confirm the first consumed offset per partition.

## Fault Injection And Rollback

Scenario 04 is a happy-path workload-semantics scenario. No dedicated fault injection is required in this slice.

If the scenario fails after cluster start:

- preserve the assert artifacts and report output
- run `automation/recovery/down scenario-04 <run-id>`
- rebuild the scenario workdir with a fresh `prepare` and `rewrite` before retrying
