#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import time


NORMALIZED_VALUE_PATTERN = re.compile(r"\|(v[0-9]{2})\|x*$")


def build_consumer(args: argparse.Namespace):
    try:
        from confluent_kafka import Consumer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "python package 'confluent-kafka' is required for compacted-topic replay probes"
        ) from exc

    consumer = Consumer(
        {
            "bootstrap.servers": args.bootstrap_server,
            "group.id": args.group_id,
            "enable.auto.commit": False,
            "auto.offset.reset": "earliest",
            "enable.partition.eof": True,
            "allow.auto.create.topics": False,
        }
    )
    return consumer


def command_latest_values(args: argparse.Namespace) -> int:
    from confluent_kafka import OFFSET_BEGINNING, KafkaError, TopicPartition

    consumer = build_consumer(args)
    latest_values: dict[str, str] = {}
    normalized_latest_values: dict[str, str] = {}
    deleted_keys: set[str] = set()
    per_partition_counts: dict[str, int] = {}
    eof_partitions: set[int] = set()
    errors: list[str] = []

    try:
        metadata = consumer.list_topics(topic=args.topic, timeout=10)
        topic_metadata = metadata.topics.get(args.topic)
        if topic_metadata is None or topic_metadata.error is not None:
            raise SystemExit(f"topic metadata unavailable for {args.topic}")

        partition_ids = sorted(topic_metadata.partitions)
        consumer.assign(
            [TopicPartition(args.topic, partition_id, OFFSET_BEGINNING) for partition_id in partition_ids]
        )
        per_partition_counts = {str(partition_id): 0 for partition_id in partition_ids}
        deadline = time.monotonic() + args.timeout_seconds

        while time.monotonic() < deadline and len(eof_partitions) < len(partition_ids):
            message = consumer.poll(1.0)
            if message is None:
                continue
            if message.error():
                if message.error().code() == KafkaError._PARTITION_EOF:
                    eof_partitions.add(message.partition())
                    continue
                errors.append(str(message.error()))
                continue

            partition_key = str(message.partition())
            if partition_key not in per_partition_counts:
                errors.append(f"unexpected partition {message.partition()}")
                continue
            per_partition_counts[partition_key] += 1

            key_bytes = message.key()
            if key_bytes is None:
                errors.append(f"record without key at partition {message.partition()} offset {message.offset()}")
                continue
            key = key_bytes.decode("utf-8")
            value_bytes = message.value()
            if value_bytes is None:
                latest_values.pop(key, None)
                normalized_latest_values.pop(key, None)
                deleted_keys.add(key)
                continue
            raw_value = value_bytes.decode("utf-8")
            latest_values[key] = raw_value
            normalized_match = NORMALIZED_VALUE_PATTERN.search(raw_value)
            normalized_latest_values[key] = normalized_match.group(1) if normalized_match else raw_value
            deleted_keys.discard(key)

        missing_eof = [partition_id for partition_id in partition_ids if partition_id not in eof_partitions]
        if missing_eof:
            errors.append(f"did not reach EOF for partitions {missing_eof}")
    finally:
        consumer.close()

    result = {
        "topic": args.topic,
        "partition_count": len(per_partition_counts),
        "eof_partitions": sorted(eof_partitions),
        "per_partition_counts": {
            key: per_partition_counts[key]
            for key in sorted(per_partition_counts, key=lambda item: int(item))
        },
        "total_messages": sum(per_partition_counts.values()),
        "latest_values": {key: latest_values[key] for key in sorted(latest_values)},
        "normalized_latest_values": {
            key: normalized_latest_values[key] for key in sorted(normalized_latest_values)
        },
        "deleted_keys": sorted(deleted_keys),
        "errors": errors,
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not errors else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    latest_values = subparsers.add_parser("latest-values")
    latest_values.add_argument("--bootstrap-server", required=True)
    latest_values.add_argument("--group-id", required=True)
    latest_values.add_argument("--topic", required=True)
    latest_values.add_argument("--timeout-seconds", default=45, type=int)
    latest_values.set_defaults(func=command_latest_values)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
