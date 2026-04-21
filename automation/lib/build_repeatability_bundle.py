#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_scalar_list(values: list[Any]) -> list[Any]:
    if all(isinstance(item, (int, float, str, bool)) for item in values):
        return sorted(values)
    return values


def normalize_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: normalize_value(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        normalized = [normalize_value(item) for item in value]
        return normalize_scalar_list(normalized)
    return value


def parse_offsets_file(path: Path) -> dict[str, int]:
    offsets: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        _topic, partition_id, offset = line.split(":", 2)
        offsets[partition_id] = int(offset)
    return offsets


def parse_partition_count_from_describe(path: Path) -> int:
    header = path.read_text(encoding="utf-8").splitlines()[0]
    match = re.search(r"PartitionCount:\s*([0-9]+)", header)
    if match is None:
        raise ValueError(f"PartitionCount not found in {path}")
    return int(match.group(1))


def read_lines(path: Path) -> list[str]:
    return sorted([line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()])


def process_scenario_01(workdir: Path) -> dict[str, Any]:
    topic_dir = workdir / "artifacts" / "assert" / "topics"
    return {
        "topics": {
            path.name.removesuffix(".describe.txt"): parse_partition_count_from_describe(path)
            for path in sorted(topic_dir.glob("*.describe.txt"))
        }
    }


def process_scenario_02(workdir: Path) -> dict[str, Any]:
    offset_dir = workdir / "artifacts" / "assert" / "offsets"
    sample_dir = workdir / "artifacts" / "assert" / "samples"
    return {
        "offsets": {
            path.name.removesuffix(".offsets.txt"): parse_offsets_file(path)
            for path in sorted(offset_dir.glob("*.offsets.txt"))
        },
        "sample_counts": {
            path.name.removesuffix(".count.txt"): int(path.read_text(encoding="utf-8").strip())
            for path in sorted(sample_dir.glob("*.count.txt"))
        },
    }


def process_scenario_04(workdir: Path) -> dict[str, Any]:
    group_dir = workdir / "artifacts" / "assert" / "groups"
    probe_dir = workdir / "artifacts" / "assert" / "probes"
    committed = {
        path.name.removesuffix(".committed.json"): load_json(path)
        for path in sorted(group_dir.glob("*.committed.json"))
    }
    resumed = {
        path.name.removesuffix(".resume.json"): load_json(path).get("first_seen_offsets", {})
        for path in sorted(probe_dir.glob("*.resume.json"))
    }
    return {"committed_offsets": committed, "resumed_offsets": resumed}


def process_scenario_05(workdir: Path) -> dict[str, Any]:
    topic_dir = workdir / "artifacts" / "assert" / "topics"
    broker_dir = workdir / "artifacts" / "assert" / "brokers"
    return {
        "topic_configs": {
            path.name.removesuffix(".normalized.json"): load_json(path)
            for path in sorted(topic_dir.glob("*.normalized.json"))
        },
        "broker_configs": {
            path.name.removesuffix(".normalized.json"): load_json(path)
            for path in sorted(broker_dir.glob("*.normalized.json"))
        },
    }


def process_scenario_06(workdir: Path) -> dict[str, Any]:
    compacted_dir = workdir / "artifacts" / "assert" / "compacted"
    config_dir = workdir / "artifacts" / "assert" / "configs"
    return {
        "compacted_latest_values": {
            path.name.removesuffix(".actual.json"): load_json(path)
            for path in sorted(compacted_dir.glob("*.actual.json"))
        },
        "topic_configs": {
            path.name.removesuffix(".normalized.json"): load_json(path)
            for path in sorted(config_dir.glob("*.normalized.json"))
        },
    }


def process_scenario_07(workdir: Path) -> dict[str, Any]:
    probe_dir = workdir / "artifacts" / "assert" / "probes"
    transactional_probe = load_json(probe_dir / "transactional-probe.json")
    transactional_probe.pop("probe_id", None)
    transactional_probe.pop("transactional_id", None)
    return {
        "read_committed_before": load_json(probe_dir / "recovery.txn.test.read-committed.before.json"),
        "read_committed_after": load_json(probe_dir / "recovery.txn.test.read-committed.after.json"),
        "transactional_probe": normalize_value(transactional_probe),
    }


def process_scenario_08(workdir: Path) -> dict[str, Any]:
    logdir_dir = workdir / "artifacts" / "assert" / "logdirs"
    meta_dir = workdir / "artifacts" / "assert" / "meta"
    return {
        "logdirs": {
            path.name: read_lines(path)
            for path in sorted(logdir_dir.glob("*.recovered-partitions.txt"))
        },
        "meta_properties": {
            path.name: read_lines(path)
            for path in sorted(meta_dir.glob("*.recovered.normalized.properties"))
        },
    }


def process_scenario_10(workdir: Path) -> dict[str, Any]:
    topic_dir = workdir / "artifacts" / "assert" / "topics"
    sample_dir = workdir / "artifacts" / "assert" / "samples"
    pre_state = load_json(topic_dir / "recovery.default.6p.pre.normalized.json")
    post_state = load_json(topic_dir / "recovery.default.6p.post.normalized.json")
    return {
        "pre_state": normalize_value(pre_state),
        "post_state": normalize_value(post_state),
        "sample_counts": {
            path.name.removesuffix(".count.txt"): int(path.read_text(encoding="utf-8").strip())
            for path in sorted(sample_dir.glob("*.count.txt"))
        },
    }


PROCESSORS = {
    "scenario-01": process_scenario_01,
    "scenario-02": process_scenario_02,
    "scenario-04": process_scenario_04,
    "scenario-05": process_scenario_05,
    "scenario-06": process_scenario_06,
    "scenario-07": process_scenario_07,
    "scenario-08": process_scenario_08,
    "scenario-10": process_scenario_10,
}


def build_bundle(manifest_path: Path) -> dict[str, Any]:
    suite_manifest = load_json(manifest_path)
    bundle: dict[str, Any] = {
        "snapshot_label": suite_manifest["snapshot_label"],
        "requested_core_scenarios": suite_manifest.get("requested_core_scenarios", []),
        "scenarios": {},
    }

    for scenario in suite_manifest.get("core_scenarios", []):
        scenario_id = scenario["scenario_id"]
        workdir = Path(scenario["workdir"])
        payload: dict[str, Any] = {
            "summary_status": load_json(Path(scenario["summary_path"])).get("status", "missing")
        }
        processor = PROCESSORS.get(scenario_id)
        if processor is not None:
            payload["data"] = processor(workdir)
        bundle["scenarios"][scenario_id] = normalize_value(payload)

    return normalize_value(bundle)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite-manifest", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    bundle = build_bundle(Path(args.suite_manifest))
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
