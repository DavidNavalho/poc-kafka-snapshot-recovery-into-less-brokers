# Scenario 10: RF=1 Steady State And Replica Expansion

## Objective

Prove that the recovered cluster stabilizes cleanly with one live replica per partition, and that a later replica-expansion step works as expected.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 01 green
- Scenario 02 green

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without changes.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md).
2. Start the recovery cluster.
3. Verify the RF=1 steady state after startup settles.
4. Execute a targeted reassignment to place one partition back on brokers `0,1,2`.
5. Verify the reassignment result.

## Assertions

- the recovered steady state has no persistent under-replicated partitions
- representative partitions show `Replicas` length `1` and `ISR = Replicas`
- targeted reassignment completes successfully
- temporary under-replication during reassignment resolves
- expanded partitions end with `Replicas=[0,1,2]` and `ISR=[0,1,2]`

## Automation Contract

- `assert` must check both the pre-expansion steady state and the post-expansion state
- the scenario should generate its reassignment payload deterministically

## Manual Fallback

Use topic describe output before and after `kafka-reassign-partitions.sh`.

## Report Artifacts

- pre-expansion topic describe output
- reassignment command output
- post-expansion topic describe output
