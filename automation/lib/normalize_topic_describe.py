#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_replica_field(value: str) -> list[int]:
    value = value.strip()
    if not value:
        return []
    return [int(item.strip()) for item in value.split(",") if item.strip()]


def parse_line(raw_line: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for part in raw_line.strip().split("\t"):
        if ":" not in part:
            continue
        key, value = part.split(":", 1)
        fields[key.strip()] = value.strip()
    return fields


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--topic", required=True)
    parser.add_argument("--partitions")
    parser.add_argument("--output")
    args = parser.parse_args()

    requested_partitions = None
    if args.partitions:
        requested_partitions = {item.strip() for item in args.partitions.split(",") if item.strip()}

    result: dict[str, dict[str, object]] = {}
    for raw_line in Path(args.input).read_text(encoding="utf-8").splitlines():
        fields = parse_line(raw_line)
        if fields.get("Topic") != args.topic or "Partition" not in fields:
            continue
        partition_id = fields["Partition"]
        if requested_partitions is not None and partition_id not in requested_partitions:
            continue
        result[partition_id] = {
            "leader": int(fields["Leader"]),
            "replicas": parse_replica_field(fields.get("Replicas", "")),
            "isr": parse_replica_field(fields.get("Isr", "")),
        }

    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(payload, encoding="utf-8")
    else:
        print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
