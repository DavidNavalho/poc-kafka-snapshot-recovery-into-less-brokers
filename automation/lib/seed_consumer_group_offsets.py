#!/usr/bin/env python3

from __future__ import annotations

import argparse
import time


def build_consumer(args: argparse.Namespace):
    try:
        from confluent_kafka import Consumer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "python package 'confluent-kafka' is required for consumer-group fixture seeding"
        ) from exc

    consumer = Consumer(
        {
            "bootstrap.servers": args.bootstrap_server,
            "group.id": args.group_id,
            "enable.auto.commit": False,
            "session.timeout.ms": 6000,
        }
    )
    return consumer


def command_commit(args: argparse.Namespace) -> int:
    from confluent_kafka import KafkaError, KafkaException, TopicPartition

    consumer = build_consumer(args)
    try:
        metadata = consumer.list_topics(topic=args.topic, timeout=10)
        topic_metadata = metadata.topics.get(args.topic)
        if topic_metadata is None or topic_metadata.error is not None:
            raise SystemExit(f"topic metadata unavailable for {args.topic}")

        offsets = [
            TopicPartition(args.topic, partition_id, args.offset)
            for partition_id in sorted(topic_metadata.partitions)
        ]
        retryable_codes = {
            KafkaError.NOT_COORDINATOR,
            KafkaError._WAIT_COORD,
            KafkaError.COORDINATOR_LOAD_IN_PROGRESS,
            KafkaError.REQUEST_TIMED_OUT,
            KafkaError.NETWORK_EXCEPTION,
        }
        for attempt in range(10):
            try:
                consumer.commit(offsets=offsets, asynchronous=False)
                break
            except KafkaException as exc:
                error = exc.args[0]
                if error.code() not in retryable_codes or attempt == 9:
                    raise
                consumer.poll(1.0)
                time.sleep(1)
    finally:
        consumer.close()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    commit = subparsers.add_parser("commit")
    commit.add_argument("--bootstrap-server", required=True)
    commit.add_argument("--group-id", required=True)
    commit.add_argument("--topic", required=True)
    commit.add_argument("--offset", required=True, type=int)
    commit.set_defaults(func=command_commit)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
