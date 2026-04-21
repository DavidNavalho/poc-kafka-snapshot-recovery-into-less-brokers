# Scenario 02: Partition Data Integrity

## Objective

Prove that copied partition data remains readable after recovery and that recovered latest offsets match the source manifest for the agreed representative topics.

## Status

- Phase: 1
- State: Implemented
- Scenario 01 is the prerequisite anchor and is already green
- Latest clean run: `20260421T095313Z`
- Latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-02-20260421T095313Z.md`
- Delivered automation: `automation/scenarios/scenario-02/assert`, `automation/scenarios/scenario-02/report`
- Supporting worktree-safe harness changes landed in `automation/lib/common.sh`, `automation/recovery/prepare`, and `automation/recovery/rewrite`

## Depends On

- Scenario 01 green
- canonical snapshot label `baseline-clean-v1`
- source manifest with `expected_latest_offsets`
- recovery cluster compose spec
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without scenario-specific extensions.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v1/manifest.json`
- `fixtures/scenario-runs/scenario-02/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-02/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `fixtures/scenario-runs/scenario-02/<run-id>/run.env`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the first recovered-data gate after Scenario 01 proves that the metadata path boots.

It proves:

- representative recovered user topics are still readable from the beginning
- recovered latest offsets match the manifest exactly for the in-scope topics
- sampled partitions from each representative topic can be fully consumed without corruption indicators
- the recovery broker logs do not show explicit CRC or log-corruption signatures during the clean-stop case

It does **not** prove:

- compacted-topic latest-value semantics
- transactional `read_committed` behavior or transaction-state convergence
- consumer-group offset continuity
- topic or broker config preservation
- every topic in the manifest, every partition in the cluster, or every message payload in the snapshot

Those belong to Scenarios 04, 05, 06, and 07.

## Concrete Inputs

The Scenario 02 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v1`
- surviving brokers: `0,1,2`
- directory mode: `UNASSIGNED`
- representative topics:
  - `recovery.default.6p`
  - `recovery.default.12p`
  - `recovery.default.24p`
  - `recovery.compressed.zstd`
- sampled partitions:
  - `recovery.default.6p`: `0`, `5`
  - `recovery.default.12p`: `0`, `11`
  - `recovery.default.24p`: `0`, `23`
  - `recovery.compressed.zstd`: `0`, `11`

Expected offsets must come only from `snapshot-manifest.json.topics[].expected_latest_offsets`.

Topic selection is intentionally limited to fixed-count topics whose clean-stop `from-beginning` count is expected to equal the manifest latest offset exactly.

Explicitly out of scope for Scenario 02:

- compacted topics, because final logical state is covered by expectation files in Scenario 06
- `recovery.txn.test`, because `read_uncommitted` versus `read_committed` semantics belong to Scenario 07

## Preconditions

Before `run` starts, all of the following must be true:

1. Scenario 01 is green on the current harness branch.
2. `automation/recovery/prepare scenario-02 <snapshot-label> [run-id]` completed successfully.
3. `run.env` exists under `fixtures/scenario-runs/scenario-02/<run-id>/run.env`.
4. `snapshot-manifest.json` exists in the scenario workdir and contains the exact representative topic set listed above.
5. The workdir was created fresh for this run. A previously failed Scenario 02 workdir must not be reused.

Worktree note:

- generated snapshot data is ignored by Git and does not automatically appear in a new Git worktree
- if Scenario 02 is run from a scenario-specific worktree, point `SNAPSHOTS_ROOT` at the shared snapshot directory before running `prepare`

## Recovery Procedure

### Prepare

Run:

```bash
SNAPSHOTS_ROOT=<shared-snapshots-root> \
automation/recovery/prepare scenario-02 baseline-clean-v1 [run-id]
```

If the current worktree already contains `fixtures/snapshots/baseline-clean-v1`, the explicit `SNAPSHOTS_ROOT` override is not required.

Expected outputs:

- `run.env`
- `snapshot-manifest.json`
- `artifacts/prepare/quorum-state.json`
- `artifacts/prepare/selected-checkpoint.json`
- rendered recovery configs for brokers `0`, `1`, and `2`

### Rewrite

Run:

```bash
automation/recovery/rewrite scenario-02 <run-id>
```

### Start

Run:

```bash
automation/recovery/up scenario-02 <run-id>
```

### Assert

Run a scenario-specific assert entrypoint once `up` succeeds:

```bash
automation/scenarios/scenario-02/assert <run-id>
```

The assert step is responsible for all pass/fail checks below and must write its outputs under:

- `fixtures/scenario-runs/scenario-02/<run-id>/artifacts/assert/`

### Report

Run:

```bash
automation/scenarios/scenario-02/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-02-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-02 <run-id>
```

If `up` or `assert` fails, teardown is still required before any rerun.

