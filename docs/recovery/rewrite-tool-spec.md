# Snapshot Rewrite Tool Spec

## Purpose

Define the component that rewrites the KRaft metadata snapshot so a recovered 3-node cluster can start from copied source data.

## Normative References

- Deterministic checkpoint selection comes from [`harness-spec.md`](./harness-spec.md).
- Checkpoint selection and quorum-mode inspection come from Phase 2 in [`final-recovery-plan.md`](../../final-recovery-plan.md).
- The `UNASSIGNED` directory strategy comes from Section 4.3 in [`final-recovery-plan.md`](../../final-recovery-plan.md).
- The high-level transformation rules come from Phase 4 in [`final-recovery-plan.md`](../../final-recovery-plan.md).
- Scenario coverage and expected evidence are defined in [`scenarios/README.md`](./scenarios/README.md).

## Phase 1 Philosophy

- strict by default
- no silent empty-partition fallback
- fail fast on missing in-scope data
- emit a machine-readable report as well as a rewritten checkpoint

## Minimum CLI Contract

```text
snapshot-rewrite-tool \
  --input <source-checkpoint> \
  --output <rewritten-checkpoint> \
  --surviving-brokers <csv> \
  --directory-mode UNASSIGNED \
  [--rewrite-voters] \
  [--report <json-report-path>]
```

## Required Inputs

- one source `.checkpoint` file
- the set of surviving broker IDs, typically `0,1,2`
- directory mode `UNASSIGNED`
- optional dynamic-quorum voter rewrite flag

## Required Output

- one valid rewritten `.checkpoint`
- one report matching the schema defined below

## Rewrite Report Schema

The `--report` output must be JSON with this top-level shape:

```json
{
  "report_version": 1,
  "status": "success",
  "input_checkpoint": {
    "path": "<path>",
    "basename": "<20-digit-offset>-<10-digit-epoch>.checkpoint",
    "offset": 0,
    "epoch": 0,
    "sha256": "<sha256>"
  },
  "output_checkpoint": {
    "path": "<path>",
    "basename": "<20-digit-offset>-<10-digit-epoch>.checkpoint",
    "offset": 0,
    "epoch": 0,
    "sha256": "<sha256>"
  },
  "surviving_brokers": [0, 1, 2],
  "directory_mode": "UNASSIGNED",
  "quorum": {
    "voters_record_present": false,
    "rewrite_voters_requested": false,
    "voters_rewritten": false
  },
  "records_processed": {
    "total": 0,
    "by_type": {
      "PartitionRecord": 0,
      "RegisterBrokerRecord": 0,
      "TopicRecord": 0,
      "ConfigRecord": 0,
      "VotersRecord": 0
    }
  },
  "partitions": {
    "total": 0,
    "rewritten": 0,
    "leader_preserved": 0,
    "leader_reassigned": 0,
    "missing_survivors": 0
  },
  "missing_partitions": [],
  "warnings": [],
  "errors": []
}
```

Required status behavior:

- `status = "success"` only when the rewritten checkpoint was emitted successfully
- `status = "failure"` on any abort condition
- on failure, `output_checkpoint` may be `null`
- `missing_partitions` must be an array of objects shaped as:

```json
{
  "topic_name": "example-topic",
  "partition": 0,
  "original_replicas": [0, 3, 6],
  "surviving_replicas": []
}
```

## Dynamic Quorum Handling Contract

Dynamic quorum handling has two layers:

### Caller-Side Detection

The harness must inspect `quorum-state` during preparation, following [`final-recovery-plan.md`](../../final-recovery-plan.md):

- `data_version = 0` means static quorum
- `data_version = 1` means dynamic quorum and the caller must pass `--rewrite-voters`

The harness should also record this result in the snapshot manifest.

### Tool-Side Safety Check

The tool must inspect the input checkpoint for `VotersRecord` entries.

Rules:

- if `VotersRecord` is present and `--rewrite-voters` was **not** provided, fail
- if `VotersRecord` is present and `--rewrite-voters` **was** provided, rewrite it
- if `VotersRecord` is absent and `--rewrite-voters` **was** provided, succeed but record a warning and set `voters_rewritten = false`

If caller-side `quorum-state` inspection and checkpoint contents ever disagree, the harness must fail the scenario preparation step rather than silently picking one interpretation.

## Required Transformations

### `PartitionRecord`

- `replicas = original_replicas ∩ surviving_brokers`
- `isr = replicas`
- preserve original leader if it survives, otherwise choose the first surviving replica
- increment `leaderEpoch`
- increment `partitionEpoch`
- set all `directories` entries to `UNASSIGNED`

If a partition has zero surviving replicas:

- default behavior: fail the run
- include the topic-partition in the report
- do not write a "successful" output snapshot

### `RegisterBrokerRecord`

- keep only surviving brokers
- omit all others

### `VotersRecord`

- rewrite only when the input checkpoint contains `VotersRecord` and the caller provided `--rewrite-voters`

### All Other Records

- pass through unchanged unless a later implementation finds a broker-ID-carrying record that also needs rewriting

## Structural Validation

The tool is not done until the output can be validated by:

- `kafka-dump-log.sh --cluster-metadata-decoder`
- recovery-cluster startup in Scenario 01

## Scenario Coverage

The tool is primarily validated by:

- Scenario 01: quorum and metadata loading
- Scenario 03: stray detection safety net
- Scenario 05: config preservation
- Scenario 10: RF=1 steady state and replica expansion

## Non-Goals For Phase 1

- an "empty partition" recovery mode
- support for mixed-version clusters
- in-place checkpoint editing
