# Scenario 11: End-To-End Automation Dry Run

## Objective

Prove that the clean-stop recovery flow can run as one scripted path from snapshot preparation through reporting.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenarios 01 through 08 and 10 should all be green individually

## Source Fixture

Use the canonical snapshot label `baseline-clean-v1`.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Automation Surface](../../../automation/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Prepare a new scenario working directory from the immutable snapshot.
2. Render recovery config overlays.
3. Rewrite metadata.
4. Start the recovery cluster.
5. Run the core assertion suite.
6. Render a report bundle.
7. Tear the scenario down.

## Assertions

- the scripted flow completes without manual intervention
- all core correctness assertions pass
- a report bundle is written automatically
- the scenario can be rerun with a fresh working directory

## Automation Contract

- this scenario is the contract test for the automation surface described in [Automation Surface](../../../automation/README.md)
- it should fail fast with readable logs if any foundation step is missing

## Manual Fallback

This scenario exists specifically to remove the need for the manual fallback once the harness is mature.

## Report Artifacts

- complete scenario report
- logs for every automation step
- recovery cluster artifacts
