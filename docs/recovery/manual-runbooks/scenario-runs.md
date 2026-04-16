# Scenario Manual Flow

## Purpose

Describe the generic manual procedure for running one recovery scenario from an immutable snapshot set.

This runbook is the authoritative meaning of the phrase "standard clean-stop recovery flow" used throughout the scenario specs. It should be read together with:

- [Snapshot Rewrite Tool Spec](../rewrite-tool-spec.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)
- [Report Contract](../reports/README.md)
- [Fixture Layout](../../../fixtures/README.md)

## Generic Flow

1. Choose the snapshot label and scenario ID.
2. Copy the needed source nodes into `fixtures/scenario-runs/<scenario-id>/<run-id>/`.
3. Render recovery config overlays for the three recovery nodes.
4. Delete `quorum-state` and metadata `.log` files from the copied metadata directories.
5. Run the snapshot rewrite tool defined by [`../rewrite-tool-spec.md`](../rewrite-tool-spec.md) unless the scenario intentionally injects a fault around it.
6. Launch the recovery cluster from the copied working data.
7. Run the scenario's assertions.
8. Collect logs and outputs into a report bundle under the reporting contract defined in [`../reports/README.md`](../reports/README.md).
9. Destroy the recovery cluster.
10. Remove the scenario working directory unless you are preserving it for debugging.

## Scenario-Specific Overrides

Each scenario file under `../scenarios/` may add:

- extra source-fixture requirements
- fault injection steps
- extra assertions
- extra artifacts to capture

## Relationship To Automation

Once scripts exist, this runbook should map onto:

- `automation/recovery/prepare`
- `automation/recovery/rewrite`
- `automation/recovery/up`
- `automation/scenarios/<scenario-id>/assert`
- `automation/scenarios/<scenario-id>/report`
- `automation/recovery/down`
