# Harness Spec

## Purpose

Define the test harness that will validate the recovery design in Docker before we attempt anything in a more realistic environment.

## Phase 1 Scope

Phase 1 proves correctness of the recovery flow under clean-stop snapshots:

- source cluster topology and placement assumptions
- snapshot copy workflow
- metadata rewrite workflow
- recovery cluster startup
- topic/data/config/offset/transaction correctness
- repeatability

## Out Of Scope For Phase 1

- true infrastructure snapshots
- live-copy crash-consistency validation
- production-scale data volumes
- throughput benchmarking

Those are later extensions, not blockers for the first feasibility pass.

## Tooling Requirements

- Docker Desktop with Compose v2
- Confluent Platform 8.1.x container images
- `bash`
- `python3`
- Python package `confluent-kafka` for the transactional fixture seed helper
- `jq`
- `rsync` or `cp -a`
- enough local disk to hold:
  - one live 9-node source cluster
  - at least one immutable snapshot set
  - one disposable 3-node scenario working copy

## Topology Requirements

The canonical source cluster must look like production in the ways that matter:

- 9 KRaft nodes
- every node runs as combined `broker,controller`
- 3 logical regions / racks
- broker IDs `0..8`
- rack IDs grouped as:
  - region A: brokers `0,1,2`
  - region B: brokers `3,4,5`
  - region C: brokers `6,7,8`
- RF=3 topics placed with rack awareness

## Storage Requirements

Use host bind mounts for all Kafka storage. Do not use opaque Docker volumes.

The source cluster should expose, per node:

- `metadata.log.dir`
- `log.dirs[0]`
- `log.dirs[1]`
- broker log output directory or captured container logs
- rendered broker config

This keeps the "snapshot" model simple: copy directories on the host after a clean stop.

## Metadata Snapshot Selection Contract

Checkpoint selection is an orchestration concern, not a rewrite-tool concern. The harness must choose the input checkpoint deterministically before invoking the rewrite tool.

Selection rules:

1. Collect every `*.checkpoint` file from the copied metadata directories of the source nodes being recovered.
2. Parse each basename as `<offset>-<epoch>.checkpoint`.
3. Compare candidates by:
   - highest numeric `offset`
   - then highest numeric `epoch`
   - then lexicographically smallest full path as a deterministic final tiebreak
4. Record the selected file in the snapshot manifest under `metadata_snapshot.selected_checkpoint`.
5. Use that exact selected checkpoint basename for the rewritten output as well.

If any candidate basename cannot be parsed, the harness must fail rather than guessing.

## Fixture Lifecycle

1. Bring up the canonical source cluster.
2. Seed deterministic test data and config.
3. Validate the source cluster against the source-fixture manifest.
4. Stop the source cluster cleanly.
5. Copy the live bind-mounted directories into an immutable snapshot label.
6. For each scenario, copy the relevant source nodes into a disposable working directory.
7. Apply the recovery preparation steps.
8. Start the recovery cluster.
9. Run scenario-specific assertions and capture artifacts.
10. Write a short report.
11. Remove the scenario working directory.

## Resource Strategy

This harness must fit on a resource-constrained Mac mini.

The sizing policy is:

- smoke profile: smallest possible data, used while wiring automation
- baseline profile: default profile, used for most correctness runs
- stretch profile: optional larger dataset, only after baseline is stable

The default phase-1 dataset should aim for correctness over volume. Approximate target:

- total retained data: low single-digit GBs, not tens or hundreds of GBs
- enough partitions to exercise distribution, offsets, compaction, and reassignment

## Scenario Contract

Every scenario spec must define:

- purpose
- source fixture dependency
- additional setup, if any
- recovery actions
- assertions
- automation entry points
- manual fallback steps
- required report artifacts

## Artifact Contract

Each scenario run should capture:

- recovery broker logs
- metadata quorum status
- topic descriptions
- consumer group state where relevant
- config dumps where relevant
- a scenario summary report

## Relationship To Existing Docs

- [`final-recovery-plan.md`](../../final-recovery-plan.md) defines the recovery design.
- this file defines the validation harness that will exercise that design.
- scenario files under `scenarios/` define how we will prove each design claim.
