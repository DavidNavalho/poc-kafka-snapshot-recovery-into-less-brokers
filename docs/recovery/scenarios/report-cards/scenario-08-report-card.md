# Scenario 08 Report Card

## What This Scenario Is Solving

In plain English, Scenario 08 answers this recovery question:

after we recover the cluster, are we still truly using both Kafka data disks on each surviving broker, or did recovery only work by accident on one side?

This is the storage-layout confidence scenario. A cluster can boot and serve some reads while still being wrong if one recovered `log.dir` is effectively ignored, mismatched, or pushed into stray handling.

Main technical references:

- [Scenario 08 Technical Spec](../scenario-08-multiple-log-directories.md)
- [Canonical Source Fixture](../../source-fixture-spec.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-08-20260421T131900Z.md)

## Where This Scenario Can Fail

This scenario is not meant to fail in the happy path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare`, `rewrite`, or `up` can fail before any disk-layout comparison starts.
   Scenario 08 still depends on the same metadata and cluster-start path already proven in Scenario 01, Scenario 02, and Scenario 05.
   Harness help: it keeps the same staged recovery flow, so an early failure is still tied to a specific phase.
   Technical detail: [Scenario 08 Preconditions](../scenario-08-multiple-log-directories.md#preconditions)

2. `assert` can fail because the recovered partition directories under one of the log roots no longer match the source snapshot.
   In human terms, the cluster came back, but the broker’s on-disk layout drifted from the snapshot we expected to recover.
   Harness help: it records side-by-side source and recovered partition-directory listings for both log roots on every surviving broker.
   Technical detail: [Scenario 08 A1](../scenario-08-multiple-log-directories.md#a1-recovered-user-partition-directories-match-the-source-snapshot-across-both-log-dirs)

3. `assert` can fail because `meta.properties` identity is inconsistent across the two recovered log roots.
   This catches the class of mistakes where a broker’s two disks no longer agree on who they belong to.
   Harness help: it captures raw `meta.properties` files from both source and recovered storage and compares them after normalization.
   Technical detail: [Scenario 08 A2](../scenario-08-multiple-log-directories.md#a2-metaproperties-identity-remains-consistent-across-both-recovered-log-dirs)

4. `assert` can fail because recovery created stray directories or emitted explicit multi-disk identity failures in the logs.
   In human terms, Kafka decided something on disk did not belong where it was found.
   Harness help: it scans both the filesystem and the recovery logs with a narrow denylist instead of forcing manual log archaeology.
   Technical detail: [Scenario 08 A3](../scenario-08-multiple-log-directories.md#a3-happypath-recovery-produces-no-stray-directories-or-multidisk-identity-failures)

5. `assert` can fail because the representative partitions that span both disks are no longer fully readable.
   This is the user-visible outcome check: even if the directories still exist, the recovered data path must work.
   Harness help: it consumes a fixed representative topic whose partitions are deliberately spread across both log roots on the surviving brokers.
   Technical detail: [Scenario 08 A4](../scenario-08-multiple-log-directories.md#a4-representative-multidisk-partitions-remain-readable-from-the-beginning)

## How The Harness Helps Recovery

- It compares recovered disk layout against the immutable source snapshot instead of relying on assumptions about what Kafka "probably" did.
- It captures both filesystem evidence and broker-log evidence, so disk-layout problems are easier to localize.
- It uses a representative topic whose partitions span both disks, which turns multi-disk recovery into a direct read check rather than a purely structural inspection.
