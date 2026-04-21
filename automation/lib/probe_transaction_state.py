#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import time


def padded_payload(prefix: str, payload_bytes: int) -> str:
    raw = prefix.encode("utf-8")
    if len(raw) > payload_bytes:
        raise ValueError(f"prefix is longer than payload budget: {prefix}")
    return (raw + (b"t" * (payload_bytes - len(raw)))).decode("utf-8")


def classify_marker(value: str) -> str:
    parts = value.split("|")
    if len(parts) > 1 and parts[1] in {"committed", "open", "probe"}:
        return parts[1]
    return "other"


def build_consumer(args: argparse.Namespace):
    try:
        from confluent_kafka import Consumer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "python package 'confluent-kafka' is required for transaction-state probes"
        ) from exc

    return Consumer(
        {
            "bootstrap.servers": args.bootstrap_server,
            "group.id": args.group_id,
            "enable.auto.commit": False,
            "auto.offset.reset": "earliest",
            "enable.partition.eof": True,
            "allow.auto.create.topics": False,
            "isolation.level": "read_committed",
        }
    )


def build_producer(args: argparse.Namespace):
    try:
        from confluent_kafka import Producer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "python package 'confluent-kafka' is required for transaction-state probes"
        ) from exc

    producer = Producer(
        {
            "bootstrap.servers": args.bootstrap_server,
            "transactional.id": args.transactional_id,
            "enable.idempotence": True,
        }
    )
    return producer


def command_read_committed(args: argparse.Namespace) -> int:
    from confluent_kafka import OFFSET_BEGINNING, KafkaError, TopicPartition

    consumer = build_consumer(args)
    per_partition_counts: dict[str, int] = {}
    marker_counts = {"committed": 0, "open": 0, "probe": 0, "other": 0}
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

            value_bytes = message.value()
            if value_bytes is None:
                marker_counts["other"] += 1
                continue
            marker_counts[classify_marker(value_bytes.decode("utf-8"))] += 1

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
        "marker_counts": marker_counts,
        "errors": errors,
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not errors else 1


def command_transactional_commit(args: argparse.Namespace) -> int:
    producer = build_producer(args)
    deliveries: dict[int, int] = {}
    errors: list[str] = []
    transaction_started = False

    def delivery_callback(err, message) -> None:
        if err is not None:
            errors.append(f"delivery failed for partition {message.partition()}: {err}")
            return
        deliveries[message.partition()] = message.offset()

    result = {
        "transactional_id": args.transactional_id,
        "probe_id": args.probe_id,
        "topic": args.topic,
        "init_transactions_status": "failed",
        "commit_transaction_status": "failed",
        "delivered_partitions": [],
        "delivery_offsets": {},
        "errors": errors,
    }

    try:
        producer.init_transactions()
        result["init_transactions_status"] = "ok"

        producer.begin_transaction()
        transaction_started = True

        for partition in range(args.partitions):
            prefix = f"{args.topic}|probe|{args.probe_id}|p{partition}|"
            producer.produce(
                args.topic,
                value=padded_payload(prefix, args.payload_bytes),
                partition=partition,
                on_delivery=delivery_callback,
            )

        outstanding = producer.flush(args.timeout_seconds)
        if outstanding:
            errors.append(f"producer flush timed out with {outstanding} outstanding messages")

        if not errors:
            producer.commit_transaction()
            result["commit_transaction_status"] = "ok"
            transaction_started = False
        else:
            producer.abort_transaction()
            transaction_started = False
    except Exception as exc:  # pragma: no cover - exercised via harness
        errors.append(str(exc))
        if transaction_started:
            try:
                producer.abort_transaction()
            except Exception as abort_exc:  # pragma: no cover - best effort cleanup
                errors.append(f"abort_transaction failed: {abort_exc}")

    result["delivered_partitions"] = sorted(deliveries)
    result["delivery_offsets"] = {
        str(partition): deliveries[partition] for partition in sorted(deliveries)
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if result["init_transactions_status"] == "ok" and result["commit_transaction_status"] == "ok" and not errors else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    read_committed = subparsers.add_parser("read-committed")
    read_committed.add_argument("--bootstrap-server", required=True)
    read_committed.add_argument("--group-id", required=True)
    read_committed.add_argument("--topic", required=True)
    read_committed.add_argument("--timeout-seconds", default=45, type=int)
    read_committed.set_defaults(func=command_read_committed)

    transactional_commit = subparsers.add_parser("transactional-commit")
    transactional_commit.add_argument("--bootstrap-server", required=True)
    transactional_commit.add_argument("--topic", required=True)
    transactional_commit.add_argument("--partitions", required=True, type=int)
    transactional_commit.add_argument("--payload-bytes", required=True, type=int)
    transactional_commit.add_argument("--transactional-id", required=True)
    transactional_commit.add_argument("--probe-id", required=True)
    transactional_commit.add_argument("--timeout-seconds", default=45, type=int)
    transactional_commit.set_defaults(func=command_transactional_commit)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
