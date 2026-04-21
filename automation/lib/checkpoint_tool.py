#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


CHECKPOINT_RE = re.compile(r"^(?P<offset>\d+)-(?P<epoch>\d+)\.checkpoint$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_candidate(path: Path) -> dict:
    match = CHECKPOINT_RE.match(path.name)
    if not match:
        raise ValueError(f"unparsable checkpoint basename: {path.name}")
    return {
        "path": str(path.resolve()),
        "basename": path.name,
        "offset": int(match.group("offset")),
        "epoch": int(match.group("epoch")),
        "sha256": sha256(path),
    }


def command_select(args: argparse.Namespace) -> int:
    root = Path(args.search_root)
    if not root.exists():
        raise SystemExit(f"search root does not exist: {root}")
    checkpoints = sorted(
        path
        for path in root.rglob("*.checkpoint")
        if path.parent.name == "__cluster_metadata-0" and CHECKPOINT_RE.match(path.name)
    )
    if not checkpoints:
        raise SystemExit(f"no checkpoint files found under {root}")
    candidates = [parse_candidate(path) for path in checkpoints]
    selected = sorted(
        candidates,
        key=lambda candidate: (
            -candidate["offset"],
            -candidate["epoch"],
            candidate["path"],
        ),
    )[0]
    sys.stdout.write(json.dumps(selected, indent=2, sort_keys=True))
    sys.stdout.write("\n")
    return 0


def command_quorum_state(args: argparse.Namespace) -> int:
    path = Path(args.path)
    if not path.exists():
        raise SystemExit(f"quorum-state file does not exist: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    data_version = int(data["data_version"])
    payload = {
        "path": str(path.resolve()),
        "data_version": data_version,
        "dynamic_quorum": data_version == 1,
    }
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True))
    sys.stdout.write("\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    select = subparsers.add_parser("select")
    select.add_argument("--search-root", required=True)
    select.set_defaults(func=command_select)

    quorum_state = subparsers.add_parser("quorum-state")
    quorum_state.add_argument("--path", required=True)
    quorum_state.set_defaults(func=command_quorum_state)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
