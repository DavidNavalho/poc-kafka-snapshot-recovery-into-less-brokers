# Scenario 04 Report Card

## What This Scenario Is Solving

In plain English, Scenario 04 answers this recovery question:

after we recover the cluster, do existing consumer groups pick up where they left off, or do they restart from the wrong place?

This is the client-resume confidence scenario. A recovered cluster can boot, preserve topic data, and still be operationally wrong if consumer groups lose their place and re-read old data or skip ahead unexpectedly.

Main technical references:

- [Scenario 04 Technical Spec](../scenario-04-consumer-offset-continuity.md)
- [Canonical Source Fixture](../../source-fixture-spec.md)
- [Latest Clean Run Report](../../reports/runs/2026-04-21-scenario-04-20260421T134100Z.md)

## Where This Scenario Can Fail

This scenario is not meant to fail in the happy path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare`, `rewrite`, or `up` can fail before any consumer-group check starts.
   Scenario 04 still depends on the same metadata and cluster-start path already proven in Scenario 01, Scenario 02, Scenario 05, and Scenario 08.
   Harness help: it keeps the same staged recovery flow, so an early failure is still tied to a specific phase.
   Technical detail: [Scenario 04 Preconditions](../scenario-04-consumer-offset-continuity.md#preconditions)

2. `assert` can fail because one of the expected consumer groups is missing or only partially visible after recovery.
   In human terms, Kafka came back, but the recovered internal offsets state is incomplete or not ready yet.
   Harness help: it retries group inspection for a bounded stabilization window and stores the raw `kafka-consumer-groups --describe` output for each canonical group.
   Technical detail: [Scenario 04 A1](../scenario-04-consumer-offset-continuity.md#a1-canonical-consumer-groups-are-present-and-fully-described)

3. `assert` can fail because the recovered committed offsets no longer match the source snapshot contract.
   This catches the case where the group exists, but its saved position drifted during recovery.
   Harness help: it normalizes the recovered offsets into JSON and compares them directly against the manifest-backed expected offsets.
   Technical detail: [Scenario 04 A2](../scenario-04-consumer-offset-continuity.md#a2-recovered-committed-offsets-match-the-manifest-exactly)

4. `assert` can fail because a real resumed consumer starts from the wrong offset.
   This is the user-visible check: the stored offsets may look correct, but the consumer still has to begin reading from those positions in practice.
   Harness help: it runs a containerized resume probe with the recovered group IDs and records the first seen offset on every partition.
   Technical detail: [Scenario 04 A3](../scenario-04-consumer-offset-continuity.md#a3-resumed-consumers-start-exactly-at-the-inherited-offsets)

## How The Harness Helps Recovery

- It separates "the group exists" from "the offsets are correct" from "a real consumer actually resumes correctly," which makes failures easier to localize.
- It keeps both raw CLI output and normalized JSON evidence, so offset mismatches can be diagnosed without re-running the whole cluster immediately.
- It uses a repo-managed containerized probe instead of host-installed Python dependencies, which keeps the verification path portable and isolated.
