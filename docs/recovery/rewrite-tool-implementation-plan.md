# Snapshot Rewrite Tool Implementation Draft

## Purpose

Turn the rewrite-tool spec into an implementation plan that is concrete enough to build in small, testable slices.

This file is intentionally about **implementation shape**, not requirements. The requirements remain in:

- [`rewrite-tool-spec.md`](./rewrite-tool-spec.md)
- [`final-recovery-plan.md`](../../final-recovery-plan.md)

## Working Assumptions

- the host should only need Docker plus basic shell tooling
- the runtime entrypoint should still be `bin/snapshot-rewrite-tool`
- the implementation should use Kafka's Java APIs rather than attempting binary checkpoint edits
- tests should not depend on manually launched external containers
- heavy integration tests should use Testcontainers

## Proposed Layout

```text
bin/
  snapshot-rewrite-tool                 # shell wrapper; docker run entrypoint

tooling/
  snapshot-rewrite/
    pom.xml
    src/main/java/...                   # rewrite CLI and implementation
    src/test/java/...                   # unit + fixture tests
    src/test/resources/...              # small synthetic fixtures only
  snapshot-rewrite.Dockerfile           # multi-stage build for the tool image
```

### Why This Layout

- `bin/` keeps the automation contract stable for [`automation/recovery/rewrite`](../../automation/recovery/rewrite).
- `tooling/snapshot-rewrite/` isolates Java build files from the rest of the repo.
- the Dockerfile keeps Java, Maven, and dependency resolution out of the host environment.

## Runtime Shape

### Tool Runtime

- implement the actual CLI in Java
- compile it in a Docker build stage
- run it through `bin/snapshot-rewrite-tool`

### Wrapper Responsibilities

`bin/snapshot-rewrite-tool` should:

1. locate repo root
2. ensure the rewrite-tool image exists
3. run the image with the repo mounted read-write
4. forward CLI arguments unchanged

The wrapper should not contain rewrite logic. It is only a stable shell entrypoint.

### Java Responsibilities

The Java CLI should:

1. parse the tool contract from [`rewrite-tool-spec.md`](./rewrite-tool-spec.md)
2. read the input checkpoint using Kafka metadata APIs
3. transform records in memory
4. write the rewritten checkpoint
5. emit the JSON report
6. fail fast on any unsupported or invalid state

## Internal Design

The implementation should be split into narrow components:

- `RewriteCli`
  Parses arguments and wires execution.

- `CheckpointReader`
  Reads the input checkpoint into an internal sequence of typed records plus snapshot metadata.

- `RewritePlanner`
  Holds parsed options such as surviving brokers, directory mode, and whether voter rewrite is requested.

- `RecordRewriter`
  Dispatches record-by-record transformations.

- `PartitionRecordRewriter`
  Applies the strict partition rewrite rules.

- `BrokerRecordFilter`
  Keeps or drops `RegisterBrokerRecord` entries.

- `VotersRecordRewriter`
  Enforces the `--rewrite-voters` safety rules.

- `RewriteReportBuilder`
  Produces the JSON report payload.

- `CheckpointWriter`
  Emits the rewritten checkpoint through Kafka's supported writer APIs.

The implementation should avoid mixing report-building, transformation, and file I/O in one class.

## Transformation Rules To Code First

These rules should be implemented and tested before wiring end-to-end file I/O:

### `PartitionRecord`

- compute `surviving = original replicas ∩ surviving brokers`
- fail if `surviving` is empty
- set `replicas = surviving`
- set `isr = surviving`
- preserve original leader if it survives
- otherwise set leader to the first surviving replica
- increment `leaderEpoch`
- increment `partitionEpoch`
- set every directory entry to `UNASSIGNED`

### `RegisterBrokerRecord`

- keep only records for surviving brokers

### `VotersRecord`

- if present without `--rewrite-voters`, fail
- if present with `--rewrite-voters`, rewrite to the surviving brokers
- if absent with `--rewrite-voters`, succeed with a warning

### All Other Records

- pass through unchanged in phase 1
- count them in the report

## Test Strategy

Use a layered test strategy. Do not jump straight to a 3-node boot test.

