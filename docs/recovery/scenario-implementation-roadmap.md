# Scenario Implementation Roadmap

## Purpose

Turn the scenario specs into an implementation sequence that stays grounded in real harness state, clear dependencies, and explicit verification gates.

This file is the current planning authority for:

- actual scenario status
- implementation order
- per-scenario spec work that must be done before coding
- cross-cutting harness gaps

## Current Reality

- The recovery harness is no longer spec-only.
- The snapshot rewrite tool now exists behind [`bin/snapshot-rewrite-tool`](../../bin/snapshot-rewrite-tool) with implementation under [`tooling/snapshot-rewrite/`](../../tooling/snapshot-rewrite/).
- Scenario 01 is now fully automated and has passed `prepare` + `rewrite` + `up` + `assert` + `report` from a fresh copied snapshot workdir.
- Two important runtime issues were already found and fixed:
  - source and recovery clusters must not share the same Docker network namespace
  - copied metadata snapshot directories must be cleaned more aggressively before installing rewritten state
- Additional rewrite/install fixes were required for the first clean pass:
  - rewritten metadata logs must ship Kafka `.index` and `.timeindex` sidecars
  - recovery metadata directories must receive `leader-epoch-checkpoint` and a rewritten `quorum-state`
  - recovered partition metadata must clear ELR state instead of filtering it to surviving brokers
- Scenario docs may still lag reality. Until they are refreshed one by one, use this roadmap as the authoritative planning view.

## Mandatory Spec Pass Before Each Scenario

Before starting implementation for any scenario, do a short scenario-specific spec pass first. That pass should update either the scenario file itself or a closely linked planning note and must resolve these questions:

1. What exact snapshot label or fixture profile is the scenario using?
2. What preconditions must already be green?
3. Which manifest fields or source-side expectation files are authoritative?
4. Which automation entrypoints need to be added or changed?
5. What exact assertions will be run, from which commands or artifacts?
6. What evidence must be saved into the report bundle?
7. What timing windows or nondeterministic fields need normalization?
8. How is cleanup handled so reruns start from a clean state?
9. If this is a negative or fault-injection scenario, what is the explicit injection mechanism and rollback path?

Only after those answers are written down should implementation start.

## Delivery Waves

### Wave 0: Planning Hygiene

- keep `HANDOFF.md`, this roadmap, and `AGENTS.md` aligned with reality
- treat Scenario 01 as the anchor scenario for the shared tool and harness
- require a spec pass before each implementation slice

### Wave 1: Core Recovery Correctness

Order:

1. Scenario 01
2. Scenario 02
3. Scenario 05
4. Scenario 08

Why this wave:

- it proves the cluster boots, metadata is sane, data is readable, configs survive, and the multi-disk assumption holds
- these scenarios validate the core correctness contract before higher-level client behavior

### Wave 2: Workload Semantics

Order:

1. Scenario 04
2. Scenario 06
3. Scenario 07

Why this wave:

- these scenarios depend on the recovered cluster already being trustworthy at the metadata and partition-data level
- they exercise higher-level Kafka state: consumer offsets, compaction, and transactions

### Wave 3: Safety And Post-Recovery Operations

Order:

1. Scenario 03
2. Scenario 10

Why this wave:

- Scenario 03 is deliberately fault-injected and easier to reason about after the happy path is stable
- Scenario 10 tests the intended RF=1 steady state and the first operational change after recovery

### Wave 4: Harness Productization

Order:

1. Scenario 11
2. Scenario 12

Why this wave:

- these scenarios are only meaningful once the individual correctness checks exist
- they convert the scenario suite into a repeatable, single-entrypoint system

### Wave 5: Deferred Extension

- Scenario 09 stays deferred until the clean-stop suite is green

## Cross-Cutting Harness Work

These are shared tasks that affect multiple scenarios and should be reused instead of reimplemented per scenario.

- report bundle normalization for offsets, configs, and logs
- helpers for topic describe, offset capture, and sampled consumption
- helpers for consumer-group describe and resume probes
- helpers for compacted-topic reconstruction from consumed records
- a transactional probe that runs without introducing new host dependencies
- deterministic reassignment payload generation for post-recovery expansion
- fault-injection hooks for negative-path scenarios

