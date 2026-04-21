#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


IMAGE = {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0",
}

RACKS = {
    "rack-a": [0, 1, 2],
    "rack-b": [3, 4, 5],
    "rack-c": [6, 7, 8],
}

TOPICS = [
    {
        "name": "recovery.default.6p",
        "partitions": 6,
        "replication_factor": 3,
        "payload_bytes": 512,
        "generator": "fixed-count-by-partition",
        "messages_per_partition": 10000,
        "configs": {},
    },
    {
        "name": "recovery.default.12p",
        "partitions": 12,
        "replication_factor": 3,
        "payload_bytes": 512,
        "generator": "fixed-count-by-partition",
        "messages_per_partition": 10000,
        "configs": {},
    },
    {
        "name": "recovery.default.24p",
        "partitions": 24,
        "replication_factor": 3,
        "payload_bytes": 512,
        "generator": "fixed-count-by-partition",
        "messages_per_partition": 5000,
        "configs": {},
    },
    {
        "name": "recovery.retention.short",
        "partitions": 6,
        "replication_factor": 3,
        "payload_bytes": 512,
        "generator": "fixed-count-by-partition",
        "messages_per_partition": 4000,
        "configs": {
            "retention.ms": "3600000",
            "retention.bytes": "268435456",
        },
    },
    {
        "name": "recovery.retention.long",
        "partitions": 6,
        "replication_factor": 3,
        "payload_bytes": 512,
        "generator": "fixed-count-by-partition",
        "messages_per_partition": 4000,
        "configs": {
            "retention.ms": "604800000",
            "retention.bytes": "1073741824",
        },
    },
    {
        "name": "recovery.compacted.accounts",
        "partitions": 6,
        "replication_factor": 3,
        "payload_bytes": 256,
        "generator": "compacted-fixed-keys",
        "keys_per_partition": 100,
        "versions_per_key": 10,
        "configs": {
            "cleanup.policy": "compact",
            "min.cleanable.dirty.ratio": "0.1",
        },
        "key_prefix": "acct",
    },
    {
        "name": "recovery.compacted.orders",
        "partitions": 6,
        "replication_factor": 3,
        "payload_bytes": 256,
        "generator": "compacted-fixed-keys",
        "keys_per_partition": 100,
        "versions_per_key": 10,
        "configs": {
            "cleanup.policy": "compact",
            "min.cleanable.dirty.ratio": "0.1",
        },
        "key_prefix": "order",
    },
    {
        "name": "recovery.compressed.zstd",
        "partitions": 12,
        "replication_factor": 3,
        "payload_bytes": 2048,
        "generator": "fixed-count-by-partition",
        "messages_per_partition": 4000,
        "configs": {
            "compression.type": "zstd",
            "max.message.bytes": "10485760",
        },
    },
    {
        "name": "recovery.txn.test",
        "partitions": 6,
        "replication_factor": 3,
        "payload_bytes": 256,
        "generator": "transactional-one-per-partition",
        "committed_transaction_count": 100,
        "messages_per_transaction": 6,
        "ongoing_transaction_count": 1,
        "messages_in_ongoing_transaction": 6,
        "configs": {},
    },
    {
        "name": "recovery.consumer.test",
        "partitions": 12,
        "replication_factor": 3,
        "payload_bytes": 512,
        "generator": "fixed-count-by-partition",
        "messages_per_partition": 8000,
        "configs": {},
    },
]

CONSUMER_GROUPS = [
    {
        "group_id": "recovery.group.25",
        "topic": "recovery.consumer.test",
        "committed_offset_per_partition": 2000,
    },
    {
        "group_id": "recovery.group.50",
        "topic": "recovery.consumer.test",
        "committed_offset_per_partition": 4000,
    },
    {
        "group_id": "recovery.group.75",
        "topic": "recovery.consumer.test",
        "committed_offset_per_partition": 6000,
    },
]

BROKER_DYNAMIC_CONFIGS = [
    {
        "broker_id": 0,
        "configs": {
            "log.cleaner.threads": "2",
        },
    }
]

TRANSACTIONS = {
    "committed_transactional_id": "recovery.txn.committed",
    "ongoing_transactional_id": "recovery.txn.ongoing",
    "committed_transaction_count": 100,
    "messages_per_committed_transaction": 6,
    "ongoing_transaction_count": 1,
    "messages_in_ongoing_transaction": 6,
    "expected_read_committed_total_messages": 600,
}


def _partition_map(partitions: int, value: int) -> dict[str, int]:
    return {str(partition): value for partition in range(partitions)}


