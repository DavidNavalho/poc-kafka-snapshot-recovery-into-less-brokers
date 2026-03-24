# Kafka Internals Research Findings
## 9-Node → N-Node Snapshot Recovery: Technical Deep-Dive

> **Purpose**: This document captures source-verified findings from reading the Apache Kafka
> trunk source code (cloned into `./kafka/`). It supersedes or corrects assumptions in
> `snapshot-to-3node-adr.md` where they conflict with reality. It is the technical foundation
> for deciding how to automate the recovery.
>
> **Key constraint**: Snapshots are potentially hundreds of GBs to TBs per node.
> No per-partition analysis, selective copying, or topic recreation via CLI tools is feasible.
> We must work by **mass-copying full disk images** and making surgical edits to a small number
> of tiny files.
>
> **Source references**: All claims are verified against the Apache Kafka trunk branch.
> Source file paths are relative to `./kafka/` in this repository.

---

## Table of Contents

1. [The Two-Layer Architecture](#1-the-two-layer-architecture)
2. [The Stray Detection Problem — The Central Risk](#2-the-stray-detection-problem--the-central-risk)
3. [File-by-File Reference: What Is Checked, How It Fails, What Is Safe](#3-file-by-file-reference)
4. [The KRaft Metadata Snapshot: Binary Format and Contents](#4-the-kraft-metadata-snapshot-binary-format-and-contents)
5. [What kafka-storage format Actually Does](#5-what-kafka-storage-format-actually-does)
6. [The quorum-state File](#6-the-quorum-state-file)
7. [KRaft Quorum Modes: Static vs Dynamic](#7-kraft-quorum-modes-static-vs-dynamic)
8. [Replica Placement: Why the Original ADR's Assumptions Are Wrong](#8-replica-placement-why-the-original-adrs-assumptions-are-wrong)
9. [The Offline Partition Problem: Cluster Size vs Data Recovery](#9-the-offline-partition-problem-cluster-size-vs-data-recovery)
10. [What a Snapshot Rewrite Tool Must Do](#10-what-a-snapshot-rewrite-tool-must-do)
11. [Strategy Analysis for TB-Scale Recovery](#11-strategy-analysis-for-tb-scale-recovery)
12. [Recommended Recovery Process](#12-recommended-recovery-process)
13. [Decision Points Requiring Input](#13-decision-points-requiring-input)
14. [Appendix: Source File Index and Error Message Reference](#14-appendix)

---

## 1. The Two-Layer Architecture

Kafka on KRaft stores cluster state in two entirely separate layers. The ADR identifies these
correctly but understates how tightly coupled they are:

```
LAYER 1: KRaft Metadata (the "brain")
  Location: <metadata.log.dir>/__cluster_metadata-0/

  Key files:
    <offset>-<epoch>.checkpoint   Binary snapshot of entire cluster state
    <offset>.log                  Incremental records after the latest snapshot
    quorum-state                  JSON: Raft election state (leader, voter set)

  Ground truth for:
    - Which broker IDs exist in the cluster
    - Which broker IDs host which partition replica  ← critical
    - Which directory UUID on each broker holds each replica  ← critical
    - ISR membership, leader, partition epochs, topic UUIDs
    - Feature versions, SCRAM credentials, ACLs

LAYER 2: Partition Data (the "body")
  Location: <log.dirs>/<topic>-<partition>/

  Key files (per partition directory):
    *.log, *.index, *.timeindex   Actual message data — NO broker ID embedded, fully portable
    partition.metadata             Contains the TOPIC UUID (not broker ID)
    leader-epoch-checkpoint        Epoch history — no broker ID
    *.snapshot                     Producer state — no broker ID

  Key files (at log.dirs root):
    meta.properties                node.id, cluster.id, directory.id
    recovery-point-offset-checkpoint
    replication-offset-checkpoint   (high watermarks)
    log-start-offset-checkpoint
```

**The critical coupling**: When a broker starts, it cross-references every partition directory
it finds against the KRaft metadata. If the metadata does not list this broker as a replica
for that partition, the directory is silently renamed to `-stray` and asynchronously
**deleted**. This is the most important constraint for the entire recovery process.

---

## 2. The Stray Detection Problem — The Central Risk

### Source code

`storage/src/main/java/org/apache/kafka/storage/internals/log/LogManager.java:63`

```java
public static boolean isStrayReplica(List<Integer> replicas, int brokerId, UnifiedLog log) {
    if (replicas.isEmpty()) {
        // Topic doesn't exist in metadata at all → STRAY → deleted
        return true;
    }
    if (!replicas.contains(brokerId)) {
        // This broker's ID is not in the Replicas[] array → STRAY → deleted
        return true;
    }
    return false;
}
```

Called from `core/src/main/scala/kafka/server/metadata/BrokerMetadataPublisher.scala:316`
during `logManager.startup()`:

```scala
isStray = log => {
    if (log.topicId().isEmpty) {
        // No partition.metadata file → STRAY (treated as orphan from failed creation)
        true
    } else {
        val replicas = newImage.topics.partitionReplicas(log.topicId.get, log.topicPartition.partition)
        JLogManager.isStrayReplica(replicas, brokerId, log)
    }
}
```

The lookup uses the **topic UUID** from `partition.metadata` to find the partition in the
KRaft metadata image, then checks whether this broker's `node.id` appears in `Replicas[]`.

### What "stray" means operationally

When `isStray` returns true for a partition directory:

1. `log.renameDir(UnifiedLog.logStrayDirName(...), false)` — directory renamed to
   `<topic>-<partition>-stray` immediately
2. Added to `strayLogs` internal map
3. Asynchronously **deleted** after `file.delete.delay.ms` (default: 60,000 ms)

**Consequence**: If we mass-copy all 9 snapshot volumes onto 3 new brokers with new broker
IDs (e.g., 0, 1, 2), but the KRaft metadata still references the original broker IDs (e.g.,
1–9), then every single partition directory will be renamed to `-stray` and deleted within
60 seconds of startup. All TBs of data, gone.

### The two paths past stray detection

**Path A — Keep original broker IDs**: Run each new node with the same `node.id` as the
original broker whose snapshot was restored. The metadata still says `Replicas=[3, 7, 1]`,
and our nodes run as broker 3, broker 7, and broker 1. `replicas.contains(brokerId)` returns
true — no stray detection fires.

**Path B — Rewrite the snapshot**: Before starting any broker, modify the KRaft metadata
snapshot so that `PartitionRecord.Replicas[]` references the new broker IDs. Then the metadata
agrees with the broker IDs actually running.

Everything else in this document follows from choosing between these two paths.

---

## 3. File-by-File Reference

### 3.1 `partition.metadata`

**Location**: `<log.dir>/<topic>-<partition>/partition.metadata`

**Format** (plain UTF-8 text, written atomically via `.tmp` file):
```
version: 0
topic_id: <UUID-base64url>
```

**What is checked on startup**:

Called from `UnifiedLog.initializeTopicId()` during log loading. The UUID in this file is
compared against what the KRaft controller says the topic's UUID is:

- UUIDs **match**: partition loads normally.
- UUIDs **mismatch**: `InconsistentTopicIdException` is thrown. This causes the entire
  `log.dir` containing this file to go **offline** — not just the one partition, the whole
  disk. Source: `PartitionMetadataFile.java`, error propagated through `logDirFailureChannel`.
- File is **absent**: Kafka accepts the partition and recreates the file with the current UUID
  from the controller. Absence is safe.

**For our recovery**:

- **Strategy 1 (keep original snapshot verbatim)**: Topic UUIDs in `partition.metadata` match
  the original snapshot's `TopicRecord` entries. **Keep files as-is.**
- **Strategy 2 (rewrite snapshot)**: We rewrite `PartitionRecord` entries but pass `TopicRecord`
  entries through unchanged. Topic UUIDs are preserved. **Still keep files as-is.**
- Only delete `partition.metadata` if recreating topics from scratch — which we are not doing.

### 3.2 `meta.properties`

**Location**: `<log.dir>/meta.properties` (one per log directory root)

**Format** (Java Properties file):
```properties
version=1
node.id=7
cluster.id=MkQkDy5fTnShlSYvMZcXAA
directory.id=J8aAPcfLQt2bqs1JT_rMgQ
```

**What is validated on startup**
(`MetaPropertiesEnsemble.verify()` at
`metadata/src/main/java/org/apache/kafka/metadata/properties/MetaPropertiesEnsemble.java:472`):

1. All log directories on the same broker must agree on `node.id`. Any mismatch:
   `"Stored node id X doesn't match previous node id Y"` → broker refuses to start.
2. All log directories must agree on `cluster.id`. Any mismatch: `"Invalid cluster.id"` → crash.
3. `directory.id` must not be a reserved UUID (MSB=0 — i.e., `MIGRATING`, `UNASSIGNED`, `LOST`).
4. `directory.id` must be unique across all directories on the same broker.
5. If `metadata.log.dir` has an I/O error, startup aborts immediately.

**For our recovery (Path A — keep original broker IDs)**:

The snapshot `meta.properties` already contains the correct `node.id`, `cluster.id`, and
`directory.id`. As long as each new node runs with `node.id` matching the original broker
and all `log.dirs` came from the same original broker's snapshot, `meta.properties` requires
no changes.

**If remapping broker IDs (Path B)**: rewrite `node.id` in all `meta.properties` on that
node. The `directory.id` should either be kept from the original (if the rewritten snapshot
preserves original directory UUIDs) or replaced — but simplest is to use `UNASSIGNED` in the
rewritten `PartitionRecord.Directories[]`, which eliminates the need to track directory UUIDs
at all (see Section 4.4).

### 3.3 Checkpoint files at `log.dir` root

All three use the same format:
```
0                    ← version (must be 0)
<N>                  ← count of entries
<topic> <partition> <offset>
...
```

| File | Contents | Failure mode |
|---|---|---|
| `replication-offset-checkpoint` | High watermark per partition | Parse failure → **non-fatal**, resets to 0 |
| `recovery-point-offset-checkpoint` | Recovery point per partition | Parse failure → **non-fatal**, resets to 0 |
| `log-start-offset-checkpoint` | Log start offset per partition | Parse failure → **non-fatal**, resets to 0 |

All three are non-fatal on failure — they reset to 0. The only consequence is slower startup
(forces full segment recovery) and temporarily stale HWMs until ISR re-establishes.

**For our recovery**: Leave all three as-is from the original snapshot. They contain correct
topic/partition names and reasonable offset values. Leaving them avoids unnecessary full-segment
recovery across TBs of data.

### 3.4 `leader-epoch-checkpoint` (inside each partition directory)

**Format**:
```
0            ← version
<N>          ← count of entries
<epoch> <startOffset>
```

**What happens on startup**: Stale entries (pointing beyond current LEO) are silently trimmed —
non-fatal. If file is completely unreadable: entire log directory goes offline (fatal). If
absent: Kafka creates an empty one safely.

**For our recovery**: Leave as-is. Kafka trims stale entries automatically.

### 3.5 Producer state snapshot files (`*.snapshot`)

Binary format with CRC32C checksum. If CRC fails, Kafka discards that snapshot and tries the
next older one. If no valid snapshot exists, Kafka rebuilds producer state by replaying all
log segments. Non-fatal.

**For our recovery**: Leave as-is.

### 3.6 Log data files (`*.log`, `*.index`, `*.timeindex`)

No broker ID embedded anywhere. Fully portable. If log tail is corrupt (partial write from
a live snapshot): `LogLoader.recover()` detects and truncates at the corrupt point — expected
and handled automatically.

**For our recovery**: Leave as-is. Copy verbatim.

### 3.7 `.kafka_cleanshutdown`

Marker file in `log.dir` root. Its absence means unclean shutdown — Kafka will run full
recovery on segments at or above `recoveryPointCheckpoint`. Slower, but safe.

Our snapshots are of a running cluster, so this file will be absent. Do not create it
artificially — doing so skips recovery and risks treating corrupt tails as valid data.

### 3.8 `quorum-state` (inside `__cluster_metadata-0/`)

See Section 6. Must be deleted or replaced.

### 3.9 `__cluster_metadata-0/*.log` (metadata log segments)

These are incremental metadata records written after the last snapshot. They may contain
`PartitionChangeRecord`, `FenceBrokerRecord`, or `UnfenceBrokerRecord` entries that reference
all 9 original broker IDs and are inconsistent with a reduced cluster.

**For our recovery**: Delete all `.log` segments in `__cluster_metadata-0/`. Keep only the
latest `.checkpoint` snapshot. The snapshot is the complete authoritative state; the log
segments are only needed if more recent than the snapshot, which is not something we can
safely replay without all 9 brokers.

### Summary Risk Table

| File | Location | Fatal if wrong? | Action |
|---|---|---|---|
| `partition.metadata` | `<log.dir>/<topic>-<N>/` | **Yes** — entire disk offline | Keep as-is (UUID matches original snapshot) |
| `meta.properties` | `<log.dir>/` | **Yes** — broker refuses to start | Keep as-is if keeping original broker IDs; rewrite `node.id` only if changing IDs |
| `quorum-state` | `__cluster_metadata-0/` | **Yes** — quorum deadlocks with 9-node voter set | **Delete** |
| `__cluster_metadata-0/*.log` | metadata dir | Potentially (stale records) | **Delete all** |
| `__cluster_metadata-0/*.checkpoint` | metadata dir | **Yes** — wrong replica assignments if bad | Use best available; optionally rewrite |
| `replication-offset-checkpoint` | `<log.dir>/` | No | Leave as-is |
| `recovery-point-offset-checkpoint` | `<log.dir>/` | No | Leave as-is |
| `log-start-offset-checkpoint` | `<log.dir>/` | No | Leave as-is |
| `leader-epoch-checkpoint` | `<log.dir>/<topic>-<N>/` | No — auto-trimmed | Leave as-is |
| `*.snapshot` (producer state) | `<log.dir>/<topic>-<N>/` | No — rebuilt from log | Leave as-is |
| `*.log` / `*.index` (partition data) | `<log.dir>/<topic>-<N>/` | No — tail truncated | Leave as-is |

---

## 4. The KRaft Metadata Snapshot: Binary Format and Contents

### 4.1 File format

A `.checkpoint` file is **byte-for-byte identical to a Kafka log segment** (RecordBatch v2
format). The only structural difference:

- First batch: control batch containing `SnapshotHeaderRecord`
- Middle batches: data batches containing metadata records
- Last batch: control batch containing `SnapshotFooterRecord`

**File naming**:
```
<20-digit-zero-padded-end-offset>-<10-digit-zero-padded-epoch>.checkpoint
e.g.: 00000000000000012345-0000000001.checkpoint
```

Temporary files: `.checkpoint.part`. Pending deletion: `.checkpoint.deleted`.

### 4.2 Reading the snapshot

`kafka-dump-log.sh` handles `.checkpoint` files natively (it explicitly branches on the
`.checkpoint` suffix — source: `tools/.../DumpLogSegments.java`):

```bash
kafka-dump-log.sh \
  --files /path/to/__cluster_metadata-0/00000000000000012345-0000000001.checkpoint \
  --cluster-metadata-decoder \
  --deep-iteration \
  --print-data-log
```

Output per record:
```json
{"type":"FeatureLevelRecord","data":{"name":"metadata.version","featureLevel":20}}
{"type":"TopicRecord","data":{"name":"orders","topicId":"abc123..."}}
{"type":"PartitionRecord","data":{"topicId":"abc123...","partitionId":0,"replicas":[3,7,1],"isr":[3,7,1],"leader":3,...}}
{"type":"RegisterBrokerRecord","data":{"brokerId":3,"fenced":false,"logDirs":["uuid1"],...}}
```

### 4.3 Key record types and their role in recovery

**`TopicRecord`** — maps topic name to UUID:
```json
{"topicId": "<uuid>", "name": "my-topic"}
```
This UUID must match the `topic_id` in each partition's `partition.metadata`. Passed through
unchanged in any snapshot rewrite.

**`PartitionRecord`** — the authoritative replica map:
```json
{
  "topicId": "<uuid>",
  "partitionId": 0,
  "replicas": [3, 7, 1],
  "isr": [3, 7, 1],
  "leader": 3,
  "leaderEpoch": 5,
  "partitionEpoch": 2,
  "directories": ["<dir-uuid-on-3>", "<dir-uuid-on-7>", "<dir-uuid-on-1>"]
}
```

- `replicas[]` → checked by `isStrayReplica()`. **This is what determines stray detection.**
- `isr[]` → determines whether clean leader election can happen (leader must be in ISR)
- `leader` → current leader broker ID (-1 if none)
- `directories[]` → parallel to `replicas[]`: the `directory.id` UUID from `meta.properties`
  of each replica's host directory; can be set to `UNASSIGNED` to skip directory-level check

**`RegisterBrokerRecord`** — broker registration state:
```json
{
  "brokerId": 3,
  "fenced": true,
  "logDirs": ["<dir-uuid>"],
  "incarnationId": "<random-uuid-per-process-start>"
}
```
Fenced brokers auto-unfence ~9 seconds after they start heartbeating. Missing brokers (those
not running in the new cluster) never unfence — their ISR participation is stuck until the
controller fences them out and shrinks ISR accordingly.

**`FeatureLevelRecord`**: metadata.version and other feature levels. Pass through unchanged.

**`KRaftVersionRecord` / `VotersRecord`**: only present in dynamic quorum mode (KIP-853,
Kafka 3.7+). Contains the voter set. Must be updated if changing controller node IDs in
dynamic quorum mode.

### 4.4 `directories[]` and `DirectoryId` sentinels

The `directories[]` field in `PartitionRecord` can contain:

| Value | Meaning | Treated as online? |
|---|---|---|
| Real UUID | Specific directory on that broker | Only if found in broker's registered LogDirs |
| `MIGRATING` (0L, 0L) | Pre-KIP-858 replica, directory not tracked | **Yes — always** |
| `UNASSIGNED` (0L, 1L) | Assigned to broker, not yet to specific dir | **Yes — always** |
| `LOST` (0L, 2L) | Directory known offline/cordoned | No |

**Key insight for recovery**: Setting `directories[i]` to `UNASSIGNED` for all replicas in
a rewritten snapshot eliminates the need to know or track original `directory.id` values.
Kafka will locate the partition directory in any of the broker's `log.dirs` automatically.
This is the simplest and most robust approach for the snapshot rewrite tool.

### 4.5 Writing a new snapshot

Kafka provides first-class APIs for this in `kafka/metadata/src/main/java/org/apache/kafka/metadata/util/`:

- **`BatchFileReader`** — reads any `.checkpoint` or `.log` file as an iterator of
  `BatchAndType` records. Uses the same `FileRecords.open()` path as log segment reading.
- **`BatchFileWriter`** — creates a new `.checkpoint` file. Automatically writes
  `SnapshotHeaderRecord` on open and `SnapshotFooterRecord` on close. Accepts
  `ApiMessageAndVersion` records via `.append()`.

These APIs are in the `kafka-metadata` jar, which ships in every Kafka installation's
`libs/` directory. A read-modify-write tool using them is approximately 100–150 lines
of Java (see Section 10 for the full specification).

---

## 5. What `kafka-storage format` Actually Does

This is important to clarify because the original ADR relies on it as a core step.

### What it does (`Formatter.doFormat()` at `metadata/.../storage/Formatter.java:389`)

1. Scans all directories in both `log.dirs` and `metadata.log.dir`
2. Classifies each as: `emptyLogDir` (no `meta.properties`) or `logDirProps` (has one)
3. For each `emptyLogDir` only:
   - Creates the directory if absent
   - Writes `bootstrap.checkpoint` (contains only `FeatureLevelRecord` entries for feature versions)
   - Writes `meta.properties` with `node.id`, `cluster.id`, a freshly generated `directory.id`
   - Dynamic quorum only: also writes `__cluster_metadata-0/00000000000000000000-0000000000.checkpoint`
4. Directories already having `meta.properties`: **completely ignored — nothing is touched**

### What it does NOT do

- Does not delete, modify, or read any existing file other than `meta.properties`
- Does not create `quorum-state` (created by the Raft engine on first startup)
- Does not create `__cluster_metadata-0/` for static quorum clusters
- Does not touch partition data, indexes, checkpoints, or `partition.metadata` files
- Does not know about the original cluster's topics or partition assignments

### Why it is the wrong tool for our recovery

1. It **cannot modify** existing `meta.properties` files — only creates new ones in empty dirs.
   Our snapshot directories already have `meta.properties`. We need to edit them, not recreate.

2. Its bootstrap snapshot (`bootstrap.checkpoint`) contains only feature version records —
   it knows nothing about our topics, partitions, or brokers. Starting from it would give us
   an empty cluster with no knowledge of the original data.

3. We do not need `kafka-storage format` at all. `meta.properties` is a plain Java properties
   file — it can be edited with any text processing tool. The metadata snapshot comes from
   the original cluster, not from `format`.

---

## 6. The `quorum-state` File

**Location**: `<metadata.log.dir>/__cluster_metadata-0/quorum-state`

**Format**: Single-line JSON. See Section 7 for version-specific formats.

### What happens if `quorum-state` is absent

From `raft/src/main/java/org/apache/kafka/raft/FileQuorumStateStore.java:132`:

```java
public Optional<ElectionState> readElectionState() {
    if (!stateFile.exists()) {
        return Optional.empty();  // no prior state → fresh election
    }
    ...
}
```

If the file is absent, the Raft engine starts a fresh election with `leaderEpoch=0` among
the voters defined in `controller.quorum.voters` config (static) or the bootstrap snapshot
(dynamic). **This is safe and the cleanest recovery path.**

### What happens if `quorum-state` still references the 9-node voter set

For **`data_version: 0`** (static quorum): `currentVoters` in the file lists 9 voter IDs.
When only 3 controllers start, they cannot reach a majority of 5. The cluster hangs in
permanent election state. **No requests can be served.**

For **`data_version: 1`** (dynamic quorum): The voter set is in the metadata snapshot's
`VotersRecord`, not in `quorum-state`. But if the snapshot still lists 9 voters, same problem.

### Action for recovery

**Delete `quorum-state` on all nodes.** On startup with `controller.quorum.voters` set to
the 3 (or 6) new node IDs in `server.properties`, Kafka writes a fresh `quorum-state` using
only those voters. The `leaderEpoch` restarts from 0, which is safe.

---

## 7. KRaft Quorum Modes: Static vs Dynamic

### How to detect which mode the production cluster uses

```bash
cat <snapshot_dir>/__cluster_metadata-0/quorum-state
```

**Static quorum** (`data_version: 0`) — the common case:
```json
{
  "clusterId": "MkQkDy5fTnShlSYvMZcXAA",
  "leaderId": 2,
  "leaderEpoch": 47,
  "votedId": -1,
  "appliedOffset": 99823,
  "currentVoters": [{"voterId": 0}, {"voterId": 1}, {"voterId": 2}],
  "data_version": 0
}
```

**Dynamic quorum / KIP-853** (`data_version: 1`) — Kafka 3.7+, rare:
```json
{
  "leaderId": 2,
  "leaderEpoch": 47,
  "votedId": -1,
  "data_version": 1
}
```

### Recovery differences

| | Static quorum | Dynamic quorum (KIP-853) |
|---|---|---|
| Voter set location | `controller.quorum.voters` in config | `VotersRecord` in metadata snapshot |
| Fix for voter set | Delete `quorum-state`; set `controller.quorum.voters` in `server.properties` | Delete `quorum-state` AND rewrite `VotersRecord` in snapshot |
| Snapshot rewrite needed for voter change? | No | Yes |
| Kafka version | All KRaft versions | 3.7+ only |
| Common in production? | **Yes, by far** | Rare |

**Recommendation**: Inspect `quorum-state` from any of the 9 snapshots before starting
recovery. If `data_version` is 0, static quorum handling applies. If 1, the snapshot rewrite
tool must also update `VotersRecord` entries.

---

## 8. Replica Placement: Why the Original ADR's Assumptions Are Wrong

### The ADR's claim

> "For RF=3 on 9 nodes, choosing brokers {0, 1, 2} guarantees 100% partition coverage because
> StripedReplicaPlacer distributes replicas using a deterministic striping algorithm."

### Why this is incorrect

`StripedReplicaPlacer` uses `new Random()` with **no fixed seed** at topic creation time
(`metadata/.../placement/StripedReplicaPlacer.java`). Each topic's replica assignment starts
at a random offset within the stripe pattern. Two topics in the same cluster will have
different stripe offsets. The placement is non-deterministic even for a perfectly configured,
sequential-ID cluster.

More critically: **`StripedReplicaPlacer` is only called when creating new topics.** It has
no relevance for existing partition assignments. The authoritative ground truth for
"which broker holds which partition" is exclusively `PartitionRecord.Replicas[]` in the KRaft
snapshot.

Additionally: custom `ReplicaPlacer` implementations are supported; rack topology affects
placement; and even within StripedReplicaPlacer, the stripe offset cycles per partition
created, making it impossible to reconstruct historical assignments without the exact creation
sequence.

### What this means for broker selection

We cannot predict which 3 (or 6) brokers maximise partition coverage without reading the
actual `PartitionRecord` entries. We must read the snapshot first (Phase 0) to determine
exact leader distributions.

**With all 9 snapshots available**, coverage is not an existential concern — every partition
has at least one replica on at least one of the 9 brokers. The question is which partitions
have all their replicas on the brokers we did *not* choose, making them offline at startup.
This is quantified in Section 9.

---

## 9. The Offline Partition Problem: Cluster Size vs Data Recovery

### The mathematics

In a 9-node cluster with RF=3, when we run N brokers (impersonating N of the original 9 IDs),
partitions whose all 3 replicas fall on the (9−N) missing brokers will be offline at startup.

Assuming fully random placement:

```
P(all 3 replicas on missing brokers) = C(9-N, 3) / C(9, 3)
```

| Target nodes | Missing nodes | P(partition offline) | Expected offline rate |
|---|---|---|---|
| 3-node | 6 missing | C(6,3)/C(9,3) = 20/84 | **≈ 23.8%** |
| 4-node | 5 missing | C(5,3)/C(9,3) = 10/84 | **≈ 11.9%** |
| 5-node | 4 missing | C(4,3)/C(9,3) = 4/84  | **≈ 4.8%**  |
| 6-node | 3 missing | C(3,3)/C(9,3) = 1/84  | **≈ 1.2%**  |
| 7-node | 2 missing | 0/84                   | **0%**      |

> These are statistical expectations for random placement. Reading the snapshot
> in Phase 0 gives the exact count, not an estimate.

### Implications

**3-node without snapshot rewrite**: ~24% of partitions completely offline. Roughly 1 in 4
consumers and producers blocked immediately. This does not meet the "no blocked users"
requirement.

**6-node without snapshot rewrite**: ~1.2% of partitions offline. At 10,000 total partitions,
~120 partitions need post-start reassignment. Manageable, and only affects those specific
topic-partitions.

**Any node count with snapshot rewrite**: 0% offline partitions from startup, regardless
of cluster size. Every partition gets at least one live replica assigned.

### Recommendation on cluster size

**Target 6-node as the minimum.** The jump from 3-node to 6-node is not a 2× improvement —
it is the difference between "most consumers broken at startup" and "less than 2% impact."
For a testing environment where "no blocked users" is a requirement, 6-node without a
snapshot rewrite tool is already close to acceptable. 3-node without the rewrite tool is not.

If operational constraints force 3-node, the snapshot rewrite tool moves from "nice to have"
to **required** to meet the no-blocked-users requirement.

---

## 10. What a Snapshot Rewrite Tool Must Do

This section specifies the rewrite tool requirements without assuming implementation language
or mechanism. It is the basis for any future implementation decision.

### Purpose

Take the best available metadata snapshot from the original 9-node cluster and produce a
new snapshot valid for a reduced cluster (3 or 6 nodes), ensuring every partition has at
least one live replica and the quorum voter set matches the new cluster.

### Inputs

1. The source `.checkpoint` file (best available metadata snapshot from any of the 9 nodes)
2. The set of broker IDs that will run in the new cluster (e.g., `{3, 7, 1, 4, 8, 2}`)
3. Optionally: a mapping of old→new broker IDs (can be identity if keeping original IDs)
4. Whether to use `UNASSIGNED` for all directory references (recommended: yes)

### Processing rules per record type

**`PartitionRecord`**:

```
surviving = replicas[] ∩ new_broker_ids

if surviving is non-empty:
  new_replicas  = surviving  (only brokers we are actually running)
  new_isr       = surviving  (same — all surviving are considered in ISR)
  new_leader    = first element of surviving, preferring original leader if present
  new_leaderEpoch    = original + 1  (signal leadership change)
  new_partitionEpoch = original + 1  (invalidate stale cached metadata)
  new_directories    = [UNASSIGNED] * len(surviving)  (simplest, skips dir-level validation)
  new_leaderRecoveryState = RECOVERING  (marks that ISR may have shrunk)
  emit record

if surviving is empty (data truly not available on any chosen broker):
  Option A — skip: partition will be offline; fix post-start via reassignment
  Option B — assign to any live broker: partition comes online empty (data loss accepted)
  For "no blocked users" requirement: use Option B
```

**`RegisterBrokerRecord`**:

```
for broker in new_broker_ids:
  keep original RegisterBrokerRecord for that broker ID, with:
    fenced = false         (allows faster startup; normal heartbeat cycle still applies)
    logDirs = [<original directory UUIDs>]  (or updated UUIDs if directory.id changed)

for broker NOT in new_broker_ids:
  omit entirely (cleaner than leaving fenced-forever brokers)
```

**`TopicRecord`**: Pass through unchanged. Topic names and UUIDs must be preserved exactly —
they are cross-referenced by `partition.metadata` files.

**`FeatureLevelRecord`**: Pass through unchanged.

**`ConfigRecord`** (topic/broker configurations): Pass through unchanged.

**`ProducerIdsRecord`**: Pass through unchanged. Preserves producer ID allocation state.

**`ClientQuotaRecord`, `UserScramCredentialRecord`, `AccessControlEntryRecord`**: Pass through
unchanged. Operational metadata, not cluster topology.

**`VotersRecord` / `KRaftVersionRecord`** (dynamic quorum only, `data_version: 1`):
Replace voter set entries with the new cluster's controller node IDs. Only needed if
production uses KIP-853 dynamic quorum.

**All other record types**: Pass through unchanged unless they embed specific broker IDs.

### Output

A valid `.checkpoint` file containing:
- `SnapshotHeaderRecord` as first control batch
- All transformed data records in data batches
- `SnapshotFooterRecord` as last control batch

The output filename should match the input's offset and epoch
(`<offset>-<epoch>.checkpoint`) so it can be a drop-in replacement. It is placed in
`__cluster_metadata-0/` on all nodes, replacing the original snapshot.

### Why the snapshot is small regardless of partition data size

The metadata snapshot contains only cluster topology and configuration records — no actual
message data. Regardless of how many TBs of partition data exist, the snapshot is typically
10–100 MB. Reading and rewriting it takes seconds.

### Tool implementation options

Any language/runtime that can:
1. Read Kafka RecordBatch v2 binary format
2. Decode the versioned metadata record schemas
3. Write the same format back with correct framing

The most practical path is **Java using Kafka's own `BatchFileReader` and `BatchFileWriter`**
APIs from the `kafka-metadata` jar (ships in every Kafka `libs/` directory). These handle
all format details. The program would be approximately 100–150 lines.

A Python/Go/Rust implementation would need to independently implement the RecordBatch v2
decoding and the metadata record schema deserialization — significantly more work, but the
format is fully documented in the Kafka protocol specification.

---

## 11. Strategy Analysis for TB-Scale Recovery

### Strategies eliminated for TB-scale

**Original ADR Strategy A/C (fresh KRaft + topic recreation + data injection)**:

Eliminated because:
- Requires recreating every topic via `kafka-topics.sh --create`
- Requires knowing every topic's partition count, RF, and all configuration overrides
- Requires moving TBs of partition data from snapshots into new empty directories
- Even with pre-exported configs, O(topics) CLI operations are fragile and slow

This approach was designed for small clusters with manageable topic counts.

---

### Strategy 1: Keep Original Broker IDs (shell scripts only)

**Core idea**: Each new node impersonates an original broker ID by running with the same
`node.id`. The KRaft metadata snapshot is used verbatim from the best available source,
with only the minimum surgical changes.

**What changes**:
- `server.properties`: set `node.id`, `controller.quorum.voters`, listener configs
- `__cluster_metadata-0/quorum-state`: **delete**
- `__cluster_metadata-0/*.log`: **delete all** (keep only the best `.checkpoint`)
- Everything else: **untouched**

**What stays the same**:
- All partition data files
- All `meta.properties` files (assuming same node IDs)
- All `partition.metadata` files
- All checkpoint files
- The metadata `.checkpoint` snapshot (used as-is)

**Offline partitions at startup**: proportional to how many partitions have all 3 replicas
on the 6 (or 3) missing broker IDs. See Section 9 for statistics.

**Pros**:
- No custom tooling
- Minimal file manipulation (shell scripts)
- All topic configs, consumer group offsets, ACLs, transactions preserved exactly
- `partition.metadata` valid without any changes

**Cons**:
- ~24% offline partitions for 3-node (unacceptable for "no blocked users")
- ~1.2% offline partitions for 6-node (manageable with post-start reassignment)

---

### Strategy 2: Keep Original Broker IDs + Snapshot Rewrite

**Core idea**: Same as Strategy 1 for all data handling, plus rewrite the KRaft metadata
snapshot before starting any node. The rewritten snapshot ensures every partition has at
least one live replica.

**Additional step**: After Phase 1 (mass copy) and before Phase 3 (start nodes), run the
snapshot rewrite tool to produce a clean snapshot where `PartitionRecord.Replicas[]` contains
only the IDs of the brokers we are actually running.

**Result**: At startup, `isStrayReplica()` returns false for every partition directory.
No offline partitions. No unclean election needed for startup.

**Pros**:
- Zero offline partitions at startup regardless of cluster size
- No post-start reassignment for data recovery
- Cleanest possible starting state

**Cons**:
- Requires building the snapshot rewrite tool
- Snapshot file must be well-formed (handled by `BatchFileWriter` or equivalent)

---

### Decision Matrix

| Factor | Strategy 1 (no rewrite) | Strategy 2 (with rewrite) |
|---|---|---|
| **Offline partitions — 6-node** | ~1.2% | 0% |
| **Offline partitions — 3-node** | ~24% | 0% |
| **Custom tooling** | None | ~150 lines Java or equivalent |
| **File manipulation** | Delete quorum-state + stale .log segments | Above + produce new snapshot |
| **partition.metadata** | Keep as-is | Keep as-is |
| **Consumer group offsets** | Fully preserved | Fully preserved |
| **Topic configs** | Fully preserved | Fully preserved |
| **Time to implement** | Hours | 1–2 days |
| **"No blocked users" at 6-node** | Close — fix ~1.2% post-start | Yes, from first startup |
| **"No blocked users" at 3-node** | No — 24% blocked at startup | Yes, from first startup |

---

## 12. Recommended Recovery Process

This process applies to both strategies. Strategy 2 adds only Phase 2b.

### Phase 0: Snapshot Analysis (minutes)

From any one of the 9 snapshot metadata directories, find and dump the latest snapshot:

```bash
# Find most recent snapshot (highest numeric offset in filename):
ls -1 <any_snapshot_dir>/__cluster_metadata-0/*.checkpoint | sort -V | tail -1

# Dump it:
kafka-dump-log.sh \
  --files <above-file> \
  --cluster-metadata-decoder \
  --deep-iteration \
  --print-data-log \
  > cluster-state.json

# Inspect quorum mode:
cat <any_snapshot_dir>/__cluster_metadata-0/quorum-state | python3 -m json.tool
```

From `cluster-state.json`, extract:
- `cluster.id` (from any `RegisterBrokerRecord` or header line)
- For each `PartitionRecord`: the `leader` field — count how many partitions each broker leads
- Quorum mode from `quorum-state`: `data_version` 0 (static) or 1 (dynamic)

**Choose which broker IDs to run**:
- Select N brokers (N = 6 recommended). Prefer brokers that led the most partitions
  (data will be most current on those nodes).
- In a balanced cluster any N brokers give roughly equivalent coverage.

**Identify the best metadata snapshot**:
- Prefer the `.checkpoint` with the highest offset number from the chosen brokers.
- In a healthy cluster all nodes' snapshots should have the same content — they are
  distributed identically across all controller nodes.

### Phase 1: Mass Copy (hours — limited only by disk throughput)

For each new node, mount or volume-copy the entire snapshot from its corresponding
original broker. No per-file selection. No per-partition analysis.

```
New Node 1 ← full snapshot volume of original broker A  (will run as node.id=A)
New Node 2 ← full snapshot volume of original broker B  (will run as node.id=B)
...
New Node N ← full snapshot volume of original broker N  (will run as node.id=N)
```

### Phase 2a: Surgical File Edits (minutes per node, fully parallelisable)

On each node, after the snapshot volume is available:

```bash
METADATA_DIR="<path to __cluster_metadata-0>"

# 1. Remove stale Raft log segments (may contain records for missing brokers):
rm -f "${METADATA_DIR}"/*.log
rm -f "${METADATA_DIR}"/*.checkpoint.deleted
rm -f "${METADATA_DIR}"/*.checkpoint.part

# 2. Remove quorum-state (will be recreated fresh on startup):
rm -f "${METADATA_DIR}/quorum-state"

# 3. Ensure the best .checkpoint is in place.
#    If snapshots across nodes differ in offset, copy the highest-offset one to all nodes.
#    (In a healthy cluster they should already be identical.)

# 4. Update server.properties — the only config file that changes:
cat > /path/to/server.properties << EOF
node.id=<original_broker_id>
process.roles=broker,controller
controller.quorum.voters=A@host1:9093,B@host2:9093,...
listeners=PLAINTEXT://:9092,CONTROLLER://:9093
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER
log.dirs=<same path as in original snapshot>
metadata.log.dir=<same path as in original snapshot>
unclean.leader.election.enable=true
EOF

# 5. Verify meta.properties node.id matches server.properties node.id:
grep node.id <log_dir>/meta.properties
# Should return: node.id=<same ID as configured above>
```

`meta.properties` does not need editing as long as `node.id` in the file matches the
broker ID we are running. Verify, do not assume.

### Phase 2b: Snapshot Rewrite (Strategy 2 only — skip for Strategy 1)

Run the snapshot rewrite tool against the best available `.checkpoint`:

```
Input:  <best_snapshot>.checkpoint
        surviving broker IDs: {A, B, C, ...}
        mode: use UNASSIGNED for all directory references

Output: rewritten.checkpoint
        - PartitionRecord.Replicas[] contains only IDs in {A, B, C, ...}
        - PartitionRecord.Isr[] contains only IDs in {A, B, C, ...}
        - RegisterBrokerRecord entries only for {A, B, C, ...}
        - PartitionRecord.Directories[] all set to UNASSIGNED
        - All TopicRecord, FeatureLevelRecord, ConfigRecord etc. unchanged
```

Place the output on all nodes:
```bash
cp rewritten.checkpoint "${METADATA_DIR}/"
# Remove the original checkpoint if desired, or leave both
# (Kafka uses the one with the highest offset — they should have the same offset)
```

### Phase 3: Start the Cluster (seconds)

Start all nodes simultaneously or as close as possible:

```bash
kafka-server-start.sh /path/to/server.properties
```

Monitor:
```bash
# Quorum health — expect 1 leader elected within seconds:
kafka-metadata-quorum.sh --bootstrap-controller host:9093 describe --status

# Offline partitions:
# Strategy 2: expect 0
# Strategy 1: expect ~1.2% for 6-node, ~24% for 3-node
kafka-topics.sh --bootstrap-server host:9092 --describe --unavailable-partitions

# Under-replicated partitions — expected initially, resolves as ISR re-establishes:
kafka-topics.sh --bootstrap-server host:9092 --describe --under-replicated-partitions
```

### Phase 4: Post-Start Recovery (Strategy 1 only)

For each offline partition:

```bash
# Partitions where ≥1 live replica exists but is not currently elected leader:
# unclean.leader.election.enable=true (already set) handles most of these automatically.
# Force election if needed:
kafka-leader-election.sh \
  --bootstrap-server host:9092 \
  --election-type UNCLEAN \
  --all-topic-partitions

# Partitions with ZERO live replicas (all data on missing brokers):
# These cannot be recovered. They must be reassigned as empty partitions (data loss).
# Generate and execute a reassignment plan for offline partitions.
kafka-reassign-partitions.sh \
  --bootstrap-server host:9092 \
  --reassignment-json-file reassign-offline.json \
  --execute
```

### Phase 5: Stabilise

```bash
# Once all partitions are online, disable unclean election:
kafka-configs.sh --bootstrap-server host:9092 \
  --alter --entity-type brokers --entity-default \
  --add-config unclean.leader.election.enable=false

# Verify final state:
kafka-topics.sh --bootstrap-server host:9092 --describe --unavailable-partitions
# Expected: empty output (no offline partitions)

kafka-metadata-quorum.sh --bootstrap-controller host:9093 describe --status
# Expected: N voters, 1 leader, all voters in sync
```

---

## 13. Decision Points Requiring Input

The following must be determined before finalising the implementation:

### D1: Target cluster size

**Recommendation: 6-node minimum.** The offline partition rate drops from 24% (3-node) to
1.2% (6-node) — a 20× improvement for exactly double the node count. If the testing
environment can support 6 nodes, it should.

### D2: Quorum mode of production cluster

Inspect `quorum-state` from any of the 9 snapshots before starting recovery:
- `"data_version": 0` → static quorum (handle with config only)
- `"data_version": 1` → dynamic quorum (snapshot rewrite required for voter set)

### D3: Build the snapshot rewrite tool?

- 6-node + willing to accept ~1.2% post-start reassignment: not strictly required
- 3-node OR "zero offline partitions from startup" is a hard requirement: **required**
- Recommendation: build it — it is a one-time investment that makes recovery clean and
  repeatable regardless of cluster size or partition distribution

### D4: Are `metadata.log.dir` and `log.dirs` on separate volumes?

If on the same volume (single disk image), the metadata snapshot is included in the mass
copy automatically. If separate, the metadata directory may need separate handling. Verify
in the production `server.properties`.

### D5: Which N original broker IDs to impersonate?

Run Phase 0 (dump the snapshot) to get exact per-broker partition leadership counts.
Prefer brokers that held more partition leaders, as their data copies are the most current.
If the cluster was balanced, any N brokers are roughly equivalent.

---

## 14. Appendix

### A. Source File Index

| Source file | Relevance |
|---|---|
| `storage/src/main/java/org/apache/kafka/storage/internals/log/LogManager.java:63` | `isStrayReplica()` — the partition deletion trigger |
| `core/src/main/scala/kafka/server/metadata/BrokerMetadataPublisher.scala:316` | Where stray detection is wired into startup |
| `metadata/src/main/java/org/apache/kafka/metadata/properties/MetaPropertiesEnsemble.java:472` | `verify()` — all startup identity validation |
| `metadata/src/main/java/org/apache/kafka/metadata/storage/Formatter.java:389` | `doFormat()` — exactly what `kafka-storage format` writes |
| `raft/src/main/java/org/apache/kafka/raft/FileQuorumStateStore.java:132` | `readElectionState()` — absent quorum-state is safe |
| `metadata/src/main/java/org/apache/kafka/metadata/util/BatchFileWriter.java` | Official API for writing new snapshot files |
| `metadata/src/main/java/org/apache/kafka/metadata/util/BatchFileReader.java` | Official API for reading snapshot files |
| `storage/src/main/java/org/apache/kafka/storage/internals/log/PartitionMetadataFile.java` | `partition.metadata` format and UUID check |
| `metadata/src/main/java/org/apache/kafka/metadata/placement/StripedReplicaPlacer.java` | Random-seeded; only relevant at topic-creation time |
| `server-common/src/main/java/org/apache/kafka/common/DirectoryId.java` | `UNASSIGNED`/`MIGRATING`/`LOST` sentinel values |

### B. Key Error Messages Reference

| Error message | Root cause | Fix |
|---|---|---|
| `Stored node id X doesn't match previous node id Y in <path>` | Two `meta.properties` on same broker have different `node.id` | Ensure all dirs on a node have the same `node.id`; match `server.properties` |
| `Invalid cluster.id in: X. Expected Y, but read Z` | `meta.properties` `cluster.id` mismatch | Rewrite mismatched `meta.properties` |
| `InconsistentTopicIdException: Topic ID of my-topic-0 is <old> but does not match <new>` | `partition.metadata` UUID differs from `TopicRecord` UUID in snapshot | Keep `partition.metadata` and original snapshot together; never mix snapshots with data from different topic incarnations |
| `Log in X marked stray and renamed to X-stray` | `isStrayReplica` returned true: broker's `node.id` not in `Replicas[]` | Ensure `node.id` in config and `meta.properties` matches the original broker ID in the snapshot; or rewrite snapshot |
| `Waiting to join the quorum (leaderId=optional.empty, epoch=0)` | `quorum-state` voter set references missing brokers, or `controller.quorum.voters` config mismatch | Delete `quorum-state`; verify `controller.quorum.voters` lists only the running nodes |
| `Encountered I/O error in metadata log directory X` | Metadata dir `meta.properties` is corrupt or unreadable | Fatal — restore `meta.properties` in metadata dir |
| `Error while reading the Quorum status from the file quorum-state` | `quorum-state` is corrupt or has unexpected format | Delete `quorum-state` — it will be recreated |

### C. Cluster Self-Healing Behaviour

**Automatic — no intervention needed**:
- Broker heartbeat session expires → controller writes `FenceBrokerRecord` within ~9s → ISR
  shrinks via `PartitionChangeRecord`
- A returning broker heartbeats → catches up to its own registration offset → controller
  writes `UnfenceBrokerRecord` → re-joins ISR naturally
- Segment tail corruption (from live snapshot) → `LogLoader.recover()` truncates automatically
- CRC failures in producer `.snapshot` files → fallback to older snapshot or log replay

**Requires manual intervention**:
- All ISR members for a partition are permanently gone → partition leaderless → needs
  unclean election or reassignment
- KRaft controller quorum lost → cluster cannot make metadata changes → must adjust
  `controller.quorum.voters` config and restart surviving controllers
- `quorum-state` references 9-node voter set on a 3/6-node cluster → permanent election
  deadlock → delete `quorum-state` (covered in Phase 2a of this process)