## Scenario Backlog

### Scenario 01: Quorum And Metadata Loading

Current status:

- implemented and validated from a fresh workdir
- latest clean report: `docs/recovery/reports/runs/2026-04-21-scenario-01-20260421T084355Z.md`
- no secondary anomalies were detected in the latest clean run

Spec before implementation:

- completed in the scenario file:
  - exact ready signal for "cluster booted successfully"
  - authoritative quorum and metadata checks
  - startup-failure denylist for explicit identity and voter mismatches
  - scope boundary between Scenario 01 topic availability and Scenario 02 data integrity
- follow-up candidates after implementation:
  - decide whether metadata-log decode should become a first-class artifact in addition to the rewrite report
  - keep the denylist narrow unless later scenarios surface a real false-negative gap

Likely implementation focus:

- reuse its quorum/topic/assert helpers in Scenario 02 and Scenario 05
- preserve the current green run as the baseline for later scenario comparisons

Done gate:

- achieved on 2026-04-21 by run `20260421T084355Z`

### Scenario 02: Partition Data Integrity

Current status:

- not automated yet
- depends on Scenario 01 assertion/report plumbing

Spec before implementation:

- lock the representative topics and partitions that must be checked
- define whether every partition or only a deterministic sample is consumed
- define clean-stop offset expectations as exact equality to the source manifest
- define how sampled reads are captured in artifacts

Likely implementation focus:

- offset comparison helper against the snapshot manifest
- deterministic sampled consumer helper
- report output for offset comparisons and read samples

Done gate:

- recovered offsets match the manifest for the agreed representative scope and sample reads succeed without corruption indicators

### Scenario 05: Topic And Broker Config Preservation

Current status:

- not automated yet
- likely low-risk once Scenario 01 metadata checks are reusable

Spec before implementation:

- pin the exact topic config keys and broker override keys that are in scope
- define how to normalize config output so defaults do not create false diffs
- define whether unknown dynamic configs should fail the scenario or just be reported

Likely implementation focus:

- source-vs-recovered config dump normalization
- broker config inspection helper
- exact comparison logic for dynamic topic and broker configs

Done gate:

- configured dynamic topic and broker overrides match the manifest exactly and no unintended overrides appear

### Scenario 08: Multiple Log Directories

Current status:

- partially covered by the base harness because the canonical layout already uses two `log.dirs`
- explicit assertions are still missing

Spec before implementation:

- define how to prove both recovered `log.dirs` are actually in use
- define which partitions or directories are the required evidence set
- define the acceptable `meta.properties` invariants across both disks
- define whether offset checks are borrowed directly from Scenario 02 or rerun independently

Likely implementation focus:

- log-dir inspection helper
- `meta.properties` comparison across recovered disk roots
- representative topic availability checks across both directories

Done gate:

- both recovered `log.dirs` contain valid partition state, `meta.properties` is consistent, and representative data remains readable

### Scenario 04: Consumer Offset Continuity

Current status:

- not automated yet
- depends on Scenario 02 and on stable manifest capture for committed offsets

Spec before implementation:

- pin the canonical group IDs and partition list used for the assertions
- define the acceptable drift window after recovery startup
- define what "resume near inherited offsets" means numerically
- define the wait or retry rule for `__consumer_offsets` stabilization

Likely implementation focus:

- consumer-group describe helper
- manifest comparison for committed offsets
- resumed-consumer probe using recovered group IDs

Done gate:

- recovered committed offsets are present and resumed consumers start from the inherited position within the declared tolerance

### Scenario 06: Compacted Topic Recovery

Current status:

- not automated yet
- depends on Scenario 02 data-read plumbing and source-side latest-value expectations

Spec before implementation:

- pin the compacted topics and key set that form the expected map
- define whether tombstones are part of the baseline fixture and, if so, how they are represented in the manifest
- define how long the harness may wait for cleaner activity before asserting
- define how to normalize consumed output into a final latest-value map

Likely implementation focus:

