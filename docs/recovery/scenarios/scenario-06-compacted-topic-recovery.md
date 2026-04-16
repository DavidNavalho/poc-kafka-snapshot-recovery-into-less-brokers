# Scenario 06: Compacted Topic Recovery

## Objective

Prove that compacted topics preserve latest-per-key semantics after recovery.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 02 green
- canonical source fixture must include repeated keys and expected latest values

## Source Fixture

Use the canonical compacted topics with deterministic repeated-key writes and recorded expected final values.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md).
2. Start the recovery cluster.
3. Allow the log cleaner to run if needed.
4. Consume the compacted topics from the beginning and verify latest values per key.

## Assertions

- compacted topics are present and still configured with `cleanup.policy=compact`
- latest value per key matches the source manifest
- no cleaner-related errors appear in broker logs
- disk usage stabilizes rather than growing unbounded

## Automation Contract

- source seeding must write a latest-value manifest for the compacted topics
- `assert` should rebuild a recovered latest-value map and compare it to the manifest

## Manual Fallback

Consume compacted topics with key printing enabled and compare against the expected latest-value set.

## Report Artifacts

- topic config output
- consumed compacted-topic sample output
- latest-value comparison
- cleaner log excerpts
