# Scenario 10: RF=1 Steady State And Replica Expansion

## Objective

Prove two things on the recovered 3-node cluster:

1. the clean-stop recovery path settles into the intended RF=1 steady state without persistent under-replication
2. a deterministic post-recovery reassignment can expand selected partitions back to replicas `[0,1,2]` and converge cleanly

## Status

- Phase: 1
- State: Implemented
- Scenario 01, Scenario 02, Scenario 03, Scenario 05, and Scenario 08 are prerequisites and already green
- Canonical fixture revision for this scenario: `baseline-clean-v3`
- Latest clean run: `20260421T162030Z`
- Latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-10-20260421T162030Z.md`
- Delivered automation: `automation/lib/generate_reassignment_payload.py`, `automation/lib/normalize_topic_describe.py`, `automation/scenarios/scenario-10/assert`, `automation/scenarios/scenario-10/report`
- Supporting tests landed in `automation/tests/scenario_10_assert_test.sh` and `automation/tests/scenario_10_report_test.sh`

## Preconditions

- Scenario 01 green
- Scenario 02 green
- Scenario 05 green
- Scenario 08 green
- Scenario 03 green
- canonical snapshot label `baseline-clean-v3`

This scenario intentionally starts from the same happy-path recovery used elsewhere and only then performs an operational mutation on the recovered cluster.

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without a new source-cluster flavor.

The authoritative machine-readable inputs are:

- `fixtures/snapshots/baseline-clean-v3/manifest.json`
- `fixtures/scenario-runs/scenario-10/<run-id>/snapshot-manifest.json`
- `fixtures/scenario-runs/scenario-10/<run-id>/run.env`
- `fixtures/scenario-runs/scenario-10/<run-id>/artifacts/assert/reassignment/reassignment.json`
- `fixtures/scenario-runs/scenario-10/<run-id>/artifacts/assert/topics/recovery.default.6p.pre.normalized.json`
- `fixtures/scenario-runs/scenario-10/<run-id>/artifacts/assert/topics/recovery.default.6p.post.normalized.json`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Harness Spec](../harness-spec.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

This scenario proves the first operational change after recovery.

It proves:

- the recovered cluster really reaches the intended RF=1 steady state
- selected user partitions can be expanded from one replica to three replicas on brokers `0,1,2`
- final ISR converges to the full target replica set
- partition data remains readable after the expansion

It does **not** prove:

- arbitrary reassignment plans
- rack-aware expansion outside the surviving `0,1,2` broker set
- reassignment throttling behavior
- partition movement under live-copy or crash-consistent snapshot conditions

## Concrete Inputs

The Scenario 10 implementation should use these exact inputs:

- snapshot label: `baseline-clean-v3`
- representative topic for steady-state and expansion checks: `recovery.default.6p`
- target partitions: `0,1,2`
- target replica set after expansion: `[0,1,2]`
- expected post-expansion partition count sample checks:
  - `recovery.default.6p-0 = 10000`
  - `recovery.default.6p-1 = 10000`
  - `recovery.default.6p-2 = 10000`

The harness must generate the reassignment payload deterministically, not by hand-editing JSON per run.

## Recovery Procedure

1. Run the standard clean-stop recovery flow on a fresh Scenario 10 workdir:
   - `automation/recovery/prepare scenario-10 baseline-clean-v3 <run-id>`
   - `automation/recovery/rewrite scenario-10 <run-id>`
   - `automation/recovery/up scenario-10 <run-id>`
2. Capture the pre-expansion describe output for `recovery.default.6p`.
3. Confirm the target partitions currently have:
   - exactly one replica
   - `ISR = replicas`
   - no persistent under-replicated state
4. Generate a deterministic reassignment payload for partitions `0,1,2` with target replicas `[0,1,2]`.
5. Execute the reassignment from broker `0`.
6. Poll the recovered cluster until the target partitions report:
   - `Replicas=[0,1,2]`
   - `ISR=[0,1,2]`
7. Capture:
   - post-expansion describe output
   - under-replicated-partition scans during and after the reassignment window
   - sampled full-read counts for partitions `0,1,2`
8. Write the Scenario 10 report.

## Timing And Nondeterminism Rules

- pre-expansion readiness should reuse the standard recovery-cluster readiness gate from `automation/recovery/up`
- reassignment convergence should allow polling for up to `180` seconds by default
- under-replicated partitions may or may not be observed during the reassignment window on a fast local run
- the scenario must fail if:
  - the steady-state precheck already shows persistent under-replication
  - the final post-expansion state does not converge to the target replica and ISR sets
  - the sampled post-expansion reads do not reach the manifest-backed offsets

The scenario should record whether transient under-replication was observed, but it should not require observing that transient state in order to pass.

## Assertions

### A1. The recovered cluster settles cleanly into the intended RF=1 steady state

Pass when:

- `recovery.default.6p` describes successfully
- target partitions `0,1,2` each report exactly one replica
- each target partition reports `ISR = replicas`
- the pre-expansion under-replicated-partitions scan is empty

Fail when:

- any target partition has replica count other than `1`
- any target partition has `ISR` different from `replicas`
- the cluster still reports under-replicated partitions before reassignment starts

### A2. The deterministic reassignment payload is generated and accepted for execution

Pass when:

- the generated JSON payload exactly targets `recovery.default.6p` partitions `0,1,2`
- every targeted partition uses replicas `[0,1,2]`
- the reassignment execute command returns success

Fail when:

- the payload differs from the expected deterministic shape
- the execute command fails

### A3. The expansion converges and does not leave persistent under-replication behind

Pass when:

- the final post-expansion describe output shows `Replicas=[0,1,2]` for partitions `0,1,2`
- the final post-expansion describe output shows `ISR=[0,1,2]` for partitions `0,1,2`
- the final under-replicated-partitions scan is empty

Fail when:

- the target partitions do not converge to the target replica set
- the final ISR set is incomplete
- under-replication remains after the convergence timeout

### A4. Expanded partitions remain fully readable after reassignment

Pass when:

- partitions `0,1,2` of `recovery.default.6p` can be consumed from the beginning after the expansion
- each consumed count matches the manifest-backed latest offset of `10000`

Fail when:

- a targeted partition cannot be read
- the consumed count is lower than the manifest-backed expected offset

## Automation Contract

Scenario 10 should add:

- `automation/lib/generate_reassignment_payload.py`
- `automation/scenarios/scenario-10/assert`
- `automation/scenarios/scenario-10/report`
- `automation/tests/scenario_10_assert_test.sh`
- `automation/tests/scenario_10_report_test.sh`

The `assert` step must:

- capture and normalize pre-expansion and post-expansion topic-describe output
- capture pre-expansion, during-expansion, and final under-replicated-partition scans
- save the deterministic reassignment payload and execute output
- save sampled post-expansion partition counts for `0,1,2`

## Manual Fallback

Use `kafka-topics --describe` and `kafka-reassign-partitions` directly from broker `0` against `recovery.default.6p`, but the automated path is the primary contract for this scenario.

## Report Artifacts

- pre-expansion topic describe output and normalized JSON
- reassignment payload JSON
- reassignment execute output
- during-expansion under-replicated scan
- post-expansion topic describe output and normalized JSON
- final under-replicated scan
- post-expansion sampled partition counts
