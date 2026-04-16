#!/usr/bin/env python3

from __future__ import annotations

import argparse
import sys


def padded_payload(prefix: str, payload_bytes: int) -> str:
    raw = prefix.encode("utf-8")
    if len(raw) > payload_bytes:
        raise ValueError(f"prefix is longer than payload budget: {prefix}")
    return (raw + (b"x" * (payload_bytes - len(raw)))).decode("utf-8")


def command_fixed(args: argparse.Namespace) -> int:
    for index in range(args.count):
        prefix = f"{args.topic}|p{args.partition}|m{index:06d}|"
        sys.stdout.write(padded_payload(prefix, args.payload_bytes))
        sys.stdout.write("\n")
    return 0


def command_compacted(args: argparse.Namespace) -> int:
    for version in range(args.versions_per_key):
        version_label = f"v{version:02d}"
        for key_index in range(args.keys_per_partition):
            key = f"{args.key_prefix}-{args.partition}-{key_index:03d}"
            prefix = f"{args.topic}|p{args.partition}|{key}|{version_label}|"
            value = padded_payload(prefix, args.payload_bytes)
            sys.stdout.write(f"{key}\t{value}\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    fixed = subparsers.add_parser("fixed")
    fixed.add_argument("--topic", required=True)
    fixed.add_argument("--partition", required=True, type=int)
    fixed.add_argument("--count", required=True, type=int)
    fixed.add_argument("--payload-bytes", required=True, type=int)
    fixed.set_defaults(func=command_fixed)

    compacted = subparsers.add_parser("compacted")
    compacted.add_argument("--topic", required=True)
    compacted.add_argument("--partition", required=True, type=int)
    compacted.add_argument("--key-prefix", required=True)
    compacted.add_argument("--keys-per-partition", required=True, type=int)
    compacted.add_argument("--versions-per-key", required=True, type=int)
    compacted.add_argument("--payload-bytes", required=True, type=int)
    compacted.set_defaults(func=command_compacted)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
