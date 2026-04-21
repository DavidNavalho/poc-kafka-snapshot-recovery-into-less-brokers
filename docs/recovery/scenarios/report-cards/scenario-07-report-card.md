# Scenario 07 Report Card

## What This Scenario Is Solving

In plain English, Scenario 07 answers this recovery question:

after we recover the cluster, are transactions still in a sane state, or did recovery leave them half-broken in ways normal reads might not show?

This is the transaction-confidence scenario. A recovered cluster can boot, serve ordinary reads, and still be operationally wrong if transactional metadata is corrupted, in-flight transactions never resolve, or new transactional producers cannot initialize cleanly.

Main technical references:

- [Scenario 07 Technical Spec](../scenario-07-transaction-state-recovery.md)
- [Canonical Source Fixture](../../source-fixture-spec.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-07-20260421T143125Z.md)

## Where This Scenario Can Fail

This scenario is not meant to fail in the happy path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare`, `rewrite`, or `up` can fail before any transaction check starts.
   Scenario 07 still depends on the same metadata and startup path already proven in the earlier happy-path scenarios.
   Harness help: it uses the same staged recovery flow, so failures still stay tied to a specific phase.
   Technical detail: [Scenario 07 Preconditions](../scenario-07-transaction-state-recovery.md#preconditions)

2. `assert` can fail because `__transaction_state` is not healthy or the canonical transactional IDs cannot be inspected.
   In human terms, the internal transaction coordinator data is present but not usable.
   Harness help: it stores raw topic-describe output and raw `kafka-transactions` output before any interpretation happens.
   Technical detail: [Scenario 07 A1](../scenario-07-transaction-state-recovery.md#a1-__transaction_state-is-online-and-canonical-transactional-ids-remain-inspectable)

3. `assert` can fail because the recovered `read_committed` view is wrong.
   This catches the case where ordinary committed transactional history is missing or the old open transaction leaked visible records.
   Harness help: it uses a containerized `read_committed` probe and compares the result directly to manifest-backed expectations.
   Technical detail: [Scenario 07 A2](../scenario-07-transaction-state-recovery.md#a2-initial-read_committed-visibility-matches-the-manifest-and-hides-open-transaction-records)

4. `assert` can fail because the source-open transaction never converges to the expected aborted terminal state.
   In human terms, recovery left the cluster with hanging transaction state instead of resolving it cleanly.
   Harness help: it polls the specific canonical transactional ID and records the exact terminal state that Kafka reports.
   Technical detail: [Scenario 07 A3](../scenario-07-transaction-state-recovery.md#a3-the-canonical-source-open-transaction-converges-to-completeabort)

5. `assert` can fail because a brand-new transactional producer cannot initialize or commit after recovery.
   This is the operational smoke test: even if old state looks reasonable, the recovered cluster still has to accept new transactional work.
   Harness help: it runs a repo-managed transactional probe with a fresh transactional ID and captures both the probe output and the broker-reported transaction state.
   Technical detail: [Scenario 07 A4](../scenario-07-transaction-state-recovery.md#a4-a-new-transactional-producer-can-initialize-commit-and-become-visible-to-read_committed)

## How The Harness Helps Recovery

- It separates transaction-state inspection from committed-read visibility and from new-producer behavior, which makes failures easier to localize.
- It keeps both raw Kafka CLI artifacts and structured JSON probe output, so transactional issues can be diagnosed without immediately re-running the cluster.
- It uses repo-managed containerized probes instead of host-installed client libraries, which keeps the verification path portable and isolated.
