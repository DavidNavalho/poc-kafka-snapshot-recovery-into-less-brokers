# Scenario 05: Topic And Broker Config Preservation

## Objective

Prove that dynamic topic configs and broker-level dynamic overrides survive the snapshot rewrite unchanged.

## Status

- Phase: 1
- State: Implemented
- Scenario 01 and Scenario 02 are prerequisites and already green
- Latest clean run: `20260421T113800Z`
- Latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-05-20260421T113800Z.md`
- Delivered automation: `automation/scenarios/scenario-05/assert`, `automation/scenarios/scenario-05/report`
- Supporting fixes landed in `automation/lib/common.sh`, `automation/recovery/prepare`, `automation/recovery/rewrite`, `automation/source-cluster/seed`, `automation/source-cluster/validate`, `automation/source-cluster/snapshot`, `compose/source-cluster.compose.yml`, and `tooling/snapshot-rewrite/`

## Depends On

- Scenario 01 green
- Scenario 02 green
- canonical snapshot label `baseline-clean-v2`
- source manifest must record config expectations
- recovery cluster compose spec
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without scenario-specific extensions.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v2/manifest.json`
- `fixtures/scenario-runs/scenario-05/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-05/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `fixtures/scenario-runs/scenario-05/<run-id>/run.env`
- `snapshot-manifest.json.topics[].configs`
- `snapshot-manifest.json.broker_dynamic_configs[]`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the configuration-preservation gate after Scenario 01 proves the cluster boots and Scenario 02 proves representative partition data is readable.

It proves:

- manifest-backed topic-level dynamic overrides survive recovery unchanged
- the pinned broker-level dynamic override for broker `0` survives recovery unchanged
- in-scope topics and surviving brokers that should have no dynamic overrides do not gain any by accident
- the recovered cluster still exposes the expected dynamic config state through Kafka admin commands

It does **not** prove:

- recovered offsets or payload readability
- compacted-topic latest-value semantics
- consumer-group continuity
- transaction-state correctness
- post-recovery config mutation workflows

Those belong to other scenarios.

## Concrete Inputs

The Scenario 05 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v2`
- surviving brokers: `0,1,2`
- directory mode: `UNASSIGNED`
- in-scope configured topics:
  - `recovery.retention.short`
  - `recovery.retention.long`
  - `recovery.compacted.accounts`
  - `recovery.compacted.orders`
  - `recovery.compressed.zstd`
- in-scope zero-override topics:
  - `recovery.default.6p`
  - `recovery.default.12p`
  - `recovery.default.24p`
  - `recovery.txn.test`
  - `recovery.consumer.test`
- in-scope brokers:
  - broker `0` must retain `log.cleaner.threads=2`
  - brokers `1` and `2` must report no dynamic broker overrides

Expected topic configs must come only from `snapshot-manifest.json.topics[].configs`.

Expected broker configs must come only from `snapshot-manifest.json.broker_dynamic_configs[]`.

Normalization rule:

- compare only dynamic config entries, not static or default broker settings
- config dumps should normalize into sorted key-value objects so CLI formatting and synonym ordering do not create false diffs
- raw CLI output must still be preserved as artifacts

## Preconditions

Before `run` starts, all of the following must be true:

1. Scenario 01 is green on the current harness branch.
2. Scenario 02 is green on the current harness branch.
3. `automation/recovery/prepare scenario-05 <snapshot-label> [run-id]` completed successfully.
4. `run.env` exists under `fixtures/scenario-runs/scenario-05/<run-id>/run.env`.
5. `snapshot-manifest.json` exists in the scenario workdir and contains:
   - the exact configured topics listed above with non-empty `configs`
   - the exact zero-override topics listed above with empty `configs`
   - `broker_dynamic_configs` containing only broker `0` with `log.cleaner.threads=2`
6. The workdir was created fresh for this run. A previously failed Scenario 05 workdir must not be reused.

Worktree note:

- generated snapshot data is ignored by Git and does not automatically appear in a new Git worktree
- if Scenario 05 is run from a scenario-specific worktree, point `SNAPSHOTS_ROOT` at the shared snapshot directory before running `prepare`

## Recovery Procedure

### Prepare

Run:

```bash
SNAPSHOTS_ROOT=<shared-snapshots-root> \
automation/recovery/prepare scenario-05 baseline-clean-v2 [run-id]
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
automation/recovery/rewrite scenario-05 <run-id>
```

### Start

Run:

```bash
automation/recovery/up scenario-05 <run-id>
```

### Assert

