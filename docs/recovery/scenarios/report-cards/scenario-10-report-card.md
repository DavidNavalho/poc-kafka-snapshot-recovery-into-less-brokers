# Scenario 10 Report Card

## What This Scenario Is Solving

In plain English, Scenario 10 answers this recovery question:

after the cluster comes back with one surviving replica per partition, can we safely use that recovered cluster as an operational starting point and expand selected partitions back across all three surviving brokers?

This is the first post-recovery operations scenario. Earlier scenarios prove the cluster boots and data is there. Scenario 10 proves the recovered cluster is not only readable, but also manageable as a live Kafka cluster after recovery.

Main technical references:

- [Scenario 10 Technical Spec](../scenario-10-rf1-steady-state-and-expansion.md)
- [Canonical Source Fixture](../../source-fixture-spec.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-10-20260421T162030Z.md)

## Where This Scenario Can Fail

This scenario is meant to pass in the happy path, but it can fail at the checkpoints below.

1. `prepare`, `rewrite`, or `up` can fail before any reassignment begins.
   Scenario 10 still depends on the same clean recovery path already proven by the earlier correctness scenarios.
   Harness help: it keeps the standard staged recovery flow, so the failure still lands in a known phase before any post-recovery mutation starts.
   Technical detail: [Scenario 10 Preconditions](../scenario-10-rf1-steady-state-and-expansion.md#preconditions)

2. `assert` can fail because the recovered cluster never settles into the intended one-replica steady state.
   In human terms, the cluster came back, but it is still unhealthy before we even try to expand anything.
   Harness help: it captures a pre-expansion topic describe and a pre-expansion under-replicated scan so the steady-state health is explicit.
   Technical detail: [Scenario 10 A1](../scenario-10-rf1-steady-state-and-expansion.md#a1-the-recovered-cluster-settles-cleanly-into-the-intended-rf1-steady-state)

3. `assert` can fail because the reassignment payload is wrong or Kafka rejects it.
   This catches the class of mistakes where the harness asks Kafka to do the wrong operational change.
   Harness help: it writes the exact deterministic JSON payload and the execute output into the artifacts instead of hiding the mutation step inside logs.
   Technical detail: [Scenario 10 A2](../scenario-10-rf1-steady-state-and-expansion.md#a2-the-deterministic-reassignment-payload-is-generated-and-accepted-for-execution)

4. `assert` can fail because the expansion starts but never converges cleanly.
   In human terms, Kafka accepted the reassignment, but the cluster never finished rebuilding the full replica set.
   Harness help: it records under-replicated scans during the reassignment window and checks the final replica and ISR sets directly.
   Technical detail: [Scenario 10 A3](../scenario-10-rf1-steady-state-and-expansion.md#a3-the-expansion-converges-and-does-not-leave-persistent-underreplication-behind)

5. `assert` can fail because the expanded partitions are no longer fully readable afterwards.
   This is the user-visible outcome check: reassignment only counts if the recovered data still reads correctly after the cluster changes shape.
   Harness help: it consumes the targeted partitions from the beginning after expansion and compares the counts to the snapshot-backed offsets.
   Technical detail: [Scenario 10 A4](../scenario-10-rf1-steady-state-and-expansion.md#a4-expanded-partitions-remain-fully-readable-after-reassignment)

## How The Harness Helps Recovery

- It turns replica expansion into a deterministic, captured operation instead of a manual Kafka-admin step.
- It separates pre-expansion health from post-expansion convergence, so the operator can tell whether the problem was recovery or reassignment.
- It keeps the evidence in one place: payload, topic describes, under-replicated scans, and post-expansion read checks.
