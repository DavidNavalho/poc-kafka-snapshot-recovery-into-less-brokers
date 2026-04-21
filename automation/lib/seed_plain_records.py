#!/usr/bin/env python3

from __future__ import annotations

import argparse


def padded_payload(prefix: str, payload_bytes: int) -> str:
    raw = prefix.encode("utf-8")
    if len(raw) > payload_bytes:
        raise ValueError(f"prefix is longer than payload budget: {prefix}")
    return (raw + (b"x" * (payload_bytes - len(raw)))).decode("utf-8")


def build_producer(args: argparse.Namespace):
    try:
        from confluent_kafka import Producer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "python package 'confluent-kafka' is required for source fixture record seeding"
        ) from exc

    return Producer(
        {
            "bootstrap.servers": args.bootstrap_server,
            "acks": "all",
        }
    )


def delivery_callback(err, _msg):
    if err is not None:
        raise RuntimeError(f"delivery failed: {err}")


def produce_fixed(args: argparse.Namespace) -> int:
    producer = build_producer(args)
    for index in range(args.count):
        prefix = f"{args.topic}|p{args.partition}|m{index:06d}|"
        producer.produce(
            args.topic,
            value=padded_payload(prefix, args.payload_bytes),
            partition=args.partition,
            on_delivery=delivery_callback,
        )
        producer.poll(0)
    producer.flush()
    return 0


def produce_compacted(args: argparse.Namespace) -> int:
    producer = build_producer(args)
    for version in range(args.versions_per_key):
        version_label = f"v{version:02d}"
        for key_index in range(args.keys_per_partition):
            key = f"{args.key_prefix}-{args.partition}-{key_index:03d}"
            prefix = f"{args.topic}|p{args.partition}|{key}|{version_label}|"
            producer.produce(
                args.topic,
                key=key,
                value=padded_payload(prefix, args.payload_bytes),
                partition=args.partition,
                on_delivery=delivery_callback,
            )
            producer.poll(0)
    producer.flush()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    fixed = subparsers.add_parser("fixed")
    fixed.add_argument("--bootstrap-server", required=True)
    fixed.add_argument("--topic", required=True)
    fixed.add_argument("--partition", required=True, type=int)
    fixed.add_argument("--count", required=True, type=int)
    fixed.add_argument("--payload-bytes", required=True, type=int)
    fixed.set_defaults(func=produce_fixed)

    compacted = subparsers.add_parser("compacted")
    compacted.add_argument("--bootstrap-server", required=True)
    compacted.add_argument("--topic", required=True)
    compacted.add_argument("--partition", required=True, type=int)
    compacted.add_argument("--key-prefix", required=True)
    compacted.add_argument("--keys-per-partition", required=True, type=int)
    compacted.add_argument("--versions-per-key", required=True, type=int)
    compacted.add_argument("--payload-bytes", required=True, type=int)
    compacted.set_defaults(func=produce_compacted)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
