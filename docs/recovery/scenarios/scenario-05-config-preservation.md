# Scenario 05: Topic And Broker Config Preservation

## Objective

Prove that dynamic topic configs and broker-level dynamic overrides survive the snapshot rewrite unchanged.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 01 green
- canonical source manifest must record config expectations

## Source Fixture

The canonical source fixture must include:

- retention-tuned topics
- compacted topics
- a compressed topic
- at least one broker-level dynamic override

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md).
2. Start the recovery cluster.
3. Dump topic-level dynamic configs for the configured topics.
4. Dump broker-level dynamic configs for the configured broker(s).

## Assertions

- configured topic overrides match the source manifest exactly
- the broker-level dynamic override is still present
- default topics do not accidentally gain dynamic overrides
- the rewrite tool did not corrupt or drop `ConfigRecord` state

## Automation Contract

- source seeding must dump expected config state into the snapshot manifest
- `assert` should compare both topic and broker dynamic config views

## Manual Fallback

Use `kafka-configs.sh --describe` for topics and brokers.

## Report Artifacts

- topic config dumps
- broker config dumps
- source-vs-recovered config comparison
