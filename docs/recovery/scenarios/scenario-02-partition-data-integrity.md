# Scenario 02: Partition Data Integrity

## Objective

Prove that copied partition data remains readable after recovery and that recovered offsets match the source manifest for representative topics.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 01 green
- source manifest with expected offsets

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md). Focus verification on representative topics across `6`, `12`, and `24` partition counts.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md) from the canonical snapshot.
2. Start the recovery cluster.
3. Query latest offsets for representative topics.
4. Consume sample partitions from beginning to verify readability.

## Assertions

- all representative topics exist with correct partition counts
- all representative partitions are available
- latest offsets match the source manifest for clean-stop snapshots
- sampled partitions are readable end-to-end
- no CRC or segment-recovery errors are present in the clean-stop case

## Automation Contract

- `assert` should compare recovered offsets against the source manifest
- `assert` should also sample-consume at least one partition from each representative topic

## Manual Fallback

Use `GetOffsetShell`, `kafka-topics.sh --describe`, and `kafka-console-consumer.sh` against the recovery cluster.

## Report Artifacts

- representative topic descriptions
- offset comparison output
- sampled consumer output
- broker logs
