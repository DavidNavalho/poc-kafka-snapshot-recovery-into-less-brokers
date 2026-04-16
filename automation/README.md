# Automation Specs

This directory is reserved for the scripts and helpers that will execute the harness.

The automation layer implements the contracts defined by:

- [`docs/recovery/harness-spec.md`](../docs/recovery/harness-spec.md)
- [`docs/recovery/source-fixture-spec.md`](../docs/recovery/source-fixture-spec.md)
- [`docs/recovery/rewrite-tool-spec.md`](../docs/recovery/rewrite-tool-spec.md)
- [`docs/recovery/scenarios/README.md`](../docs/recovery/scenarios/README.md)
- [`docs/recovery/reports/README.md`](../docs/recovery/reports/README.md)

## Command Contract

The first implementation pass should target these entry points:

| Path | Purpose |
|---|---|
| `automation/source-cluster/up` | Start the canonical 9-node source cluster |
| `automation/source-cluster/seed` | Create topics, produce deterministic data, create consumer groups, set configs |
| `automation/source-cluster/validate` | Assert the source cluster matches the fixture spec |
| `automation/source-cluster/stop` | Stop the source cluster cleanly |
| `automation/source-cluster/snapshot` | Copy the clean-stopped source data into an immutable snapshot set |
| `automation/recovery/prepare` | Copy snapshot data into a scenario working directory |
| `automation/recovery/rewrite` | Invoke the snapshot rewrite tool |
| `automation/recovery/up` | Start the 3-node recovery cluster from copied data |
| `automation/recovery/down` | Stop the recovery cluster |
| `automation/scenarios/<scenario-id>/run` | Execute one scenario end-to-end |
| `automation/scenarios/<scenario-id>/assert` | Run scenario-specific checks only |
| `automation/scenarios/<scenario-id>/report` | Render a report bundle from collected artifacts |
| `automation/scenarios/<scenario-id>/cleanup` | Remove the scenario working directory |

## Rules

- Scripts should be idempotent where practical.
- Every script should log its inputs, outputs, and artifacts directory.
- Scenario automation should never mutate the canonical source fixture or the immutable snapshot directories.
- Generated data and copied broker directories should live under `fixtures/`, not in repo root.

## Scope

Implemented in this pass:

- `automation/source-cluster/up`
- `automation/source-cluster/seed`
- `automation/source-cluster/validate`
- `automation/source-cluster/stop`
- `automation/source-cluster/snapshot`
- `automation/recovery/prepare`
- `automation/recovery/rewrite`
- `automation/recovery/up`
- `automation/recovery/down`

Still pending:

- `automation/scenarios/<scenario-id>/...` orchestration
- the actual snapshot rewrite tool binary behind `automation/recovery/rewrite`
- runtime verification against a real local Docker run
