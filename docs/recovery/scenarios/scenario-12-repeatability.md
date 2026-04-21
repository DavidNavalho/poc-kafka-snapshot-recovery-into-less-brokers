# Scenario 12: Repeatability

## Objective

Prove that running the same clean-stop suite from the same immutable snapshot produces the same normalized result bundle twice.

Scenario 12 builds directly on Scenario 11. It does not rerun the old manual flow; it reruns the Scenario 11 suite and compares the stable outputs after stripping run-specific noise.

## Status

- Phase: 1
- State: Implemented
- Latest clean run report: [2026-04-21-scenario-12-20260421T170720Z.md](../reports/runs/2026-04-21-scenario-12-20260421T170720Z.md)

## Preconditions

- Scenario 11 green
- canonical snapshot label `baseline-clean-v3`
- the suite-manifest contract from Scenario 11 must be available

## Source Fixture

Reuse the same immutable snapshot label for both suite runs:

- `baseline-clean-v3`

The authoritative inputs for this scenario are:

- `fixtures/snapshots/baseline-clean-v3/manifest.json`
- `fixtures/scenario-runs/scenario-11/<suite-run-id>/artifacts/suite-manifest.json`
- stable per-scenario artifacts referenced by those suite manifests

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Harness Spec](../harness-spec.md)
- [Report Contract](../reports/README.md)
- [Scenario 11 Technical Spec](./scenario-11-end-to-end-automation.md)

## Scope Boundary

Scenario 12 proves:

- the Scenario 11 suite can be rerun from the same immutable snapshot
- both suite runs pass
- the normalized bundle of stable recovery results is identical between runs

It does **not** prove:

- repeatability under a different snapshot label
- repeatability after live-copy or crash-consistent capture
- byte-identical raw artifacts including timestamps, run IDs, absolute paths, or generated probe IDs

## Normalized Bundle Contract

The repeatability bundle should include only stable fields from the Scenario 11 suite outputs.

At minimum it must normalize and compare:

- Scenario 01 topic definition evidence:
  - topic names
  - partition counts from topic-describe output
- Scenario 02:
  - latest offsets
  - sampled partition counts
- Scenario 04:
  - committed consumer-group offsets
  - resumed first-seen offsets
- Scenario 05:
  - normalized topic configs
  - normalized broker configs
- Scenario 06:
  - compacted latest-value maps
  - normalized compacted-topic configs
- Scenario 07:
  - normalized read-committed probe counts
  - normalized transactional probe result, excluding run-specific transactional IDs
- Scenario 08:
  - normalized logdir listings
  - normalized recovered `meta.properties` files
- Scenario 10:
  - normalized pre-expansion and post-expansion partition state
  - post-expansion sampled partition counts

The normalized bundle must exclude or rewrite:

- run IDs
- timestamps
- absolute artifact paths
- generated transactional probe IDs
- ordering noise where Kafka returns ISR members in a different but equivalent order

## Recovery Procedure

1. Start a Scenario 12 run:
   - `automation/scenarios/scenario-12/run baseline-clean-v3 <run-id>`
2. Run Scenario 11 suite pass 1 with derived suite run ID `<run-id>-run1`.
3. Build normalized bundle 1 from the resulting Scenario 11 suite manifest.
4. If run 1 failed or bundle 1 could not be built, mark run 2 as skipped and fail the scenario without starting a second suite.
5. Otherwise run Scenario 11 suite pass 2 with derived suite run ID `<run-id>-run2`.
6. Build normalized bundle 2 from the resulting Scenario 11 suite manifest.
7. Compare bundle 1 and bundle 2.
8. Write the Scenario 12 assert summary and report.

## Assertions

### A1. The first suite rerun completed successfully

Pass when:

- Scenario 11 run 1 finished with suite status `pass`
- its suite manifest exists

### A2. The second suite rerun completed successfully

Pass when:

- Scenario 11 run 2 finished with suite status `pass`
- its suite manifest exists

### A3. Both normalized bundles were generated from the expected stable artifact surface

Pass when:

- normalized bundle 1 exists
- normalized bundle 2 exists
- both bundles cover the same scenario IDs

### A4. The normalized bundles match exactly

Pass when:

- the normalized bundle files are byte-equal
- any generated diff file is empty

Fail when:

- the bundle files differ after normalization

## Automation Contract

Scenario 12 should add:

- `automation/lib/build_repeatability_bundle.py`
- `automation/scenarios/scenario-12/run`
- `automation/scenarios/scenario-12/assert`
- `automation/scenarios/scenario-12/report`
- `automation/tests/scenario_12_run_test.sh`
- `automation/tests/scenario_12_assert_test.sh`
- `automation/tests/scenario_12_report_test.sh`

The Scenario 12 run manifest should live at:

- `fixtures/scenario-runs/scenario-12/<run-id>/artifacts/repeatability-manifest.json`

The normalized bundles should live at:

- `fixtures/scenario-runs/scenario-12/<run-id>/artifacts/normalized/run1.bundle.json`
- `fixtures/scenario-runs/scenario-12/<run-id>/artifacts/normalized/run2.bundle.json`
- `fixtures/scenario-runs/scenario-12/<run-id>/artifacts/normalized/diff.txt`

Current green run:

- `automation/scenarios/scenario-12/run baseline-clean-v3 20260421T170720Z`

## Manual Fallback

Manual comparison is acceptable only for ad hoc debugging. The supported path for this scenario is the automated normalized-bundle comparison.

## Report Artifacts

- run 1 Scenario 11 suite manifest
- run 2 Scenario 11 suite manifest
- normalized bundle 1
- normalized bundle 2
- normalized diff output
- Scenario 12 report
