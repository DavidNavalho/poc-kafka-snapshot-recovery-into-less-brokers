# Scenario 07: Transaction State Recovery

## Objective

Prove that transaction coordinator state survives recovery, the source-side in-flight transaction converges to an aborted terminal state, and a brand-new transactional producer can initialize and commit successfully after reconnect.

## Status

- Phase: 1
- State: Implemented
- Scenario 01, Scenario 02, Scenario 05, Scenario 06, and Scenario 08 are prerequisites and already green
- Latest clean run: `20260421T143125Z`
- Delivered automation:
  - `automation/lib/probe_transaction_state.py`
  - `automation/scenarios/scenario-07/assert`
  - `automation/scenarios/scenario-07/report`
  - `automation/tests/scenario_07_assert_test.sh`
  - `automation/tests/scenario_07_report_test.sh`

## Depends On

- Scenario 01 green
- Scenario 02 green
- Scenario 05 green
- Scenario 06 green
- Scenario 08 green
- canonical snapshot label `baseline-clean-v3`
- canonical source fixture must include both committed and intentionally open transaction cases
- repo-managed Python toolbox with `confluent-kafka`
- `kafka-transactions` CLI inside the broker container image
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without scenario-specific extensions.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v3/manifest.json`
- `fixtures/scenario-runs/scenario-07/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-07/<run-id>/run.env`
- `fixtures/scenario-runs/scenario-07/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `fixtures/scenario-runs/scenario-07/<run-id>/artifacts/prepare/quorum-state.json`
- `snapshot-manifest.json.transactions`
- the `snapshot-manifest.json.topics[]` entry for `recovery.txn.test`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the transaction-semantics gate after the recovered cluster already proved it can boot, preserve representative data, retain config state, survive multi-log-dir recovery, and preserve compacted-topic logical state.

It proves:

- `__transaction_state` is online and transaction metadata can still be inspected after recovery
- the canonical committed transactional history remains visible to `read_committed` consumers
- the canonical source-side open transaction converges to the expected terminal recovery state
- a brand-new transactional producer can call `initTransactions()`, commit one transaction, and make those records visible to `read_committed`

It does **not** prove:

- transactional throughput or latency
- long-running transactional workloads after recovery
- transaction-state topic config preservation beyond topic availability and online leadership
- client-library compatibility outside the repo-managed probe helper

Those belong to later scenarios.

## Concrete Inputs

