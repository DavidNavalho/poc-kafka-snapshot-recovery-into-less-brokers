# Scenario 09: Live Snapshot Extension

## Objective

Extend the harness to validate live-copy crash-consistency behavior after the clean-stop suite is already working.

## Status

- Phase: 2
- State: Deferred

## Why Deferred

The first harness pass is intentionally clean-stop only. Live-copy behavior is important, but it introduces a second axis of complexity that should not block correctness work on the main recovery flow.

## Depends On

- clean-stop Scenarios 01 through 08 and 10 must already be green
- host-side live-copy mechanics must be designed explicitly

## Source Fixture

Reuse the canonical source cluster, but copy data while producers are still active and before the source cluster is stopped.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Proposed Procedure

1. Start from the canonical source fixture with active writes.
2. Copy Region A broker directories while the source cluster is still running.
3. Stop the source cluster only after the copy completes.
4. Run the standard recovery flow from the copied live snapshot.

## Future Assertions

- all in-scope partitions still come online
- broker logs show expected recovery/truncation behavior, not fatal corruption
- recovered offsets are behind the last acknowledged offsets only within the expected copy window
- no stray detection occurs

## Automation Contract

To be designed after the clean-stop suite is stable.

## Manual Fallback

Not defined in phase 1.

## Report Artifacts

- live-copy timing records
- broker recovery log excerpts
- offset-loss comparison against the source-side capture
