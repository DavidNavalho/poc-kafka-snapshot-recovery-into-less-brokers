# Source Cluster Manual Flow

## Purpose

Describe how to create and snapshot the canonical 9-node source cluster manually if automation is not ready.

## Preconditions

- Docker Desktop and Compose v2 installed
- compose specs implemented under `compose/`
- enough disk for the live source cluster plus one copied snapshot set
- the source cluster is configured per [`source-fixture-spec.md`](../source-fixture-spec.md), including two `log.dirs` per broker and the canonical topic set

## Manual Outline

1. Start the 9-node source cluster from `compose/source-cluster.compose.yml`.
2. Wait for KRaft quorum and broker readiness.
3. Create the canonical topic set from [`source-fixture-spec.md`](../source-fixture-spec.md).
4. Produce deterministic fixture data.
5. Create consumer groups and commit offsets.
6. Apply dynamic topic and broker config overrides.
7. Validate expected offsets, configs, and transaction state.
8. Stop the source cluster cleanly.
9. Copy `fixtures/source-cluster/live/` into `fixtures/snapshots/<label>/`.
10. Write or update the snapshot manifest.

## Expected Outputs

- immutable snapshot directory under `fixtures/snapshots/`
- manifest for that snapshot label
- enough source-cluster validation evidence to reuse the snapshot for multiple scenarios

## Relationship To Automation

Once scripts exist, this runbook should map cleanly onto:

- `automation/source-cluster/up`
- `automation/source-cluster/seed`
- `automation/source-cluster/validate`
- `automation/source-cluster/stop`
- `automation/source-cluster/snapshot`