## Assertions

Scenario 02 should fail only on the assertions below.

### A1: Representative Topics Exist And Are Fully Available

Sources:

- `snapshot-manifest.json`
- `artifacts/assert/topics/<topic>.describe.txt`
- `artifacts/assert/topics/<topic>.unavailable.txt`

Pass criteria:

- every representative topic exists
- every representative topic reports the manifest partition count
- every representative topic has empty unavailable-partitions output

### A2: Latest Offsets Match The Manifest Exactly

Sources:

- `snapshot-manifest.json.topics[].expected_latest_offsets`
- `artifacts/assert/offsets/<topic>.offsets.txt`

Pass criteria:

- every partition in every representative topic appears in the recovered offset output
- every recovered latest offset exactly equals the manifest value
- no extra partitions appear in the recovered offset output

Because `baseline-clean-v1` is a clean-stop snapshot, there is no tolerance window in this scenario.

### A3: Sampled Partitions Are Fully Readable From The Beginning

Sources:

- `artifacts/assert/samples/<topic>.p<partition>.count.txt`
- `snapshot-manifest.json.topics[].expected_latest_offsets`

Pass criteria:

- each sampled partition can be consumed from beginning to end
- the consumed line count exactly equals the manifest latest offset for that partition

### A4: Sampled Partition Prefixes Match The Deterministic Seed Pattern

Sources:

- `artifacts/assert/samples/<topic>.p<partition>.preview.txt`

Pass criteria:

- each sampled preview contains at least the first five records
- those first five records start with deterministic prefixes:
  - `<topic>|p<partition>|m000000|`
  - `<topic>|p<partition>|m000001|`
  - `<topic>|p<partition>|m000002|`
  - `<topic>|p<partition>|m000003|`
  - `<topic>|p<partition>|m000004|`

This assertion applies only to the fixed-count representative topics listed above.

### A5: No Explicit Corruption Or Segment-Recovery Error In Broker Logs

Sources:

- `artifacts/recovery/docker-compose.log`
- `artifacts/assert/corruption-scan.txt`

Scenario 02 must fail on explicit evidence of:

- `CorruptRecordException`
- `InvalidRecordException`
- checksum or CRC validation failure
- explicit log-segment corruption or recovery failure while loading data

Implementation note:

- keep this denylist narrow to data-integrity signals
- do not fail the scenario on unrelated controller or metadata warnings already covered elsewhere

## Automation Contract

- `prepare`: `automation/recovery/prepare scenario-02 <snapshot-label> [run-id]`
- `run`: `automation/recovery/rewrite scenario-02 <run-id>` then `automation/recovery/up scenario-02 <run-id>`
- `assert`: `automation/scenarios/scenario-02/assert <run-id>`
- `report`: `automation/scenarios/scenario-02/report <run-id>`
- `teardown`: `automation/recovery/down scenario-02 <run-id>`

The new `assert` entrypoint must write at least:

- `artifacts/assert/topics/<topic>.describe.txt`
- `artifacts/assert/topics/<topic>.unavailable.txt`
- `artifacts/assert/offsets/<topic>.offsets.txt`
- `artifacts/assert/samples/<topic>.p<partition>.count.txt`
- `artifacts/assert/samples/<topic>.p<partition>.preview.txt`
- `artifacts/assert/corruption-scan.txt`
- `artifacts/assert/assert-summary.json`

The new `report` entrypoint must:

- link to the raw artifacts under `fixtures/scenario-runs/scenario-02/<run-id>/artifacts/`
- summarize which assertions passed or failed
- note the exact representative topics and sampled partitions used for the run

This contract is now implemented and verified by the latest clean run listed above.

## Cleanup And Rerun Rules

- Always run `automation/recovery/down scenario-02 <run-id>` before discarding or preserving a failed run.
- Do not rerun `automation/recovery/up` against a previously failed Scenario 02 workdir without rerunning `prepare` and `rewrite`.
- If the scenario is rerun, create a fresh run ID or remove the prior workdir completely.
- Preserve the failed workdir only when its artifacts are needed for debugging.

## Manual Fallback

Use the generic flow in [`../manual-runbooks/scenario-runs.md`](../manual-runbooks/scenario-runs.md), then run:

1. `kafka-topics --bootstrap-server kafka-0:9092 --describe --topic <topic>`
2. `kafka-topics --bootstrap-server kafka-0:9092 --describe --topic <topic> --unavailable-partitions`
3. `kafka-run-class kafka.tools.GetOffsetShell --bootstrap-server kafka-0:9092 --topic <topic>`
4. `kafka-console-consumer --bootstrap-server kafka-0:9092 --topic <topic> --partition <partition> --from-beginning --timeout-ms 20000 | wc -l`
5. log scans against `artifacts/recovery/docker-compose.log`
