# Scenario 08: Multiple Log Directories

## Objective

Prove that the recovery works when each broker uses two `log.dirs`, and that the rewritten metadata can load partitions regardless of which disk they live on.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 01 green
- canonical source fixture must already use two `log.dirs` per broker

## Source Fixture

This scenario relies on the canonical cluster being multi-log-dir from the start. No separate source-cluster flavor should be required.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md) from the canonical snapshot.
2. Start the recovery cluster.
3. Verify that data exists under both log directories on recovered nodes.
4. Verify that representative topics are readable and fully available.

## Assertions

- recovered brokers retain partitions under both `log.dirs`
- all in-scope partitions come online
- `meta.properties` remains consistent across both log directories on each broker
- no stray detection occurs on either disk

## Automation Contract

- `assert` must inspect both log-directory roots
- `assert` must compare representative topic offsets against the source manifest

## Manual Fallback

Inspect both log-directory roots directly on disk, then run topic and offset checks.

## Report Artifacts

- directory listings for both log dirs on each recovery broker
- `meta.properties` extracts
- topic and offset verification output