### Layer 1: Pure JVM Unit Tests

No Docker, no Testcontainers, no filesystem fixtures beyond small synthetic data.

Test cases:

- `PartitionRecord` preserves leader when the leader survives
- `PartitionRecord` reassigns leader when the original leader is gone
- `PartitionRecord` fails on zero surviving replicas
- `PartitionRecord` always rewrites directories to `UNASSIGNED`
- `RegisterBrokerRecord` filtering keeps only surviving brokers
- `VotersRecord` safety checks enforce `--rewrite-voters`
- report builder counts rewritten, preserved, reassigned, and missing partitions correctly

These should be the first tests written.

### Layer 2: Fixture-Based Integration Tests

Still no containers. These tests should use a real checkpoint fixture and the actual reader/writer path.

Primary fixture source:

- the checkpoint selected from `fixtures/snapshots/baseline-clean-v1/`

Test cases:

- read the real baseline checkpoint successfully
- rewrite it for surviving brokers `0,1,2`
- emit a valid report
- write a new checkpoint file with the same basename
- re-read the rewritten checkpoint successfully
- verify that only brokers `0,1,2` remain registered

This layer validates the actual checkpoint I/O without requiring a broker boot.

### Layer 3: Testcontainers Integration Tests

Use Testcontainers for the expensive checks that need real Kafka processes.

The goal here is not to replace every direct JVM test with containers. The goal is to isolate the few tests that genuinely benefit from a real broker boot.

Suggested approach:

1. copy snapshot data into a temporary test workdir
2. apply the same cleanup steps as `automation/recovery/prepare`
3. run the Java rewrite logic in-process
4. start a 3-node recovery cluster with Testcontainers using the Confluent image family already used by the harness
5. assert Scenario 01-style outcomes:
   - quorum forms
   - one leader exists
   - no startup mismatch on cluster id or voters
   - no stray-detection failures in logs

This keeps end-to-end Java tests self-contained without relying on manually launched Docker Compose services.

## Test Matrix

The first concrete matrix should be:

1. `PartitionRecordTransformTest`
   Covers leader preservation, reassignment, missing survivors, and `UNASSIGNED` directories.

2. `RegisterBrokerFilterTest`
   Covers broker filtering only.

3. `VotersRecordRewriteTest`
   Covers dynamic-quorum safety behavior.

4. `RewriteReportBuilderTest`
   Covers success and failure report shapes.

5. `CheckpointRoundTripTest`
   Reads and rewrites a real checkpoint fixture from `baseline-clean-v1`.

6. `Scenario01BootIT`
   Uses Testcontainers to boot the rewritten 3-node recovery cluster.

The first five should run quickly and on every normal test run. The Testcontainers test can be tagged or profiled separately if runtime becomes expensive.

## Initial Implementation Slices

### Slice 1

- add Java subproject and Docker build
- add `bin/snapshot-rewrite-tool` wrapper
- add CLI skeleton returning a placeholder report
- add unit-test harness

### Slice 2

- implement pure transformation code for `PartitionRecord`, `RegisterBrokerRecord`, and `VotersRecord`
- add Layer 1 unit tests

### Slice 3

- implement checkpoint reader/writer path
- add fixture-based round-trip tests against `baseline-clean-v1`

### Slice 4

- wire the real CLI report output
- make `automation/recovery/rewrite` succeed against `scenario-01`

### Slice 5

- add Testcontainers end-to-end boot test for Scenario 01 semantics

## Practical Notes For Testcontainers

- use the same image family as the harness to avoid version skew
- do not mutate repo fixtures in place; always copy into a temporary directory
- prefer per-test temporary workdirs over shared mutable state
- mount copied metadata and log directories into the containers
- capture broker logs as part of failed test output

Testcontainers should be used for broker-boot verification, not for every transformation test.

## Open Questions To Resolve During Slice 1

- exact Kafka library coordinates matching the Confluent image version
- whether to build a shaded jar or run with a plain classpath inside the tool image
- whether Testcontainers should manage three `GenericContainer`s directly or a Compose-based integration fixture

These are implementation decisions, not blockers for starting the code skeleton.
