# Scenario 06 Report Card

## What This Scenario Is Solving

In plain English, Scenario 06 answers this recovery question:

after we recover the cluster, do compacted topics still represent the right latest value for each key, or did recovery lose the logical end state those topics are supposed to preserve?

This is the compacted-data confidence scenario. A cluster can boot and serve reads while still being wrong if replaying a compacted topic no longer produces the expected final state for each business key.

Main technical references:

- [Scenario 06 Technical Spec](../scenario-06-compacted-topic-recovery.md)
- [Canonical Source Fixture](../../source-fixture-spec.md)

## Where This Scenario Can Fail

This scenario is not meant to fail in the happy path. If it fails, it should usually fail in one of the checkpoints below.

1. `prepare`, `rewrite`, or `up` can fail before any compacted-topic check starts.
   Scenario 06 still depends on the same metadata and cluster-start path already proven in Scenario 01, Scenario 02, Scenario 05, and Scenario 08.
   Harness help: it keeps the same staged recovery flow, so an early failure is still tied to a specific phase.
   Technical detail: [Scenario 06 Preconditions](../scenario-06-compacted-topic-recovery.md#preconditions)

2. `assert` can fail because a recovered compacted topic lost the compaction settings that define how it should behave.
   In human terms, the topic came back, but it is no longer configured as the compacted topic we meant to recover.
   Harness help: it captures the raw topic-config output and a normalized config map for each compacted topic.
   Technical detail: [Scenario 06 A1](../scenario-06-compacted-topic-recovery.md#a1-compacted-topics-retain-the-required-dynamic-compaction-configs)

3. `assert` can fail because replaying the recovered compacted topic no longer reconstructs the expected latest value per key.
   This is the main logical-state check: the recovered topic history may exist, but it still has to rebuild the correct final map.
   Harness help: it replays each compacted topic from the beginning in a containerized probe and compares the resulting map to the explicit expectation file saved with the snapshot.
   Technical detail: [Scenario 06 A2](../scenario-06-compacted-topic-recovery.md#a2-reconstructed-latest-value-maps-match-the-snapshot-expectation-files-exactly)

4. `assert` can fail because the recovery logs show cleaner-related failures while the compacted topics are being exercised.
   In human terms, Kafka may be telling us the compaction machinery is unhealthy even if a quick read still works.
   Harness help: it scans the recovery logs with a narrow denylist and saves the matching lines as an artifact.
   Technical detail: [Scenario 06 A3](../scenario-06-compacted-topic-recovery.md#a3-recovery-logs-show-no-narrow-cleaner-failure-patterns-while-compact-topics-are-exercised)

## How The Harness Helps Recovery

- It compares recovered logical state to the explicit snapshot expectation files instead of relying on ad hoc manual replay.
- It separates config drift, logical latest-value drift, and cleaner-log health so failures are easier to localize.
- It uses a repo-managed containerized replay helper, which keeps the verification path isolated from the host environment.
