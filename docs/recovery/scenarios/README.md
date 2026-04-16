# Scenario Index

Each file in this directory defines one scenario in a spec-first format.

## Execution Order

| ID | File | Purpose | Phase | Status |
|---|---|---|---|---|
| 01 | [scenario-01-quorum-and-metadata.md](./scenario-01-quorum-and-metadata.md) | Prove the rewritten metadata boots as a 3-node KRaft cluster | 1 | Planned |
| 02 | [scenario-02-partition-data-integrity.md](./scenario-02-partition-data-integrity.md) | Prove copied partition data is readable and offsets match the source manifest | 1 | Planned |
| 03 | [scenario-03-stray-detection-safety-net.md](./scenario-03-stray-detection-safety-net.md) | Prove stray detection is avoided in the happy path and recoverable in a fault-injected case | 1 | Planned |
| 04 | [scenario-04-consumer-offset-continuity.md](./scenario-04-consumer-offset-continuity.md) | Prove consumer groups resume from inherited offsets | 1 | Planned |
| 05 | [scenario-05-config-preservation.md](./scenario-05-config-preservation.md) | Prove topic and broker dynamic configs survive the rewrite | 1 | Planned |
| 06 | [scenario-06-compacted-topic-recovery.md](./scenario-06-compacted-topic-recovery.md) | Prove compacted topics retain latest-per-key data | 1 | Planned |
| 07 | [scenario-07-transaction-state-recovery.md](./scenario-07-transaction-state-recovery.md) | Prove transaction state survives and new transactional producers work | 1 | Planned |
| 08 | [scenario-08-multiple-log-directories.md](./scenario-08-multiple-log-directories.md) | Prove the recovery works with two log directories per broker | 1 | Planned |
| 09 | [scenario-09-live-snapshot-extension.md](./scenario-09-live-snapshot-extension.md) | Extend the harness to crash-consistent live-copy behavior | 2 | Deferred |
| 10 | [scenario-10-rf1-steady-state-and-expansion.md](./scenario-10-rf1-steady-state-and-expansion.md) | Prove the recovered cluster stabilizes at RF=1 and can later expand | 1 | Planned |
| 11 | [scenario-11-end-to-end-automation.md](./scenario-11-end-to-end-automation.md) | Run the whole clean-stop flow as one scripted path | 1 | Planned |
| 12 | [scenario-12-repeatability.md](./scenario-12-repeatability.md) | Prove rerunning from the same snapshot yields the same result | 1 | Planned |

## Shared Rules

- Scenarios run from copied snapshot data, not from the live source cluster.
- Scenario working data lives under `fixtures/scenario-runs/`.
- Scenario specs assume the canonical source fixture defined in [`../source-fixture-spec.md`](../source-fixture-spec.md).
- Every scenario should produce a short report using [`../reports/report-template.md`](../reports/report-template.md).
- The phrase "standard clean-stop recovery flow" means the generic execution path in [`../manual-runbooks/scenario-runs.md`](../manual-runbooks/scenario-runs.md), implementing the recovery design in [`../../../final-recovery-plan.md`](../../../final-recovery-plan.md).
