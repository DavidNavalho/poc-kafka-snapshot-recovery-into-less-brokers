# Source Fixture Spec

## Purpose

Define the one canonical seeded 9-node source cluster that most scenarios will reuse.

This file is the authoritative source for:

- the canonical source-cluster topology
- the baseline seeded dataset
- the snapshot labels scenarios are allowed to depend on
- the manifest content that scenario assertions consume

## Version And Image Family

- Confluent Platform 8.1.x
- default image target: `confluentinc/cp-kafka:8.1.0`

## Canonical Cluster Shape

- 9 nodes
- combined `broker,controller`
- broker IDs `0..8`
- 3 racks / regions:
  - rack-a: `0,1,2`
  - rack-b: `3,4,5`
  - rack-c: `6,7,8`
- 2 `log.dirs` per broker from day one
- dedicated `metadata.log.dir` per broker
- source brokers statically lower metadata snapshot thresholds so the fixture emits a KRaft metadata checkpoint that the recovery harness can rewrite deterministically

Using two log directories from the beginning keeps the harness aligned with the multi-log-dir scenario without needing a second source-cluster flavor.

## Canonical Dataset

The baseline source fixture is fully pinned for deterministic seeding and repeatability.

### Baseline User Topics

| Topic | Partitions | RF | Seed Plan | Payload | Dynamic Configs | Primary Scenarios |
|---|---:|---:|---|---:|---|---|
| `recovery.default.6p` | 6 | 3 | `10,000` messages per partition | `512 B` | none | 02, 11, 12 |
| `recovery.default.12p` | 12 | 3 | `10,000` messages per partition | `512 B` | none | 02, 11, 12 |
| `recovery.default.24p` | 24 | 3 | `5,000` messages per partition | `512 B` | none | 02, 11, 12 |
| `recovery.retention.short` | 6 | 3 | `4,000` messages per partition | `512 B` | `retention.ms=3600000`, `retention.bytes=268435456` | 05, 11, 12 |
| `recovery.retention.long` | 6 | 3 | `4,000` messages per partition | `512 B` | `retention.ms=604800000`, `retention.bytes=1073741824` | 05, 11, 12 |
| `recovery.compacted.accounts` | 6 | 3 | `100` keys per partition, `10` versions per key, `1,000` messages per partition | `256 B` | `cleanup.policy=compact`, `min.cleanable.dirty.ratio=0.1` | 06, 11, 12 |
| `recovery.compacted.orders` | 6 | 3 | `100` keys per partition, `10` versions per key, `1,000` messages per partition | `256 B` | `cleanup.policy=compact`, `min.cleanable.dirty.ratio=0.1` | 06, 11, 12 |
| `recovery.compressed.zstd` | 12 | 3 | `4,000` messages per partition | `2048 B` | `compression.type=zstd`, `max.message.bytes=10485760` | 05, 11, 12 |
| `recovery.txn.test` | 6 | 3 | `100` committed transactions x `6` messages each, plus `1` ongoing transaction x `6` messages | `256 B` | none | 07, 11, 12 |
| `recovery.consumer.test` | 12 | 3 | `8,000` messages per partition | `512 B` | none | 04, 11, 12 |

### Internal Topics Expected In The Fixture

The harness does not seed these directly, but the snapshot manifest and recovery assertions must account for them:

- `__consumer_offsets`
- `__transaction_state`
- `__cluster_metadata`

### Deterministic Generation Rules

- All baseline user topics use RF=3.
- All non-transactional topics are written by explicit partition, not by relying on the producer's default partitioner.
- For non-transactional, non-compacted topics, `expected_latest_offset[partition] = messages_written_to_that_partition`.
- For `recovery.compacted.accounts`, keys must be `acct-<partition>-<000..099>` and values must be `v00` through `v09` in order. The expected final value for every key is `v09`.
- For `recovery.compacted.orders`, keys must be `order-<partition>-<000..099>` and values must be `v00` through `v09` in order. The expected final value for every key is `v09`.
- For `recovery.txn.test`, the committed producer must use transactional ID `recovery.txn.committed` and write exactly one committed message per partition in each of `100` transactions. The in-flight producer must use transactional ID `recovery.txn.ongoing` and write exactly one uncommitted message per partition in one open transaction before the source cluster is stopped.

### Pinned Consumer Groups

The canonical source fixture must create these three consumer groups against `recovery.consumer.test`:

| Group ID | Topic | Committed Offset Per Partition | Purpose |
|---|---|---:|---|
| `recovery.group.25` | `recovery.consumer.test` | `2000` | low-water resume check |
| `recovery.group.50` | `recovery.consumer.test` | `4000` | midpoint resume check |
| `recovery.group.75` | `recovery.consumer.test` | `6000` | high-water resume check |

Every partition in `recovery.consumer.test` must have the same committed offset for a given group.

### Pinned Dynamic Overrides

- Broker `0` must have the dynamic broker config override `log.cleaner.threads=2`.
- Topic-level dynamic configs must exactly match the values listed in the baseline topic table above.

