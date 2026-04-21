# Scenario 03 Report Card

## What This Scenario Is Solving

In plain English, Scenario 03 answers this recovery question:

if recovery metadata is wrong for even one partition, do we have a safe window to catch Kafka stray handling before it permanently deletes data?

This is the first explicit safety-net scenario. The happy path is already covered elsewhere. Scenario 03 is about proving that stray handling stays quiet when recovery is correct, and that the harness can deliberately trigger the real dangerous case in a controlled way and still recover from it.

Main technical references:

- [Scenario 03 Technical Spec](../scenario-03-stray-detection-safety-net.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md#scenario-3-stray-detection-safety-net)
- [Canonical Source Fixture](../../source-fixture-spec.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-03-20260421T154928Z.md)

## Where This Scenario Can Fail

This scenario has both a happy path and a deliberate fault-injected path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare`, `rewrite`, or the initial `up` can fail before the stray-specific checks even start.
   Scenario 03 still depends on the same clean recovery path already proven by Scenario 01, Scenario 02, Scenario 05, and Scenario 08.
   Harness help: it keeps the normal staged recovery flow intact, so an early failure is still localized to the ordinary recovery phases.
   Technical detail: [Scenario 03 Preconditions](../scenario-03-stray-detection-safety-net.md#preconditions)

2. the happy-path validation can fail because stray handling already appeared without any injected fault.
   In human terms, the cluster came back, but Kafka already decided something on disk did not belong where it was found.
   Harness help: it reuses the same narrow startup denylist style from Scenario 01 and records a direct stray-directory scan.
   Technical detail: [Scenario 03 A1](../scenario-03-stray-detection-safety-net.md#a1-happypath-recovery-produces-no-stray-directories-or-explicit-stray-startup-failures)

3. the negative-path fault injection can fail because the metadata mutation was not applied to the intended partition.
   This means the scenario did not really test stray behavior, even if the cluster started.
   Harness help: it records the exact override command and the before/after directory listings for the targeted broker and log directory.
   Technical detail: [Scenario 03 A2](../scenario-03-stray-detection-safety-net.md#a2-the-injected-metadata-fault-creates-the-expected-stray-directory)

4. the negative-path boot can fail because the target partition never becomes stray, or because the data is missing from the stray directory.
   This is the critical safety-net check: the scenario must show both the rename and the fact that the data is still recoverable.
   Harness help: it captures the stray directory contents before rollback instead of relying on log messages alone.
   Technical detail: [Scenario 03 A2](../scenario-03-stray-detection-safety-net.md#a2-the-injected-metadata-fault-creates-the-expected-stray-directory) and [Scenario 03 A3](../scenario-03-stray-detection-safety-net.md#a3-data-remains-present-inside-the-stray-directory-during-the-safety-window)

5. the restored restart can fail because the clean metadata was not restored correctly or the renamed directory was not put back in place cleanly.
   In human terms, the safety window existed, but the repair path still did not get the cluster back to a healthy state.
   Harness help: it restarts from a controlled negative-path clone, then records restored quorum, topic availability, and post-restart stray scans separately from the original happy path.
   Technical detail: [Scenario 03 A4](../scenario-03-stray-detection-safety-net.md#a4-restoring-the-clean-metadata-and-renaming-the-directory-back-allows-a-clean-restart)

## How The Harness Helps Recovery

- It isolates the injected fault in a cloned recovery workdir, so the original clean rewritten state stays available as the rollback source.
- It captures filesystem evidence before and after Kafka renames the target partition to `*-stray`, which is much easier to reason about than logs alone.
- It makes the repair path explicit: stop, restore clean metadata, rename the directory back, restart, and verify the cluster is healthy again.
