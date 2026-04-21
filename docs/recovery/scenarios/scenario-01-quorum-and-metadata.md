# Scenario 01: Quorum And Metadata Loading

## Objective

Prove that the copied Region A data, after metadata cleanup and snapshot rewrite, can boot as a valid 3-node KRaft cluster.

## Status

- Phase: 1
- State: Implemented
- Fresh end-to-end validation passed on 2026-04-21 with run ID `20260421T084355Z`
- `prepare`, `rewrite`, `up`, `assert`, and `report` automation are in place
- The current clean run reports `no secondary anomalies detected`

## Depends On

- canonical snapshot label `baseline-clean-v1`
- recovery cluster compose spec
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without any scenario-specific extensions.

The authoritative machine-readable inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v1/manifest.json`
- `fixtures/scenario-runs/scenario-01/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-01/<run-id>/artifacts/prepare/selected-checkpoint.json`
- `fixtures/scenario-runs/scenario-01/<run-id>/artifacts/prepare/quorum-state.json`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario is the boot-and-metadata gate for the whole recovery suite.

It proves:

- the copied Region A working set can be prepared deterministically
- the rewritten metadata can be installed into all three recovery metadata directories
- the 3-node recovery quorum forms and elects a leader
- manifest topics are present and not unavailable at startup
- the startup path does not fail for explicit metadata-identity problems such as cluster-id, `meta.properties`, or voter mismatch

It does **not** prove:

- exact recovered offsets
- end-to-end sample reads
- consumer-group continuity
- config preservation
- compacted-topic semantics
- transaction recovery
- elimination of every controller or broker warning line during startup

Those belong to later scenarios.

## Concrete Inputs

The Scenario 01 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v1`
- surviving brokers: `0,1,2`
- copied source brokers: `0,1,2`
- expected recovery quorum voters: `0@kafka-0:9093,1@kafka-1:9093,2@kafka-2:9093`
- directory mode: `UNASSIGNED`
- in-scope topics: every topic in the snapshot manifest where `replication_factor == 3`

For the current baseline snapshot, the selected metadata checkpoint and quorum mode should come from:

- `snapshot-manifest.json.metadata_snapshot.selected_checkpoint`
- `artifacts/prepare/selected-checkpoint.json`
- `artifacts/prepare/quorum-state.json`

The prepare step must fail if those sources disagree.

## Preconditions

Before `run` starts, all of the following must be true:

1. `automation/recovery/prepare scenario-01 <snapshot-label> [run-id]` completed successfully.
2. `run.env` exists under `fixtures/scenario-runs/scenario-01/<run-id>/run.env`.
3. `snapshot-manifest.json` exists in the scenario workdir and reports:
   - `snapshot_label = baseline-clean-v1`
   - `cluster.cluster_id = ${KAFKA_CLUSTER_ID}`
   - `metadata_snapshot.dynamic_quorum` consistent with `artifacts/prepare/quorum-state.json`
4. `artifacts/prepare/selected-checkpoint.json.basename` matches `snapshot-manifest.json.metadata_snapshot.selected_checkpoint.basename`.
5. The workdir was created fresh for this run. A previously failed recovery workdir must not be reused.

## Recovery Procedure

### Prepare

Run:

```bash
automation/recovery/prepare scenario-01 baseline-clean-v1 [run-id]
```

Expected outputs:

- `run.env`
- `snapshot-manifest.json`
- `artifacts/prepare/quorum-state.json`
- `artifacts/prepare/selected-checkpoint.json`
- rendered recovery configs for brokers `0`, `1`, and `2`

Expected side effects:

- copied metadata directories have metadata `.log`, `.index`, `.timeindex`, `.snapshot`, `.checkpoint.part`, `.checkpoint.deleted`, and `quorum-state` files removed before rewrite

### Rewrite

Run:

```bash
automation/recovery/rewrite scenario-01 <run-id>
```

Expected outputs:

- `artifacts/rewrite/rewrite-command.txt`
- `artifacts/rewrite/rewrite-report.json`
- `artifacts/rewrite/<selected-checkpoint-basename>`
- `artifacts/rewrite/00000000000000000000.log`

Expected install result:

- each recovery broker metadata snapshot dir contains:
  - `partition.metadata`
  - the rewritten checkpoint with the selected basename
  - `00000000000000000000.log`
