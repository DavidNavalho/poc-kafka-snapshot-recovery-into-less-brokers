#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import time


def build_consumer(args: argparse.Namespace):
    try:
        from confluent_kafka import Consumer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "python package 'confluent-kafka' is required for consumer-group resume probes"
        ) from exc

    consumer = Consumer(
        {
            "bootstrap.servers": args.bootstrap_server,
            "group.id": args.group_id,
            "enable.auto.commit": False,
            "auto.offset.reset": "error",
            "session.timeout.ms": 10000,
            "allow.auto.create.topics": False,
        }
    )
    return consumer


def command_resume(args: argparse.Namespace) -> int:
    from confluent_kafka import KafkaError

    consumer = build_consumer(args)
    assignment_partitions: set[int] = set()
    first_seen_offsets: dict[str, int] = {}
    errors: list[str] = []

    def on_assign(_consumer, partitions) -> None:
        assignment_partitions.update(partition.partition for partition in partitions)

    consumer.subscribe([args.topic], on_assign=on_assign)
    deadline = time.monotonic() + args.timeout_seconds

    try:
        while time.monotonic() < deadline and len(first_seen_offsets) < args.partition_count:
            current_assignment = consumer.assignment()
            if current_assignment:
                assignment_partitions.update(
                    partition.partition for partition in current_assignment
                )

            message = consumer.poll(1.0)
            if message is None:
                continue
            if message.error():
                if message.error().code() == KafkaError._PARTITION_EOF:
                    continue
                errors.append(str(message.error()))
                continue
            if message.topic() != args.topic:
                errors.append(f"unexpected topic {message.topic()}")
                continue
            partition_id = message.partition()
            if partition_id < 0 or partition_id >= args.partition_count:
                errors.append(f"unexpected partition {partition_id}")
                continue
            first_seen_offsets.setdefault(str(partition_id), message.offset())
    finally:
        consumer.close()

    missing_partitions = [
        partition_id
        for partition_id in range(args.partition_count)
        if str(partition_id) not in first_seen_offsets
    ]

    result = {
        "group_id": args.group_id,
        "topic": args.topic,
        "partition_count": args.partition_count,
        "assigned_partitions": sorted(assignment_partitions),
        "first_seen_offsets": {
            key: first_seen_offsets[key]
            for key in sorted(first_seen_offsets, key=lambda item: int(item))
        },
        "missing_partitions": missing_partitions,
        "errors": errors,
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not missing_partitions and not errors else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    resume = subparsers.add_parser("resume")
    resume.add_argument("--bootstrap-server", required=True)
    resume.add_argument("--group-id", required=True)
    resume.add_argument("--topic", required=True)
    resume.add_argument("--partition-count", required=True, type=int)
    resume.add_argument("--timeout-seconds", default=45, type=int)
    resume.set_defaults(func=command_resume)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