Run a scenario-specific assert entrypoint once `up` succeeds:

```bash
automation/scenarios/scenario-05/assert <run-id>
```

The assert step is responsible for all pass/fail checks below and must write its outputs under:

- `fixtures/scenario-runs/scenario-05/<run-id>/artifacts/assert/`

### Report

Run:

```bash
automation/scenarios/scenario-05/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-05-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-05 <run-id>
```

If `up` or `assert` fails, teardown is still required before any rerun.

## Assertions

Scenario 05 should fail only on the assertions below.

### A1: Configured Topics Retain Exact Dynamic Overrides

Sources:

- `snapshot-manifest.json.topics[].configs`
- `artifacts/assert/topics/<topic>.config.txt`
- `artifacts/assert/topics/<topic>.normalized.json`

Pass criteria:

- every configured topic listed above is present in the manifest
- the normalized recovered dynamic config object exactly equals the manifest `configs` object
- no expected key is missing
- no extra dynamic key appears on the topic

### A2: Zero-Override Topics Remain Free Of Dynamic Overrides

Sources:

- `snapshot-manifest.json.topics[].configs`
- `artifacts/assert/topics/<topic>.config.txt`
- `artifacts/assert/topics/<topic>.normalized.json`

Pass criteria:

- every zero-override topic listed above is present in the manifest
- the normalized recovered dynamic config object is empty for each zero-override topic

### A3: Broker 0 Retains The Exact Dynamic Broker Override

Sources:

- `snapshot-manifest.json.broker_dynamic_configs[]`
- `artifacts/assert/brokers/broker-0.config.txt`
- `artifacts/assert/brokers/broker-0.normalized.json`

Pass criteria:

- broker `0` is present in the manifest broker config list
- the normalized recovered dynamic broker config object exactly equals:
  - `{"log.cleaner.threads":"2"}`
- no extra dynamic broker key appears for broker `0`

### A4: Brokers 1 And 2 Do Not Gain Dynamic Broker Overrides

Sources:

- `snapshot-manifest.json.broker_dynamic_configs[]`
- `artifacts/assert/brokers/broker-1.config.txt`
- `artifacts/assert/brokers/broker-2.config.txt`
- `artifacts/assert/brokers/broker-1.normalized.json`
- `artifacts/assert/brokers/broker-2.normalized.json`

Pass criteria:

- brokers `1` and `2` are absent from `snapshot-manifest.json.broker_dynamic_configs[]`
- the normalized recovered dynamic broker config object is empty for broker `1`
- the normalized recovered dynamic broker config object is empty for broker `2`

## Automation Contract

- `prepare`: `automation/recovery/prepare scenario-05 <snapshot-label> [run-id]`
- `run`: `automation/recovery/rewrite scenario-05 <run-id>` then `automation/recovery/up scenario-05 <run-id>`
- `assert`: `automation/scenarios/scenario-05/assert <run-id>`
- `report`: `automation/scenarios/scenario-05/report <run-id>`
- `teardown`: `automation/recovery/down scenario-05 <run-id>`

The new `assert` entrypoint must write at least:

- `artifacts/assert/topics/<topic>.config.txt`
- `artifacts/assert/topics/<topic>.normalized.json`
- `artifacts/assert/brokers/broker-<id>.config.txt`
- `artifacts/assert/brokers/broker-<id>.normalized.json`
- `artifacts/assert/assert-summary.json`

The new `report` entrypoint must:

- link to the raw and normalized config artifacts under `fixtures/scenario-runs/scenario-05/<run-id>/artifacts/`
- summarize which assertions passed or failed
- note the exact configured topics, zero-override topics, and in-scope brokers used for the run

## Cleanup And Rerun Rules

- Always run `automation/recovery/down scenario-05 <run-id>` before discarding or preserving a failed run.
- Do not rerun `automation/recovery/up` against a previously failed Scenario 05 workdir without rerunning `prepare` and `rewrite`.
- If the scenario is rerun, create a fresh run ID or remove the prior workdir completely.
- Preserve the failed workdir only when its artifacts are needed for debugging.

## Manual Fallback

Use the generic flow in [`../manual-runbooks/scenario-runs.md`](../manual-runbooks/scenario-runs.md), then run:

1. `kafka-configs --bootstrap-server kafka-0:9092 --entity-type topics --entity-name <topic> --describe`
2. `kafka-configs --bootstrap-server kafka-0:9092 --entity-type brokers --entity-name <broker-id> --describe`
3. normalize the dynamic entries and compare them to `snapshot-manifest.json`