def _topic_entry(topic: dict) -> dict:
    entry = {
        "name": topic["name"],
        "partitions": topic["partitions"],
        "replication_factor": topic["replication_factor"],
        "payload_bytes": topic["payload_bytes"],
        "seed_plan": {
            "generator": topic["generator"],
        },
        "configs": topic["configs"],
    }
    if topic["generator"] == "fixed-count-by-partition":
        entry["seed_plan"]["messages_per_partition"] = topic["messages_per_partition"]
        entry["expected_latest_offsets"] = _partition_map(
            topic["partitions"], topic["messages_per_partition"]
        )
    elif topic["generator"] == "compacted-fixed-keys":
        entry["seed_plan"]["keys_per_partition"] = topic["keys_per_partition"]
        entry["seed_plan"]["versions_per_key"] = topic["versions_per_key"]
        entry["expected_latest_offsets"] = _partition_map(
            topic["partitions"], topic["keys_per_partition"] * topic["versions_per_key"]
        )
    elif topic["generator"] == "transactional-one-per-partition":
        entry["seed_plan"]["committed_transaction_count"] = topic[
            "committed_transaction_count"
        ]
        entry["seed_plan"]["messages_per_transaction"] = topic["messages_per_transaction"]
        entry["seed_plan"]["ongoing_transaction_count"] = topic["ongoing_transaction_count"]
        entry["seed_plan"]["messages_in_ongoing_transaction"] = topic[
            "messages_in_ongoing_transaction"
        ]
        # Committed transaction control markers consume offsets, but the in-flight
        # transaction has not emitted its terminal marker at clean-stop time.
        entry["expected_latest_offsets"] = _partition_map(topic["partitions"], 201)
        entry["expected_read_committed_offsets"] = _partition_map(topic["partitions"], 100)
    else:
        raise ValueError(f"unsupported generator {topic['generator']}")
    return entry


def build_fixture() -> dict:
    return {
        "image": IMAGE,
        "cluster": {
            "kraft_mode": "combined",
            "broker_ids": list(range(9)),
            "racks": RACKS,
            "log_dirs_per_broker": 2,
        },
        "topics": [_topic_entry(topic) for topic in TOPICS],
        "consumer_groups": [
            {
                "group_id": group["group_id"],
                "topic": group["topic"],
                "expected_committed_offsets": _partition_map(12, group["committed_offset_per_partition"]),
            }
            for group in CONSUMER_GROUPS
        ],
        "broker_dynamic_configs": BROKER_DYNAMIC_CONFIGS,
        "transactions": TRANSACTIONS,
        "internal_topics": [
            "__consumer_offsets",
            "__transaction_state",
            "__cluster_metadata",
        ],
    }


def build_compacted_expectation(topic: dict) -> dict:
    values = {}
    for partition in range(topic["partitions"]):
        for key_index in range(topic["keys_per_partition"]):
            key = f"{topic['key_prefix']}-{partition}-{key_index:03d}"
            values[key] = "v09"
    return {
        "topic": topic["name"],
        "expected_latest_values": values,
    }


def command_fixture_json(_args: argparse.Namespace) -> int:
    json.dump(build_fixture(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def command_manifest(args: argparse.Namespace) -> int:
    checkpoint = json.loads(Path(args.checkpoint_json).read_text(encoding="utf-8"))
    fixture = build_fixture()
    manifest = {
        "schema_version": 1,
        "snapshot_label": args.snapshot_label,
        "source_fixture_version": args.snapshot_label,
        "created_at_utc": args.created_at_utc,
        "image": fixture["image"],
        "cluster": {
            "cluster_id": args.cluster_id,
            "kraft_mode": fixture["cluster"]["kraft_mode"],
            "broker_ids": fixture["cluster"]["broker_ids"],
            "racks": fixture["cluster"]["racks"],
            "log_dirs_per_broker": fixture["cluster"]["log_dirs_per_broker"],
        },
        "metadata_snapshot": {
            "quorum_state_data_version": args.quorum_state_data_version,
            "dynamic_quorum": args.dynamic_quorum,
            "selected_checkpoint": checkpoint,
        },
        "topics": fixture["topics"],
        "consumer_groups": fixture["consumer_groups"],
        "broker_dynamic_configs": fixture["broker_dynamic_configs"],
        "transactions": fixture["transactions"],
        "expectation_files": {
            "compacted_latest_values": {
                topic["name"]: f"expectations/compacted/{topic['name']}.json"
                for topic in TOPICS
                if topic["generator"] == "compacted-fixed-keys"
            }
        },
    }
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


def command_write_compacted_expectations(args: argparse.Namespace) -> int:
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    for topic in TOPICS:
        if topic["generator"] != "compacted-fixed-keys":
            continue
        expectation = build_compacted_expectation(topic)
        target = output_dir / f"{topic['name']}.json"
        target.write_text(json.dumps(expectation, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


def parse_bool(value: str) -> bool:
    lowered = value.lower()
    if lowered in {"1", "true", "yes"}:
        return True
    if lowered in {"0", "false", "no"}:
        return False
    raise argparse.ArgumentTypeError(f"invalid boolean value: {value}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    fixture_json = subparsers.add_parser("fixture-json")
    fixture_json.set_defaults(func=command_fixture_json)

    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--snapshot-label", required=True)
    manifest.add_argument("--created-at-utc", required=True)
    manifest.add_argument("--cluster-id", required=True)
    manifest.add_argument("--checkpoint-json", required=True)
    manifest.add_argument("--quorum-state-data-version", type=int, required=True)
    manifest.add_argument("--dynamic-quorum", type=parse_bool, required=True)
    manifest.add_argument("--output", required=True)
    manifest.set_defaults(func=command_manifest)

    expectations = subparsers.add_parser("write-compacted-expectations")
    expectations.add_argument("--output-dir", required=True)
    expectations.set_defaults(func=command_write_compacted_expectations)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
