#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_csv_ints(value: str) -> list[int]:
    items = [item.strip() for item in value.split(",") if item.strip()]
    if not items:
        raise argparse.ArgumentTypeError("expected at least one integer")
    try:
        return [int(item) for item in items]
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer list: {value}") from exc


def build_payload(topic: str, partitions: list[int], replicas: list[int]) -> dict[str, object]:
    return {
        "version": 1,
        "partitions": [
            {
                "topic": topic,
                "partition": partition_id,
                "replicas": replicas,
            }
            for partition_id in partitions
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--topic", required=True)
    parser.add_argument("--partitions", required=True, type=parse_csv_ints)
    parser.add_argument("--replicas", required=True, type=parse_csv_ints)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    payload = build_payload(args.topic, args.partitions, args.replicas)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
