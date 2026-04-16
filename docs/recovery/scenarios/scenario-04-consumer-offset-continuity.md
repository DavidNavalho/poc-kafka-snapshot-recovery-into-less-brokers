# Scenario 04: Consumer Offset Continuity

## Objective

Prove that consumer groups resume from inherited offsets rather than from the beginning of the topic.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 02 green
- source manifest must record committed offsets for the canonical consumer groups

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) with at least three consumer groups and deterministic committed offsets.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md).
2. Start the recovery cluster.
3. Wait for `__consumer_offsets` to stabilize.
4. Describe the canonical consumer groups.
5. Resume consumption with one or more recovered groups.

## Assertions

- expected consumer groups exist
- committed offsets are present for all expected partitions
- recovered committed offsets do not jump ahead of the source manifest
- consumers resume near the inherited offsets, not from the beginning
- any drift is explained and bounded by the harness assumptions

## Automation Contract

- the source manifest must include committed offsets per group and partition
- `assert` should compare recovered offsets to the manifest before resuming consumption

## Manual Fallback

Use `kafka-consumer-groups.sh --describe` and then run consumers with the recovered group IDs.

## Report Artifacts

- consumer group describe output
- offset comparison output
- resumed-consumer output
