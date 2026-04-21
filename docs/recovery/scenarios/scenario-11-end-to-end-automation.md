# Scenario 11: End-To-End Automation Dry Run

## Objective

Prove that the clean-stop recovery flow can run as one scripted suite from snapshot selection through per-scenario reporting without manual intervention.

This scenario is the first harness productization check. It does not replace the individual scenario assertions; it orchestrates the already-green scenarios as one reproducible automation surface.

## Status

- Phase: 1
- State: Implemented
- Scenario 01, Scenario 02, Scenario 03, Scenario 04, Scenario 05, Scenario 06, Scenario 07, Scenario 08, and Scenario 10 are prerequisites and already green
- Canonical fixture revision for this scenario: `baseline-clean-v3`
- Latest clean run: `20260421T163100Z`
- Latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-11-20260421T163100Z.md`
- Delivered automation: `automation/scenarios/scenario-11/run`, `automation/scenarios/scenario-11/assert`, `automation/scenarios/scenario-11/report`
- Supporting tests landed in `automation/tests/scenario_11_run_test.sh`, `automation/tests/scenario_11_assert_test.sh`, and `automation/tests/scenario_11_report_test.sh`

## Preconditions

- Scenario 01 green
- Scenario 02 green
- Scenario 03 green
- Scenario 04 green
- Scenario 05 green
- Scenario 06 green
- Scenario 07 green
- Scenario 08 green
- Scenario 10 green
- canonical snapshot label `baseline-clean-v3`

## Source Fixture

Use the canonical clean-stop snapshot label `baseline-clean-v3`.

The authoritative inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v3/manifest.json`
- the individual scenario contracts for:
  - `scenario-01`
  - `scenario-02`
  - `scenario-04`
  - `scenario-05`
  - `scenario-06`
  - `scenario-07`
  - `scenario-08`
  - `scenario-10`

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Harness Spec](../harness-spec.md)
- [Report Contract](../reports/README.md)
- [Automation Surface](../../../automation/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Scope Boundary

Scenario 11 proves:

- one suite command can execute the core clean-stop validation flow end to end
- the suite can create isolated run IDs per scenario automatically
- the suite persists readable step logs, scenario results, and report paths in one bundle
- every in-scope scenario passes from a fresh workdir

It does **not** prove:

- normalized repeatability across two suite runs
- the negative-path stray scenario as part of the suite happy path
- the deferred live-snapshot behavior

Those belong to Scenario 12 and Scenario 09.

## Core Scenario Set

The suite should run these scenarios in this exact order:

1. `scenario-01`
2. `scenario-02`
3. `scenario-04`
4. `scenario-05`
5. `scenario-06`
6. `scenario-07`
7. `scenario-08`
8. `scenario-10`

`scenario-03` is intentionally excluded from the Scenario 11 happy-path suite because it is a deliberate fault-injection scenario, not a clean-stop correctness gate.

## Recovery Procedure

1. Start a Scenario 11 suite run:
   - `automation/scenarios/scenario-11/run baseline-clean-v3 <run-id>`
2. For each core scenario in the fixed suite order:
   - create a fresh scenario-specific run ID derived from the suite run ID
   - run `prepare`
   - run `rewrite`
   - run `up`
   - run the scenario `assert`
   - run the scenario `report`
   - run `down`
3. Persist a suite manifest that records:
   - suite run metadata
   - scenario IDs and derived run IDs
   - per-step status
   - per-scenario assert-summary path
   - per-scenario report path
4. Run `automation/scenarios/scenario-11/assert <run-id>`.
5. Run `automation/scenarios/scenario-11/report <run-id>`.

## Timing And Failure Rules

- the suite should fail fast on the first scenario step failure
- if a failure occurs after `up` succeeded, the suite must still attempt `down` for that scenario before exiting
- the suite must preserve step logs even when it fails early
- the suite must not reuse an existing Scenario 11 run directory

## Assertions

### A1. The suite manifest covers the full core scenario set in the required order

Pass when:

- the suite manifest exists
- it lists the exact core scenario set in the expected order
- every listed scenario has a derived run ID

### A2. Every orchestrated scenario step completed successfully

Pass when:

- for every core scenario, the steps `prepare`, `rewrite`, `up`, `assert`, `report`, and `down` are all recorded as successful

### A3. Every orchestrated core scenario ended in a passing assert summary

Pass when:

- every referenced per-scenario `assert-summary.json` exists
- every referenced per-scenario summary reports `status = pass`

### A4. The suite produced a complete report bundle automatically

Pass when:

- every referenced per-scenario report exists
- every per-step log file exists
- the Scenario 11 report itself exists

## Automation Contract

Scenario 11 should add:

- `automation/scenarios/scenario-11/run`
- `automation/scenarios/scenario-11/assert`
- `automation/scenarios/scenario-11/report`
- `automation/tests/scenario_11_run_test.sh`
- `automation/tests/scenario_11_assert_test.sh`
- `automation/tests/scenario_11_report_test.sh`

The suite manifest should be machine-readable JSON stored under:

- `fixtures/scenario-runs/scenario-11/<run-id>/artifacts/suite-manifest.json`

The suite log root should be:

- `fixtures/scenario-runs/scenario-11/<run-id>/artifacts/steps/`

## Manual Fallback

The manual fallback is the current operator flow of executing the individual scenario scripts one by one. Scenario 11 exists specifically to replace that workflow with one supported command.

## Report Artifacts

- Scenario 11 suite manifest
- per-scenario step logs
- per-scenario assert summaries
- per-scenario report paths
- the Scenario 11 report itself
