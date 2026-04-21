# Scenario 02 Report Card

## What This Scenario Is Solving

In plain English, Scenario 02 answers the next recovery question after boot:

even if the recovered 3-node cluster starts, did the actual topic data survive in a way that users can still read it, and do the recovered offsets still match what the source snapshot said should exist?

This is the "is the recovered data really there?" scenario. Scenario 01 proves the cluster can start; Scenario 02 proves that the data path still behaves like the snapshot says it should.

Main technical references:

- [Scenario 02 Technical Spec](../scenario-02-partition-data-integrity.md)
- [Latest Clean Scenario 02 Run Report](../../reports/runs/2026-04-21-scenario-02-20260421T095313Z.md)
- [Scenario 01 Report Card](./scenario-01-report-card.md)

## Where This Scenario Can Fail

This scenario is not meant to fail in the happy path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare`, `rewrite`, or `up` can fail before any data check runs.
   Scenario 02 still depends on the boot and metadata path from Scenario 01 being healthy.
   Harness help: it reuses the same staged recovery flow and artifacts, so a failure still points at a specific phase rather than a vague "restore failed" outcome.
   Technical detail: [Scenario 02 Preconditions](../scenario-02-partition-data-integrity.md#preconditions), [Scenario 01 Technical Spec](../scenario-01-quorum-and-metadata.md)

2. `assert` can fail because the expected topics are present but not fully available.
   In human terms, the cluster is up, but some of the data is still not really ready to use.
   Harness help: it saves topic describe output and unavailable-partition output for each representative topic.
   Technical detail: [Scenario 02 A1](../scenario-02-partition-data-integrity.md#a1-representative-topics-exist-and-are-fully-available)

3. `assert` can fail because the recovered offsets do not match the snapshot manifest.
   This means the recovered cluster does not line up with the clean-stop snapshot we expected to restore.
   Harness help: it captures per-topic offset output and compares it directly to the manifest, so the mismatch is explicit.
   Technical detail: [Scenario 02 A2](../scenario-02-partition-data-integrity.md#a2-latest-offsets-match-the-manifest-exactly)

4. `assert` can fail because sampled partitions cannot be fully read back from the beginning.
   This is the practical "can a reader actually consume the data?" check.
   Harness help: it records both read counts and preview samples for selected partitions, which makes a short read or wrong payload pattern easy to see.
   Technical detail: [Scenario 02 A3](../scenario-02-partition-data-integrity.md#a3-sampled-partitions-are-fully-readable-from-the-beginning), [Scenario 02 A4](../scenario-02-partition-data-integrity.md#a4-sampled-partition-prefixes-match-the-deterministic-seed-pattern)

5. `assert` can fail because the broker logs show corruption or segment-recovery errors.
   In human terms, the cluster may look up, but Kafka is warning that the underlying log data is damaged or had to be recovered unexpectedly.
   Harness help: it scans the recovery logs for a narrow set of corruption signatures and writes the scan result as a scenario artifact.
   Technical detail: [Scenario 02 A5](../scenario-02-partition-data-integrity.md#a5-no-explicit-corruption-or-segment-recovery-error-in-broker-logs)

## How The Harness Helps Recovery

- It turns "data looks wrong" into separate checks for topic availability, offsets, sample reads, payload previews, and corruption signals.
- It keeps the raw evidence under the scenario run directory, so a failing run can be reviewed without rerunning the cluster immediately.
- It supports worktree-based runs by allowing `SNAPSHOTS_ROOT` to point at shared snapshot data while still keeping the scenario workdir isolated.
  Technical detail: [Scenario 02 Worktree Note](../scenario-02-partition-data-integrity.md#preconditions), [Recovery Handoff](../../HANDOFF.md)
