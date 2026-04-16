# Scenario 07: Transaction State Recovery

## Objective

Prove that transaction metadata survives recovery, ongoing transactions resolve, and new transactional producers can operate after reconnect.

## Status

- Phase: 1
- State: Planned

## Depends On

- Scenario 02 green
- canonical source fixture must include committed and intentionally unresolved transaction cases

## Source Fixture

Use the canonical transaction topic and transaction producers defined in the source-fixture spec.

## Authoritative References

- [Canonical Source Fixture](../source-fixture-spec.md)
- [Standard Clean-Stop Recovery Flow](../manual-runbooks/scenario-runs.md)
- [Snapshot Rewrite Tool](../rewrite-tool-spec.md)
- [Report Contract](../reports/README.md)
- [Recovery Design Runbook](../../../final-recovery-plan.md)

## Recovery Procedure

1. Run the [standard clean-stop recovery flow](../manual-runbooks/scenario-runs.md).
2. Start the recovery cluster.
3. Wait at least one transaction timeout interval.
4. Inspect transaction state.
5. Read committed data from the transaction topic.
6. Run a new transactional producer test that calls `initTransactions()`.

## Assertions

- `__transaction_state` is online
- committed transaction data is readable with `read_committed`
- unresolved transactions are eventually aborted or otherwise leave the expected recoverable state
- new transactional producers can initialize and commit without sequence or fencing errors

## Automation Contract

- the source manifest must record the expected committed transaction count
- the scenario should include a tiny transactional-producer probe program or equivalent helper

## Manual Fallback

Use Kafka transaction tooling where available and a small producer helper for the reconnect probe.

## Report Artifacts

- transaction-list output
- `read_committed` consumer output
- transactional probe logs
- broker logs
