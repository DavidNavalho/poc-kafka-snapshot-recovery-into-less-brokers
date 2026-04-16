# Scenario 03: Stray Detection Safety Net

## Objective

Prove two things:

1. the happy path does not produce stray directories
2. a deliberately corrupted metadata assignment can be caught and recovered before deletion because `file.delete.delay.ms` is extended

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 01 green
- test harness support for post-rewrite fault injection

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) and its clean snapshot label.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

### Positive Case

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md).
2. Start the recovery cluster.

### Negative Case

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md) through snapshot rewrite.
2. Mutate the rewritten metadata so that a known on-disk partition no longer lists its real broker in `Replicas[]`.
3. Start the recovery cluster with `file.delete.delay.ms=86400000`.
4. Stop the cluster before the delay window expires.
5. Restore the correct rewritten snapshot and rename any `-stray` directories back to their original names.
6. Restart and verify recovery.

## Assertions

- positive case yields zero `-stray` directories
- positive case yields zero stray-related broker log lines
- negative case yields one or more `-stray` directories for the injected fault
- negative case preserves data in those directories until the delay window expires
- restoring the correct rewritten snapshot and renaming directories back allows a clean restart

## Automation Contract

- fault injection must be explicit and reproducible
- `assert` must distinguish positive and negative cases
- `cleanup` must remove mutated working copies and preserve only artifacts

## Manual Fallback

Manual runs may rename `-stray` directories back only after the cluster is stopped.

## Report Artifacts

- positive-case broker logs
- negative-case broker logs
- directory listings before and after stray renames
- recovered restart evidence