The Scenario 07 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v3`
- surviving brokers: `0,1,2`
- directory mode: `UNASSIGNED`
- in-scope transaction topic: `recovery.txn.test`
- expected partition count: `6`
- canonical committed transactional ID: `recovery.txn.committed`
- canonical source-open transactional ID: `recovery.txn.ongoing`
- expected initial `read_committed` total messages: `600`
- expected initial `read_committed` per-partition counts: `100` on partitions `0..5`
- expected committed transaction terminal state: `CompleteCommit`
- expected recovered open transaction terminal state: `CompleteAbort`
- post-recovery probe transactional ID pattern: `recovery.txn.probe.scenario-07.<run-id>`
- post-recovery probe writes exactly `1` committed message per partition
- expected post-probe `read_committed` total messages: `606`
- expected post-probe `read_committed` per-partition counts: `101` on partitions `0..5`

Timing and retry rules:

- transaction-state inspection may need a short stabilization window after `up`; allow up to `45` seconds for `kafka-transactions describe --transactional-id recovery.txn.ongoing` to report `CompleteAbort`
- the post-recovery transactional probe may briefly encounter coordinator load-in-progress behavior while `initTransactions()` resolves; the helper should retry internally until success or timeout
- each `read_committed` probe should allow up to `45` seconds to reach partition EOF across all six partitions

## Preconditions

Before `run` starts, all of the following must be true:

1. Scenario 01 is green on the current harness branch.
2. Scenario 02 is green on the current harness branch.
3. Scenario 05 is green on the current harness branch.
4. Scenario 06 is green on the current harness branch.
5. Scenario 08 is green on the current harness branch.
6. `automation/recovery/prepare scenario-07 <snapshot-label> [run-id]` completed successfully.
7. `run.env` exists under `fixtures/scenario-runs/scenario-07/<run-id>/run.env`.
8. `snapshot-manifest.json` exists in the scenario workdir and contains:
   - the `transactions` object from the canonical fixture
   - the `recovery.txn.test` topic entry with `expected_read_committed_offsets`
9. the immutable snapshot root referenced by `SNAPSHOT_SOURCE_ROOT` contains `baseline-clean-v3`
10. the workdir was created fresh for this run. A previously failed Scenario 07 workdir must not be reused.

Worktree note:

- generated snapshot data is ignored by Git and does not automatically appear in a new Git worktree
- if Scenario 07 is run from a scenario-specific worktree, point `SNAPSHOTS_ROOT` at the shared snapshot directory before running `prepare`

## Recovery Procedure

### Prepare

Run:

```bash
SNAPSHOTS_ROOT=<shared-snapshots-root> \
automation/recovery/prepare scenario-07 baseline-clean-v3 [run-id]
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
automation/recovery/rewrite scenario-07 <run-id>
```

### Start

Run:

```bash
automation/recovery/up scenario-07 <run-id>
```

### Assert

Run a scenario-specific assert entrypoint once `up` succeeds:

```bash
automation/scenarios/scenario-07/assert <run-id>
```

The assert step is responsible for all pass/fail checks below and must write its outputs under:

- `fixtures/scenario-runs/scenario-07/<run-id>/artifacts/assert/`

### Report

Run:

```bash
automation/scenarios/scenario-07/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-07-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-07 <run-id>
```

If `up` or `assert` fails, teardown is still required before any rerun.

## Assertions

Scenario 07 should fail only on the assertions below.

### A1: `__transaction_state` Is Online And Canonical Transactional IDs Remain Inspectable

Sources:

- `artifacts/assert/transaction-state/__transaction_state.describe.txt`
- `artifacts/assert/transaction-state/transactions.list.initial.txt`
- `artifacts/assert/transaction-state/recovery.txn.committed.describe.txt`
- `artifacts/assert/transaction-state/recovery.txn.ongoing.describe.txt`

Pass criteria:

- `__transaction_state` topic describe succeeds
- every partition line in the describe output has a leader in `0,1,2`
- the initial transaction list includes both `recovery.txn.committed` and `recovery.txn.ongoing`
- `recovery.txn.committed` is inspectable and reports `TransactionState = CompleteCommit`

### A2: Initial `read_committed` Visibility Matches The Manifest And Hides Open-Transaction Records

Sources:

- `snapshot-manifest.json.transactions`
- the `snapshot-manifest.json.topics[]` entry for `recovery.txn.test`
- `artifacts/assert/probes/recovery.txn.test.read-committed.before.json`

Pass criteria:

- the probe reaches EOF on all six partitions
- the probe reports zero errors
- total visible messages equal `snapshot-manifest.json.transactions.expected_read_committed_total_messages`
- per-partition visible counts equal `snapshot-manifest.json.topics["recovery.txn.test"].expected_read_committed_offsets`
- visible marker counts include zero `open` records

### A3: The Canonical Source-Open Transaction Converges To `CompleteAbort`

Sources:

- `artifacts/assert/transaction-state/recovery.txn.ongoing.describe.txt`

Pass criteria:

- within the bounded stabilization window, the recovered `recovery.txn.ongoing` transactional ID reports `TransactionState = CompleteAbort`

### A4: A New Transactional Producer Can Initialize, Commit, And Become Visible To `read_committed`

Sources:

- `artifacts/assert/probes/transactional-probe.json`
- `artifacts/assert/transaction-state/<probe-transactional-id>.describe.txt`
- `artifacts/assert/probes/recovery.txn.test.read-committed.after.json`

Pass criteria:

- the repo-managed transactional probe helper completes successfully
- the helper records successful `initTransactions()` and `commitTransaction()` phases
- the post-probe transactional ID is inspectable and reports `TransactionState = CompleteCommit`
- the post-probe `read_committed` total is exactly `606`
- the post-probe `read_committed` per-partition counts are exactly `101`
- the post-probe visible marker counts include exactly `6` `probe` records and still include zero `open` records

## Automation Contract

The Scenario 07 automation should add:

- a repo-managed Python helper to consume a topic with `isolation.level=read_committed` and emit a structured JSON summary
- a repo-managed Python helper to run a brand-new transactional producer probe and emit a structured JSON summary
- a scenario-specific `assert` entrypoint that captures `kafka-transactions` CLI output as artifacts and compares structured probe output against the manifest
- a scenario-specific `report` entrypoint that summarizes transaction health, committed visibility, and probe success

The automation should reuse:

- the standard `prepare` / `rewrite` / `up` / `down` lifecycle
- the repo-managed toolbox container instead of host-installed Python packages

## Required Report Artifacts

Scenario 07 should retain at least these artifacts:

- `artifacts/assert/transaction-state/__transaction_state.describe.txt`
- `artifacts/assert/transaction-state/transactions.list.initial.txt`
- `artifacts/assert/transaction-state/recovery.txn.committed.describe.txt`
- `artifacts/assert/transaction-state/recovery.txn.ongoing.describe.txt`
- `artifacts/assert/transaction-state/<probe-transactional-id>.describe.txt`
- `artifacts/assert/probes/recovery.txn.test.read-committed.before.json`
- `artifacts/assert/probes/recovery.txn.test.read-committed.after.json`
- `artifacts/assert/probes/transactional-probe.json`
- `artifacts/assert/recovery-ps.txt`
- `artifacts/assert/assert-summary.json`

## Manual Fallback

If the scripted assert path is unavailable, inspect the recovered cluster with:

1. `kafka-topics --bootstrap-server kafka-0:9092 --describe --topic __transaction_state`
2. `kafka-transactions --bootstrap-server kafka-0:9092 list`
3. `kafka-transactions --bootstrap-server kafka-0:9092 describe --transactional-id recovery.txn.committed`
4. `kafka-transactions --bootstrap-server kafka-0:9092 describe --transactional-id recovery.txn.ongoing`
5. a repo-managed `read_committed` probe against `recovery.txn.test`
6. a repo-managed transactional producer helper using a fresh transactional ID

## Fault Injection And Rollback

Scenario 07 is a happy-path workload-semantics scenario. No dedicated fault injection is required in this slice.
