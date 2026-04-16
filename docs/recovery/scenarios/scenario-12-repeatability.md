# Scenario 12: Repeatability

## Objective

Prove that running the same recovery procedure from the same immutable snapshot produces the same result.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 11 green or close to green
- deterministic source manifest and deterministic report fields where practical

## Source Fixture

Reuse the exact same immutable snapshot label for both runs.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the standard automated recovery flow from snapshot label `X`.
2. Capture a result bundle.
3. Destroy the recovery working directory.
4. Run the same flow again from the same snapshot label `X`.
5. Compare the result bundles.

## Assertions

- topic definitions match between runs
- latest offsets match between runs
- consumer group offsets match between runs
- config dumps match between runs
- differences are limited to acceptable nondeterministic fields such as leader placement timing or timestamps

## Automation Contract

- the scenario should emit normalized comparison artifacts so timestamp noise does not dominate
- the report should explicitly list accepted nondeterminism

## Manual Fallback

Manual comparison is acceptable for the first pass, but the scenario should eventually automate the normalized diff.

## Report Artifacts

- run 1 report bundle
- run 2 report bundle
- normalized diff output
