# Fixture Layout

This directory is reserved for generated Kafka data, copied snapshot sets, and scenario working directories.

See also:

- [`docs/recovery/README.md`](../docs/recovery/README.md) for terminology
- [`docs/recovery/source-fixture-spec.md`](../docs/recovery/source-fixture-spec.md) for the canonical dataset and snapshot-label rules
- [`docs/recovery/manual-runbooks/scenario-runs.md`](../docs/recovery/manual-runbooks/scenario-runs.md) for how scenario working directories are used

Large generated files should not be committed. When implementation starts, these paths should be covered by `.gitignore`.

## Planned Layout

```text
fixtures/
  source-cluster/
    artifacts/
      seed/
      validate/
    live/
      broker-0/
      broker-1/
      ...
      broker-8/
  snapshots/
    baseline-clean-v1/
      broker-0/
      broker-1/
      ...
      broker-8/
      manifest.json
    baseline-live-v1/          # deferred phase-2 fixture
  scenario-runs/
    scenario-01/
      <run-id>/
    scenario-02/
      <run-id>/
```

## Rules

- `source-cluster/live/` is the active bind-mounted data for the canonical 9-node source cluster.
- `source-cluster/artifacts/` holds seed and validation evidence from the live canonical cluster.
- `snapshots/<label>/` is immutable once created.
- `scenario-runs/<scenario-id>/<run-id>/` is disposable and may be deleted after reporting.
- Scenarios should copy only the required source nodes into their working directory, typically nodes `0`, `1`, and `2`.

## Snapshot Simulation

For phase 1, a "snapshot" means:

1. Stop the canonical source cluster cleanly.
2. Copy the bind-mounted broker data directories from `source-cluster/live/` into `snapshots/<label>/`.
3. Record a manifest beside the snapshot set describing topic counts, offsets, configs, consumer group state, and metadata snapshot file names.

This is intentionally a clean-stop copy, not a live-copy crash-consistency test. Live snapshot simulation is tracked separately.
