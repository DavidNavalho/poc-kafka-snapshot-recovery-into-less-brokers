# Scenario 01 Report Card

## What This Scenario Is Solving

In plain English, Scenario 01 answers the first recovery question:

can we take the copied snapshot from the original 9-node cluster, rewrite the metadata that no longer fits, and bring it back as a healthy 3-node cluster without confusing Kafka about who the controllers and brokers are?

This is the "does the recovered cluster actually boot correctly?" scenario. If this one is not green, the rest of the recovery suite is not trustworthy yet.

Main technical references:

- [Scenario 01 Technical Spec](../scenario-01-quorum-and-metadata.md)
- [Latest Clean Scenario 01 Run Report](../../reports/runs/2026-04-21-scenario-01-20260421T084355Z.md)
- [Snapshot Rewrite Tool Spec](../../rewrite-tool-spec.md)

## Where This Scenario Can Fail

This scenario is not meant to fail in the happy path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare` can fail if the copied snapshot inputs do not line up.
   This usually means the selected checkpoint, quorum state, or snapshot metadata is inconsistent.
   Harness help: it records the chosen checkpoint and quorum inputs before any rewrite starts, so the mismatch is visible early.
   Technical detail: [Scenario 01 Preconditions](../scenario-01-quorum-and-metadata.md#preconditions)

2. `rewrite` can fail if the old 9-node metadata cannot be safely converted into the 3-node recovery shape.
   This is where stale controller state, stale side files, or wrong voter information should be caught.
   Harness help: it writes a rewrite command and a rewrite report, and it resets copied metadata directories before installing the rewritten files.
   Technical detail: [Scenario 01 Rewrite](../scenario-01-quorum-and-metadata.md#rewrite), [Rewrite Tool Spec](../../rewrite-tool-spec.md)

3. `up` can fail if the three recovery nodes cannot form a valid quorum.
   In human terms, this means the cluster starts but never really agrees on who is in charge, or it still thinks it belongs to the old topology.
   Harness help: it waits for a concrete ready signal instead of treating container startup as success, and it captures broker logs for inspection.
   Technical detail: [Scenario 01 Exact Ready Signal](../scenario-01-quorum-and-metadata.md#exact-ready-signal)

4. `assert` can fail if the cluster looks alive but the metadata is still wrong.
   Examples are missing manifest topics, unavailable partitions, or explicit identity and voter mismatch errors.
   Harness help: it turns those checks into named assertions and writes evidence into the scenario artifacts instead of leaving the result in raw logs only.
   Technical detail: [Scenario 01 Assertions](../scenario-01-quorum-and-metadata.md#assertions)

## How The Harness Helps Recovery

- It breaks the work into `prepare`, `rewrite`, `up`, `assert`, and `report`, so the failure is tied to a stage instead of appearing as one large opaque recovery attempt.
- It preserves the rewritten metadata artifacts and the broker logs from the failed run, which makes reruns and diagnosis much easier.
- It makes the rerun rule explicit: do not trust a reused failed workdir; rebuild it with a fresh `prepare` and `rewrite`.
  Technical detail: [Recovery Handoff](../../HANDOFF.md)
