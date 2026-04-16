#!/usr/bin/env python3

from __future__ import annotations

import argparse
import signal
import sys
import time
from pathlib import Path


def padded_payload(prefix: str, payload_bytes: int) -> str:
    raw = prefix.encode("utf-8")
    if len(raw) > payload_bytes:
        raise ValueError(f"prefix is longer than payload budget: {prefix}")
    return (raw + (b"t" * (payload_bytes - len(raw)))).decode("utf-8")


def build_producer(args: argparse.Namespace):
    try:
        from confluent_kafka import Producer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "python package 'confluent-kafka' is required for transactional fixture seeding"
        ) from exc
    producer = Producer(
        {
            "bootstrap.servers": args.bootstrap_server,
            "transactional.id": args.transactional_id,
            "enable.idempotence": True,
        }
    )
    producer.init_transactions()
    return producer


def delivery_callback(err, _msg):
    if err is not None:
        raise RuntimeError(f"delivery failed: {err}")


def command_committed(args: argparse.Namespace) -> int:
    producer = build_producer(args)
    for txn_index in range(args.transaction_count):
        producer.begin_transaction()
        for partition in range(args.partitions):
            prefix = f"{args.topic}|committed|txn{txn_index:03d}|p{partition}|"
            producer.produce(
                args.topic,
                value=padded_payload(prefix, args.payload_bytes),
                partition=partition,
                on_delivery=delivery_callback,
            )
        producer.flush()
        producer.commit_transaction()
    return 0


def command_open(args: argparse.Namespace) -> int:
    producer = build_producer(args)
    hold_file = Path(args.hold_file)
    ready_file = Path(args.ready_file)
    hold_file.parent.mkdir(parents=True, exist_ok=True)
    ready_file.parent.mkdir(parents=True, exist_ok=True)
    producer.begin_transaction()
    for partition in range(args.partitions):
        prefix = f"{args.topic}|open|p{partition}|"
        producer.produce(
            args.topic,
            value=padded_payload(prefix, args.payload_bytes),
            partition=partition,
            on_delivery=delivery_callback,
        )
    producer.flush()
    ready_file.write_text("ready\n", encoding="utf-8")

    stop = False

    def handle_signal(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    while hold_file.exists() and not stop:
        time.sleep(1)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    committed = subparsers.add_parser("committed")
    committed.add_argument("--bootstrap-server", required=True)
    committed.add_argument("--topic", required=True)
    committed.add_argument("--partitions", required=True, type=int)
    committed.add_argument("--payload-bytes", required=True, type=int)
    committed.add_argument("--transactional-id", required=True)
    committed.add_argument("--transaction-count", required=True, type=int)
    committed.set_defaults(func=command_committed)

    open_txn = subparsers.add_parser("open")
    open_txn.add_argument("--bootstrap-server", required=True)
    open_txn.add_argument("--topic", required=True)
    open_txn.add_argument("--partitions", required=True, type=int)
    open_txn.add_argument("--payload-bytes", required=True, type=int)
    open_txn.add_argument("--transactional-id", required=True)
    open_txn.add_argument("--hold-file", required=True)
    open_txn.add_argument("--ready-file", required=True)
    open_txn.set_defaults(func=command_open)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
