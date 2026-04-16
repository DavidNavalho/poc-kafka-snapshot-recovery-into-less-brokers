# Scenario 01: Quorum And Metadata Loading

## Objective

Prove that the copied Region A data, after metadata cleanup and snapshot rewrite, can boot as a valid 3-node KRaft cluster.

## Status

- Phase: 1
- State: Planned

## Depends On

- canonical snapshot label `baseline-clean-v1`
- recovery cluster compose spec
- snapshot rewrite tool

## Source Fixture

Use the [canonical source fixture](../source-fixture-spec.md) without any scenario-specific extensions.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Copy source nodes `0`, `1`, and `2` into a disposable scenario working directory.
2. Delete metadata `.log`, `.checkpoint.part`, `.checkpoint.deleted`, and `quorum-state` files from the copied metadata directories.
3. Render recovery config overlays for nodes `0`, `1`, and `2`.
4. Rewrite the best `.checkpoint` with surviving brokers `0,1,2` using the contract in [Snapshot Rewrite Tool](../rewrite-tool-spec.md).
5. Start the 3-node recovery cluster.

## Assertions

- metadata quorum reports exactly 3 voters and 1 leader
- rewritten metadata contains exactly 3 `RegisterBrokerRecord` entries
- no unavailable partitions for in-scope RF=3 topics
- no broker log evidence of stray detection
- no startup failure due to `meta.properties`, `cluster.id`, or voter mismatch

## Automation Contract

- `prepare`: copy snapshot and render recovery config
- `run`: rewrite metadata and start recovery cluster
- `assert`: run quorum, metadata, and unavailable-partition checks
- `report`: capture quorum status, metadata dump, and broker logs

## Manual Fallback

Use the generic flow in [`../manual-runbooks/scenario-runs.md`](../manual-runbooks/scenario-runs.md), then run Kafka CLI checks manually.

## Report Artifacts

- metadata quorum status output
- metadata checkpoint dump
- recovery broker logs
- topic describe output