- helper to consume compacted topics and rebuild latest-per-key state
- comparison logic against the stored compacted-topic expectation files
- cleaner-log capture for failures

Done gate:

- recovered latest-per-key state matches the expected compacted-topic manifest and the topic remains configured for compaction

### Scenario 07: Transaction State Recovery

Current status:

- not automated yet
- depends on stable Scenario 02 behavior and a repeatable transactional probe

Spec before implementation:

- pin the committed and intentionally unresolved transaction cases that must exist in the source fixture
- define the timeout window and what resolved state is acceptable after recovery
- define the exact success criteria for the post-recovery transactional producer probe
- decide whether the probe runs via a helper container or Testcontainers-backed test code

Likely implementation focus:

- transactional probe helper with no new host dependency
- `read_committed` verification for the transaction topic
- transaction-state inspection and artifact capture

Done gate:

- `__transaction_state` is healthy, committed records are visible via `read_committed`, unresolved transactions converge as expected, and a new transactional producer can initialize and commit

### Scenario 03: Stray Detection Safety Net

Current status:

- not automated yet
- intentionally deferred until the happy path is already solid

Spec before implementation:

- define the exact metadata mutation used to force a partition into stray handling
- define the directory and log signatures that count as a successful negative-path trigger
- define the rollback steps precisely enough that data is not lost during the test
- define how the positive case reuses Scenario 01 checks rather than duplicating them

Likely implementation focus:

- explicit fault-injection helper or test hook
- directory listing capture before and after rename recovery
- cleanup logic that never reuses a mutated workdir accidentally

Done gate:

- the positive case stays clean, the negative case deterministically produces preserved `-stray` evidence, and the restored metadata path recovers cleanly

### Scenario 10: RF=1 Steady State And Replica Expansion

Current status:

- not automated yet
- should wait until the base recovery and data checks are stable

Spec before implementation:

- define which topic-partition set is the deterministic reassignment target
- define the acceptable stabilization period for startup and reassignment
- define the precise under-replication checks before, during, and after expansion
- define the artifact set that proves the expansion completed

Likely implementation focus:

- deterministic reassignment payload generator
- steady-state and post-expansion topic-describe assertions
- report capture around the reassignment operation

Done gate:

- the recovered cluster settles with `Replicas` length `1`, targeted expansion to `[0,1,2]` completes, and temporary under-replication resolves

### Scenario 11: End-To-End Automation Dry Run

Current status:

- not ready until the scenario-specific checks above exist

Spec before implementation:

- define the single entrypoint for the full flow
- define the required log layout and report-bundle layout
- define failure semantics and teardown behavior for partial runs
- define which scenario checks are considered "core correctness" for this dry run

Likely implementation focus:

- orchestrator script that chains prepare, rewrite, startup, assertions, reporting, and teardown
- fail-fast logging with readable artifact paths
- stable report-bundle structure under `docs/recovery/reports/runs/`

Done gate:

- one command runs the clean-stop flow from snapshot to report bundle without manual intervention

### Scenario 12: Repeatability

Current status:

- not ready until Scenario 11 or an equivalent automated flow exists

Spec before implementation:

- define the normalized comparison format between runs
- define the accepted nondeterministic fields explicitly
- define whether both runs must use the exact same snapshot label and tool image hash
- define how differences are surfaced in the report bundle

Likely implementation focus:

- report normalizer and diff helper
- rerun orchestration from the same immutable snapshot
- comparison artifact generation

Done gate:

- two runs from the same snapshot yield matching normalized results with only explicitly accepted nondeterminism

### Scenario 09: Live Snapshot Extension

Current status:

- deferred by design

Spec before implementation:

- define the live-copy window and source-side timing capture
- define the maximum acceptable offset loss relative to the copy window
- define whether the scenario uses host-side copy tooling, helper containers, or both
- define how recovery and truncation log evidence will be classified

Likely implementation focus:

- live-copy harness mechanics
- source-side write and timing capture
- offset-loss comparison logic

Done gate:

- a live-copied snapshot recovers within the agreed crash-consistency bounds and without fatal corruption