### Approximate Baseline Footprint

This baseline is intentionally modest:

- logical single-replica user data is approximately `330 MiB` before indexes and metadata
- with RF=3, total broker storage across the 9-node source cluster should remain roughly in the `1-2 GiB` range

This is large enough to validate correctness while remaining practical on a resource-constrained developer machine.

## Manifest Contract

### Manifest Location

Every immutable snapshot label must contain:

- `fixtures/snapshots/<label>/manifest.json`
- `fixtures/snapshots/<label>/expectations/compacted/<topic>.json` for each compacted topic

### Manifest Schema

`manifest.json` is the authoritative machine-readable contract that scenario automation consumes.

Required top-level shape:

```json
{
  "schema_version": 1,
  "snapshot_label": "baseline-clean-v2",
  "source_fixture_version": "baseline-clean-v2",
  "created_at_utc": "YYYY-MM-DDTHH:MM:SSZ",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  },
  "cluster": {
    "cluster_id": "<cluster-id>",
    "kraft_mode": "combined",
    "broker_ids": [0, 1, 2, 3, 4, 5, 6, 7, 8],
    "racks": {
      "rack-a": [0, 1, 2],
      "rack-b": [3, 4, 5],
      "rack-c": [6, 7, 8]
    },
    "log_dirs_per_broker": 2
  },
  "metadata_snapshot": {
    "quorum_state_data_version": 0,
    "dynamic_quorum": false,
    "selected_checkpoint": {
      "basename": "<20-digit-offset>-<10-digit-epoch>.checkpoint",
      "offset": 0,
      "epoch": 0,
      "sha256": "<sha256>"
    }
  },
  "topics": [],
  "consumer_groups": [],
  "broker_dynamic_configs": [],
  "transactions": {},
  "expectation_files": {
    "compacted_latest_values": {}
  }
}
```

### Topic Entry Schema

Each `topics[]` entry must contain:

```json
{
  "name": "recovery.default.6p",
  "partitions": 6,
  "replication_factor": 3,
  "payload_bytes": 512,
  "seed_plan": {
    "generator": "fixed-count-by-partition",
    "messages_per_partition": 10000
  },
  "configs": {},
  "expected_latest_offsets": {
    "0": 10000,
    "1": 10000
  }
}
```

Additional required topic-entry rules:

- compacted topics must use `generator = "compacted-fixed-keys"` and include `keys_per_partition = 100` and `versions_per_key = 10`
- `recovery.txn.test` must use `generator = "transactional-one-per-partition"` and include:
  - `committed_transaction_count = 100`
  - `messages_per_transaction = 6`
  - `ongoing_transaction_count = 1`
  - `messages_in_ongoing_transaction = 6`
  - `expected_latest_offsets` of `201` for each partition because committed transaction control markers advance the log end offset, while the in-flight transaction contributes one uncommitted data batch but no terminal control marker at clean-stop time
  - `expected_read_committed_offsets` of `100` for each partition

### Consumer Group Entry Schema

Each `consumer_groups[]` entry must contain:

```json
{
  "group_id": "recovery.group.50",
  "topic": "recovery.consumer.test",
  "expected_committed_offsets": {
    "0": 4000,
    "1": 4000
  }
}
```

### Broker Dynamic Config Schema

Each `broker_dynamic_configs[]` entry must contain:

```json
{
  "broker_id": 0,
  "configs": {
    "log.cleaner.threads": "2"
  }
}
```

### Transaction Schema

The `transactions` object must contain:

```json
{
  "committed_transactional_id": "recovery.txn.committed",
  "ongoing_transactional_id": "recovery.txn.ongoing",
  "committed_transaction_count": 100,
  "messages_per_committed_transaction": 6,
  "ongoing_transaction_count": 1,
  "messages_in_ongoing_transaction": 6,
  "expected_read_committed_total_messages": 600
}
```

### Compacted-Topic Expectation Files

For every compacted topic, `expectation_files.compacted_latest_values[topic]` must point to a JSON file with this shape:

```json
{
  "topic": "recovery.compacted.accounts",
  "expected_latest_values": {
    "acct-0-000": "v09",
    "acct-0-001": "v09"
  }
}
```

No scenario automation should infer compacted latest values implicitly when the explicit expectation file is available.

## Snapshot Labels

Planned labels:

- `baseline-clean-v1`
- `baseline-clean-v2`
- `baseline-live-v1` for the deferred live-snapshot scenario

`baseline-clean-v1` remains the original clean-stop fixture used by Scenario 01 and Scenario 02.

`baseline-clean-v2` is the corrected clean-stop fixture revision for config-preservation coverage. It removes the accidental static broker retention override and records a real dynamic broker override on broker `0`.

If a scenario needs materially different source data, create a new snapshot label instead of mutating an existing fixture revision.

## Reuse Rules

- the canonical source cluster is the source of truth
- scenarios never modify it directly
- scenarios work from copied snapshot data only
- if the source fixture changes, bump the snapshot label version and refresh the manifest
