# Compose Specs

This directory is reserved for the Docker Compose files that will drive the recovery test harness.

Use this directory together with:

- [`docs/recovery/harness-spec.md`](../docs/recovery/harness-spec.md) for lifecycle and topology rules
- [`docs/recovery/source-fixture-spec.md`](../docs/recovery/source-fixture-spec.md) for the canonical 9-node source-cluster shape
- [`docs/recovery/scenarios/README.md`](../docs/recovery/scenarios/README.md) for the scenario execution order

## Intended Files

| File | Purpose |
|---|---|
| `source-cluster.compose.yml` | Canonical 9-node Confluent 8.1 source cluster |
| `recovery-cluster.compose.yml` | 3-node recovery target cluster launched from copied snapshot data |
| `tools.compose.yml` | Optional helper services for seeding, assertions, and CLI access |
| `overrides/` | Scenario-specific compose overrides if a scenario truly needs one |

## Compose Requirements

- Use Confluent Platform 8.1.x images. Default target: `confluentinc/cp-kafka:8.1.0`.
- Model all 9 source nodes as combined `broker,controller` KRaft nodes.
- Use host bind mounts, not anonymous/named Docker volumes, for all Kafka data paths.
- Keep storage paths stable and explicit so that "snapshot" simulation is a host-side directory copy.
- Prefer one shared Docker network for both source and recovery compose stacks, but never run both stacks against the same data paths.

## Storage Conventions

The compose files should bind-mount paths under [`fixtures/README.md`](../fixtures/README.md):

- `fixtures/source-cluster/live/`
- `fixtures/snapshots/`
- `fixtures/scenario-runs/`

## Scope

Implemented in this pass:

- [`source-cluster.compose.yml`](./source-cluster.compose.yml)
- [`recovery-cluster.compose.yml`](./recovery-cluster.compose.yml)

Still pending:

- `tools.compose.yml` if we decide a helper service is better than host-side scripting
- any scenario-specific compose overrides