- stale files such as `leader-epoch-checkpoint`, stale `quorum-state`, and leftover index files are not preserved in the copied metadata snapshot dir before the rewritten files are installed

### Start

Run:

```bash
automation/recovery/up scenario-01 <run-id>
```

### Assert

Run a scenario-specific assert entrypoint once `up` succeeds:

```bash
automation/scenarios/scenario-01/assert <run-id>
```

The assert step is responsible for all pass/fail checks below and must write its outputs under:

- `fixtures/scenario-runs/scenario-01/<run-id>/artifacts/assert/`

### Report

Run a scenario-specific report entrypoint after `assert`:

```bash
automation/scenarios/scenario-01/report <run-id>
```

The report step should author:

- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-01-<run-id>.md`

### Teardown

Run:

```bash
automation/recovery/down scenario-01 <run-id>
```

If `up` or `assert` fails, teardown is still required before any rerun.

## Exact Ready Signal

The primary ready signal for Scenario 01 is the success condition already implemented in `automation/recovery/up`.

That means:

1. `automation/recovery/up` exits `0`.
2. It only exits after `wait_for_recovery_cluster` succeeds.
3. `wait_for_recovery_cluster` succeeds only when this command works from the recovery cluster:

```bash
docker compose --project-name <project> -f compose/recovery-cluster.compose.yml \
  exec -T kafka-0 kafka-topics --bootstrap-server kafka-0:9092 --list
```

Secondary evidence to capture, but not use as the primary gate, is:

- `docker compose ps` for the recovery project
- the final `recovery cluster <project> is ready` log line from `automation/recovery/up`

## Assertions

Scenario 01 should fail only on the assertions below. It should not fail simply because the recovery logs contain unrelated startup noise.

### A1: Rewrite Report Succeeded

Source:

- `artifacts/rewrite/rewrite-report.json`

Pass criteria:

- `status == "success"`
- `surviving_brokers == [0,1,2]`
- `directory_mode == "UNASSIGNED"`
- `partitions.missing_survivors == 0`
- `missing_partitions == []`
- `output_checkpoint.basename == input_checkpoint.basename`
- the `quorum` block is consistent with `artifacts/prepare/quorum-state.json`

### A2: Rewritten Files Were Installed Into Every Recovery Metadata Directory

Source:

- `brokers/broker-{0,1,2}/metadata/__cluster_metadata-0/`

Pass criteria:

- each broker has the rewritten checkpoint basename selected during `prepare`
- each broker has `00000000000000000000.log`
- each broker retains `partition.metadata`
- each broker metadata snapshot dir does not retain stale pre-rewrite files such as old `leader-epoch-checkpoint`, stale `quorum-state`, or leftover index files from the copied snapshot state

### A3: Metadata Quorum Formed As A 3-Node Recovery Quorum

Primary command:

```bash
docker compose --project-name <project> -f compose/recovery-cluster.compose.yml \
  exec -T kafka-0 kafka-metadata-quorum --bootstrap-server kafka-0:9092 describe --status
```

Pass criteria:

- the quorum-status output shows exactly the three recovery voter IDs `0`, `1`, and `2`
- the leader is one of `0`, `1`, or `2`
- the command exits `0`

Implementation note:

- this scenario should parse the quorum-status output narrowly enough to verify the 3-node quorum without depending on unstable timing fields

### A4: All In-Scope Manifest Topics Exist And Have No Unavailable Partitions

In-scope topic definition:

- every `snapshot-manifest.json.topics[]` entry where `replication_factor == 3`

Primary commands:

```bash
docker compose --project-name <project> -f compose/recovery-cluster.compose.yml \
  exec -T kafka-0 kafka-topics --bootstrap-server kafka-0:9092 --describe --topic <topic>
```

```bash
docker compose --project-name <project> -f compose/recovery-cluster.compose.yml \
  exec -T kafka-0 kafka-topics --bootstrap-server kafka-0:9092 --describe --topic <topic> --unavailable-partitions
```

Pass criteria:

- every in-scope manifest topic exists
- partition count for each topic matches the manifest
- the unavailable-partitions output is empty for each in-scope topic

Out of scope for Scenario 01:

- comparing recovered latest offsets to the manifest
- consuming records to verify readability

Those belong to Scenario 02.

### A5: No Explicit Metadata-Identity Or Stray-Detection Startup Failure

Sources:

- `artifacts/recovery/docker-compose.log`
- `artifacts/assert/` grep extracts

Scenario 01 must fail on explicit evidence of:

- cluster-id mismatch
- `meta.properties` mismatch or unreadable metadata identity
- controller quorum voter mismatch
- stray-directory handling in the happy path

Initial failure-pattern denylist for implementation:

- log lines that match `stray` or `-stray`
- log lines that mention `meta.properties` together with `ERROR`, `FATAL`, `Exception`, `mismatch`, or `inconsistent`
- log lines that mention `cluster.id` together with `ERROR`, `FATAL`, `Exception`, `mismatch`, or `inconsistent`
- log lines that mention `controller.quorum.voters` or `voter` together with `ERROR`, `FATAL`, `Exception`, `mismatch`, or `inconsistent`

Implementation note:

- do **not** fail the scenario on every `ERROR` line in the recovery logs
- the denylist is intentionally narrow because current successful boots still emit non-gating controller noise

## Secondary Diagnostics To Capture But Not Yet Gate

The current happy-path recovery run has shown controller and broker noise that should be captured for follow-up analysis, but should not yet be the primary Scenario 01 fail gate:

- `UnknownHostException` lines for non-surviving brokers such as `kafka-4` through `kafka-8`
- `overlapping ISR=[...] and ELR=[...]`
- `StaleBrokerEpochException`
- transient Raft-election chatter during startup

The Scenario 01 report should include a short anomaly summary if any of those appear.

## Automation Contract

- `prepare`: `automation/recovery/prepare scenario-01 <snapshot-label> [run-id]`
- `run`: `automation/recovery/rewrite scenario-01 <run-id>` then `automation/recovery/up scenario-01 <run-id>`
- `assert`: `automation/scenarios/scenario-01/assert <run-id>`
- `report`: `automation/scenarios/scenario-01/report <run-id>`
- `teardown`: `automation/recovery/down scenario-01 <run-id>`

The new `assert` entrypoint must write at least:

- `artifacts/assert/quorum-status.txt`
- `artifacts/assert/topics/<topic>.describe.txt` for each in-scope topic
- `artifacts/assert/topics/<topic>.unavailable.txt` for each in-scope topic
- `artifacts/assert/startup-failure-scan.txt`
- `artifacts/assert/secondary-anomalies.txt`
- `artifacts/assert/assert-summary.json`

The new `report` entrypoint must:

- link to the raw artifacts under `fixtures/scenario-runs/scenario-01/<run-id>/artifacts/`
- summarize which assertions passed or failed
- record any secondary anomalies that were observed but not yet gating

## Cleanup And Rerun Rules

- Always run `automation/recovery/down scenario-01 <run-id>` before discarding or preserving a failed run.
- Do not rerun `automation/recovery/up` against a previously failed workdir without rerunning `prepare` and `rewrite`.
- If the scenario is rerun, create a fresh run ID or remove the prior workdir completely.
- Preserve the failed workdir only when its artifacts are needed for debugging.

## Manual Fallback

Use the generic flow in [`../manual-runbooks/scenario-runs.md`](../manual-runbooks/scenario-runs.md), then run:

1. `kafka-metadata-quorum --bootstrap-server kafka-0:9092 describe --status`
2. `kafka-topics --bootstrap-server kafka-0:9092 --describe --topic <topic>`
3. `kafka-topics --bootstrap-server kafka-0:9092 --describe --topic <topic> --unavailable-partitions`
4. log scans against `artifacts/recovery/docker-compose.log`

## Report Artifacts

- `artifacts/prepare/quorum-state.json`
- `artifacts/prepare/selected-checkpoint.json`
- `artifacts/rewrite/rewrite-command.txt`
- `artifacts/rewrite/rewrite-report.json`
- `artifacts/rewrite/00000000000000000000.log`
- `artifacts/assert/quorum-status.txt`
- `artifacts/assert/topics/<topic>.describe.txt`
- `artifacts/assert/topics/<topic>.unavailable.txt`
- `artifacts/assert/startup-failure-scan.txt`
- `artifacts/assert/secondary-anomalies.txt`
- `artifacts/recovery/docker-compose.log`
- `docs/recovery/reports/runs/<yyyy-mm-dd>-scenario-01-<run-id>.md`
