# Kafka 9-Node → 3-Node Snapshot Recovery Plan

## Scope & Constraints

| Constraint | Detail |
|---|---|
| **Source cluster** | 9 brokers, 3 regions, 3 brokers per region, KRaft mode, rack-aware |
| **Target cluster** | 3 brokers (one region's worth) |
| **Snapshots** | Automatic hourly IBM hardware snapshots; no pre-snapshot coordination or live cluster access |
| **Data loss** | Acceptable and expected — goal is best-effort recovery |
| **Infrastructure** | DevOps/GitOps; all nodes share identical disk layout, configs, and physical harness |
| **Tiered storage** | Not in use, not planned |
| **Kafka version** | Target always matches source binary version |

### Out of Scope

**Topics with replication factor less than 3 are outside the default recovery path.** A single-region restore may not contain any surviving replica for them. The baseline plan does not attempt to auto-recover these topics. If the snapshot rewrite encounters a partition with no surviving replica on the selected region, it should fail fast and report that partition so operators can explicitly choose whether to drop/re-create it or design a separate "empty partition" recovery mode later.

---

## 1. Background: How Kafka Stores State (and Why Recovery Is Hard)

Understanding Kafka's storage architecture is essential context for every decision in this plan. Kafka on KRaft stores cluster state in two entirely separate layers, and the tension between them is what makes snapshot recovery non-trivial.

### 1.1 The Two-Layer Architecture

```
LAYER 1: KRaft Metadata (the "brain")
  Location: <metadata.log.dir>/__cluster_metadata-0/

  Key files:
    <offset>-<epoch>.checkpoint   Binary snapshot of entire cluster state
    <offset>.log                  Incremental records after the latest snapshot
    quorum-state                  JSON: Raft election state (leader, voter set)

  This layer is the single source of truth for:
    - Which broker IDs exist in the cluster
    - Which broker IDs host which partition replicas
    - Which directory UUID on each broker holds each replica
    - ISR membership, partition leaders, topic UUIDs
    - Topic configurations, ACLs, SCRAM credentials, feature versions

LAYER 2: Partition Data (the "body")
  Location: <log.dirs>/<topic>-<partition>/

  Key files per partition directory:
    *.log, *.index, *.timeindex   Actual message data
    partition.metadata             Contains the topic UUID (not broker ID)
    leader-epoch-checkpoint        Epoch history
    *.snapshot                     Producer state

  Key files at each log.dirs root:
    meta.properties                node.id, cluster.id, directory.id
    recovery-point-offset-checkpoint
    replication-offset-checkpoint   (high watermarks)
    log-start-offset-checkpoint
```

**The critical property of partition data**: Log segment files (`*.log`, `*.index`, `*.timeindex`) do not embed any broker ID. A directory `my-topic-0/` from broker 7 can be placed on broker 1 and Kafka will read it correctly — **provided the KRaft metadata is updated** to say "broker 1 is a replica for my-topic partition 0."

This portability is what makes snapshot recovery possible. But it also means these two layers must agree, or data is destroyed.

### 1.2 The Stray Detection Problem — The Central Risk

When a Kafka broker starts, it cross-references every partition directory it finds on disk against the KRaft metadata. If the metadata does not list this broker as a replica for that partition, the directory is **silently renamed** to `<topic>-<partition>-stray` and then **permanently deleted** after `file.delete.delay.ms` (default: 60 seconds).

The check works as follows:

1. Broker reads `partition.metadata` inside the partition directory to get the topic UUID
2. Broker looks up that topic UUID in the KRaft metadata to find the `PartitionRecord`
3. Broker checks whether its own `node.id` appears in `PartitionRecord.Replicas[]`
4. If not present → **stray** → renamed → deleted

**This is the most dangerous aspect of the entire recovery.** If the KRaft metadata snapshot still references the original 9 broker IDs (e.g., 0-8) but our 3 recovered brokers are running as different IDs, then every single partition directory will be classified as stray and deleted within 60 seconds. Terabytes of data, gone.

**This is why we keep the original broker IDs** (each recovered node runs with the same `node.id` as the original broker whose snapshot it received): that is what prevents blanket stray deletion. **Rewriting the metadata snapshot serves a different purpose**: it collapses the original 9-node replica assignments down to the 3 recovered brokers so every in-scope RF=3 partition remains assigned to at least one live replica and the cluster does not start with offline partitions.

### 1.3 The `meta.properties` Identity File

Each log directory root contains a `meta.properties` file:

```properties
version=1
node.id=7
cluster.id=MkQkDy5fTnShlSYvMZcXAA
directory.id=J8aAPcfLQt2bqs1JT_rMgQ
```

Kafka validates on startup that:
- All `meta.properties` files on the same broker agree on `node.id` — any mismatch and the broker refuses to start
- All agree on `cluster.id` — mismatch crashes the broker
- `directory.id` is unique per directory and is not a reserved sentinel value

Since we keep original broker IDs, the `meta.properties` files from the snapshot are already correct and require no changes.

---

## 2. Why One Region Is the Right Selection

With rack awareness enabled and RF=3, Kafka guarantees one replica per region. Selecting all 3 brokers from a single region gives us:

- **One copy of every RF=3 partition** — rack awareness guarantees exactly one replica exists in each region
- **No per-partition coverage analysis needed** — the guarantee is structural, not statistical
- **Simplest snapshot workflow** — snapshot one region's infrastructure as a unit

Since snapshots are taken automatically every hour at the infrastructure level, the "broker selection" decision is simply: **which region's snapshots do we restore?** In a balanced cluster, any region is equivalent. If one region is known to be more current (e.g., hosted more partition leaders), prefer that one.

---

## 3. Recommended Strategy: Keep Original Broker IDs + Snapshot Rewrite

The recommended approach is:

1. **Mass-copy full disk images** from the 3 selected brokers' snapshots — no per-topic or per-partition work
2. **Keep original broker IDs** — each recovered node runs as the same `node.id` as the source broker
3. **Rewrite the KRaft metadata snapshot** — so that partition assignments reference only the 3 live brokers

### Why This Approach (vs. Alternatives)

The main alternative would be to format a fresh KRaft cluster, recreate all topics via CLI, and inject partition data into the new directories. This has significant drawbacks at scale:

| Factor | Fresh KRaft approach | Recommended approach |
|---|---|---|
| **TB-scale feasibility** | Requires per-topic CLI recreation — fragile and slow at hundreds of topics | Mass-copy; no per-topic work |
| **Topic UUIDs** | New UUIDs generated at topic creation → must delete every `partition.metadata` file or all data is stray-detected and destroyed | Original UUIDs preserved → `partition.metadata` files remain valid |
| **Consumer offsets** | `__consumer_offsets` partition count must match exactly when recreating; `hash(group.id) % num_partitions` mapping breaks if it differs | Preserved automatically — same topic, same UUIDs, same partition count |
| **Topic configs** | Must export and re-apply all topic-level configs | Preserved in the metadata snapshot |
| **ACLs, quotas, credentials** | Lost (fresh KRaft has no history) | Preserved in the metadata snapshot |
| **Custom tooling** | None | ~150 lines Java (snapshot rewrite tool — see Section 4) |
| **Offline partitions at startup** | 0% (all brokers are replicas for all topics) | 0% (snapshot rewrite assigns all RF=3 partitions to live brokers) |

The snapshot rewrite tool is a one-time investment that makes the recovery clean, repeatable, and safe at any data scale.

---

## 4. The Snapshot Rewrite Tool

This section introduces the tool before it is used in the recovery process.

### 4.1 What Is a `.checkpoint` File?

The KRaft metadata snapshot is stored as a `.checkpoint` file inside `__cluster_metadata-0/`. It is a binary file in the Kafka RecordBatch v2 format — structurally identical to a regular Kafka log segment, but with a header and footer:

```
[SnapshotHeaderRecord]          ← control batch (marks start of snapshot)
[data batch: FeatureLevelRecord, TopicRecord, PartitionRecord, ...]
[data batch: RegisterBrokerRecord, ConfigRecord, ...]
...
[SnapshotFooterRecord]          ← control batch (marks end of snapshot)
```

The filename encodes the offset and epoch: `00000000000000012345-0000000001.checkpoint`

**Size**: The snapshot contains only cluster topology and configuration records — no actual message data. Regardless of how many terabytes of partition data exist, the metadata snapshot is typically 10-100 MB. Reading and rewriting it takes seconds.

### 4.2 Key Record Types Inside the Snapshot

| Record Type | What It Controls | Recovery Action |
|---|---|---|
| **`PartitionRecord`** | Which brokers hold which partition replicas; ISR membership; current leader; directory UUIDs | **Rewrite**: remove missing broker IDs from `Replicas[]` and `Isr[]` |
| **`RegisterBrokerRecord`** | Broker existence and fencing state | **Filter**: keep only the 3 live brokers; omit the other 6 |
| **`TopicRecord`** | Maps topic name to UUID | **Pass through unchanged** — UUID must match `partition.metadata` files |
| **`FeatureLevelRecord`** | `metadata.version` and feature flags | **Pass through unchanged** |
| **`ConfigRecord`** | Topic and broker configuration overrides | **Pass through unchanged** |
| **`ProducerIdsRecord`** | Producer ID allocation state | **Pass through unchanged** |
| **`ClientQuotaRecord`** | Per-client/user quotas | **Pass through unchanged** |
| **`AccessControlEntryRecord`** | ACLs | **Pass through unchanged** |
| **`VotersRecord`** | KRaft voter set (dynamic quorum only) | **Rewrite if present**: replace voter set with the 3 live node IDs |

### 4.3 The `UNASSIGNED` Directory Sentinel

Each `PartitionRecord` contains a `directories[]` field parallel to `replicas[]`. It maps each replica to the specific `directory.id` UUID of the disk directory holding that replica. If we were to change directory UUIDs, we would need to track the mapping from old to new — complex and error-prone.

Instead, setting `directories[i]` to `UNASSIGNED` (a sentinel UUID: `0L, 1L`) tells Kafka: "this replica is assigned to this broker, but not to a specific directory — find it in any of the broker's `log.dirs`." This eliminates directory-level validation entirely and is the simplest, most robust approach.

### 4.4 Implementation

Kafka ships first-class APIs for reading and writing snapshot files in the `kafka-metadata` jar (present in every Kafka installation's `libs/` directory):

- **`BatchFileReader`** — reads any `.checkpoint` file as an iterator of record batches
- **`BatchFileWriter`** — creates a new `.checkpoint` file with proper `SnapshotHeader`/`Footer` framing

A read-modify-write tool using these APIs is approximately **100-150 lines of Java**. The processing logic for each record type is specified in Section 5, Phase 4.

### 4.5 Why Not Edit In Place?

The `.checkpoint` file uses CRC-protected record batches. Any byte-level edit invalidates the CRC and corrupts the file. The only correct approach is to read the original, transform records in memory, and write a new file using the proper APIs.

---

## 5. Recovery Process

### Phase 1: Mount Snapshots

Restore the most recent hourly snapshots from the 3 selected brokers (one full region) to the target environment:

```
New Node 1 ← snapshot of original broker A  (will run as node.id=A)
New Node 2 ← snapshot of original broker B  (will run as node.id=B)
New Node 3 ← snapshot of original broker C  (will run as node.id=C)
```

Each new node keeps the **original broker ID**. This is essential: the partition data on disk was written by that broker, the `meta.properties` file identifies that broker, and the KRaft metadata assigns partitions to that broker. Changing IDs would require rewriting `meta.properties`, the metadata snapshot, and risk stray detection failures.

### Phase 2: Snapshot Analysis (minutes)

After mounting, inspect the snapshot data to gather information needed for subsequent phases. All commands run against local files — no live cluster access required.

```bash
# 1. Check quorum mode — determines whether VotersRecord rewrite is needed
#
# Why: The quorum voter set determines which nodes can participate in
# KRaft leader election. In "static" mode (data_version: 0), the voter
# set comes from server.properties and we only need to delete quorum-state.
# In "dynamic" mode (data_version: 1, Kafka 3.7+), the voter set is
# embedded inside the metadata snapshot's VotersRecord — meaning the
# snapshot rewrite tool MUST also update VotersRecord, or the cluster
# will try to form a 9-node quorum and deadlock.
#
cat <any_node>/__cluster_metadata-0/quorum-state | python3 -m json.tool
# If "data_version": 0 → static quorum (common case)
# If "data_version": 1 → dynamic quorum (rare; snapshot rewrite must update VotersRecord)

# 2. Identify the best metadata snapshot across nodes
#
# Why: Each node may have a metadata snapshot at a slightly different offset.
# The highest-offset snapshot is the most recent and therefore the most
# accurate representation of the cluster state at snapshot time.
#
for node_dir in <each node's __cluster_metadata-0>; do
  ls -1 "${node_dir}"/*.checkpoint 2>/dev/null
done
# Use the .checkpoint with the highest numeric offset in its filename

# 3. (Optional) Dump the snapshot to inspect its contents
#
# Why: Useful for verifying that the snapshot contains the expected topics,
# partitions, and broker registrations before proceeding. Not strictly
# required if you trust the snapshot is healthy.
#
kafka-dump-log.sh \
  --files <best_checkpoint_file> \
  --cluster-metadata-decoder \
  --deep-iteration \
  --print-data-log \
  > cluster-state.json

# 4. Verify meta.properties on each node
#
# Why: Confirms that node.id and cluster.id are consistent across all
# log directories on each node. If any directory has a mismatched node.id
# (which shouldn't happen on a healthy cluster), it must be corrected
# before startup or the broker will refuse to start.
#
for dir in <each log.dir on each node>; do
  echo "--- ${dir} ---"
  cat "${dir}/meta.properties"
done
```

### Phase 3: Surgical File Edits (minutes per node, parallelisable across nodes)

These edits prepare each node for startup in a 3-node configuration. Every operation has a specific reason — **do not skip any step**, and **do not perform operations not listed here** (particularly: do not touch partition data directories, `partition.metadata` files, checkpoint files, or log segment files).

On each of the 3 nodes:

```bash
METADATA_DIR="<path to __cluster_metadata-0>"
```

#### 3.1 Delete incremental Raft log segments

```bash
rm -f "${METADATA_DIR}"/*.log
rm -f "${METADATA_DIR}"/*.checkpoint.deleted
rm -f "${METADATA_DIR}"/*.checkpoint.part
```

**Why**: The `.log` files inside `__cluster_metadata-0/` are incremental KRaft Raft records written *after* the latest `.checkpoint` snapshot. They may contain `PartitionChangeRecord`, `FenceBrokerRecord`, or `UnfenceBrokerRecord` entries that reference all 9 original broker IDs. These records are inconsistent with a reduced 3-node cluster and cannot be safely replayed.

The `.checkpoint` snapshot is the complete, self-contained authoritative state of the cluster at a point in time. The incremental logs are only needed to advance beyond that point, which we don't need — we accept the snapshot's point-in-time state. The `.deleted` and `.part` files are cleanup artifacts that should also be removed.

#### 3.2 Delete `quorum-state`

```bash
rm -f "${METADATA_DIR}/quorum-state"
```

**Why**: The `quorum-state` file is a JSON file containing the Raft election state, including the voter set. The original file references all 9 broker IDs as voters. The Raft consensus protocol requires a majority (5 out of 9) to elect a leader. With only 3 nodes running, a majority can never be reached, and the cluster will hang in a permanent election deadlock — no requests can ever be served.

When `quorum-state` is absent, the Raft engine starts a fresh election using the voter set from `controller.quorum.voters` in `server.properties` (for static quorum) or from the `VotersRecord` in the metadata snapshot (for dynamic quorum). This is safe and is the cleanest recovery path.

#### 3.3 Place the best `.checkpoint` on all nodes

```bash
# If the highest-offset .checkpoint came from a different node than this one,
# copy it here (replacing any lower-offset checkpoint):
cp <best_checkpoint_file> "${METADATA_DIR}/"
```

**Why**: In a healthy cluster, all controller nodes should have nearly identical metadata snapshots. However, if one node was slightly ahead at snapshot time (more recent metadata operations committed), its snapshot will be more accurate. Using the same, most-recent snapshot on all 3 nodes ensures they start from identical cluster state, avoiding inconsistencies during quorum formation.

#### 3.4 Patch the existing broker config

Start from the broker's existing `server.properties` (or the GitOps-rendered equivalent for that node). **Do not replace it with a new minimal file.** Apply only the recovery-specific overrides below and leave all other required settings unchanged.

```properties
# Values that must be set for the recovery boot:
node.id=<original_broker_id>
controller.quorum.voters=A@host1:9093,B@host2:9093,C@host3:9093
log.dirs=<same paths as in original snapshot>
metadata.log.dir=<same path as in original snapshot>
file.delete.delay.ms=86400000
```

Preserve from the original config:
- `process.roles=broker,controller`
- Listener and network settings (`listeners`, `advertised.listeners`, `listener.security.protocol.map`, `inter.broker.listener.name`, `controller.listener.names`)
- Security/auth settings (TLS, SASL, authorizer, principal mapping, etc.)
- `rack.id`, performance tuning, logging, and any environment-specific operational settings

**Why for each notable setting:**

- **`node.id=<original_broker_id>`**: Must match the `node.id` in `meta.properties` on this node's disk, or the broker refuses to start with error `"Stored node id X doesn't match configured node id Y"`. Since we are keeping original IDs, this matches the snapshot data.

- **`controller.quorum.voters=A@host1:9093,...`**: Defines the 3-node voter set for KRaft leader election. This replaces the original 9-node voter set. Combined with the deleted `quorum-state`, this allows the 3 recovered nodes to elect a leader among themselves.

- **`log.dirs` and `metadata.log.dir`**: Must point to the same filesystem paths as the original broker's configuration. Since all nodes use identical infrastructure (DevOps/GitOps), the paths are the same. If the paths differ, Kafka cannot find the partition data directories.

- **`file.delete.delay.ms=86400000`** (24 hours): Kafka's stray detection renames partition directories to `-stray` and then permanently deletes them after this delay. The default is 60 seconds — an extremely tight window if anything goes wrong. Setting this to 24 hours gives a full day to detect and recover from any misconfiguration before data is permanently destroyed. This is the single most important safety net in the entire process.

- **Everything else should stay as-is from the source config**: The recovery boot still needs the cluster's real listener topology, security model, and operational settings. This is an overlay onto the existing config, not a fresh hand-written broker config.

`unclean.leader.election.enable` should remain at its normal value (`false`) in the baseline happy path. With the snapshot rewrite collapsing each in-scope partition to a single live replica and matching ISR, unclean election should not be needed. Treat it as an emergency-only override if startup unexpectedly leaves partitions offline and you consciously accept the extra data-loss risk.

#### 3.5 Verify `meta.properties`

```bash
for dir in <each log.dir>; do
  echo "--- ${dir}/meta.properties ---"
  grep -E "node.id|cluster.id|directory.id" "${dir}/meta.properties"
done
```

**Why**: This is a safety check, not a modification. Since we keep original broker IDs, `meta.properties` should already be correct. But a single incorrect file — for example, if a snapshot volume was accidentally mounted from the wrong broker — will cause either a startup crash (`node.id` mismatch) or silent data destruction (wrong `cluster.id` causes all partitions to be rejected). Verify before proceeding.

### Phase 4: Snapshot Rewrite

This is the key step that makes the recovery safe. Run the snapshot rewrite tool (see Section 4 for full background) against the best `.checkpoint` file.

#### Input

- The best `.checkpoint` file (identified in Phase 2)
- The set of surviving broker IDs: `{A, B, C}` (the 3 original IDs from the selected region)
- Directory mode: `UNASSIGNED` (eliminates directory.id tracking — see Section 4.3)

#### Processing Rules

**`PartitionRecord`** — the most critical transformation:

```
surviving = replicas[] ∩ {A, B, C}

if surviving is non-empty:
  replicas        = surviving
  isr             = surviving
  leader          = first of surviving (prefer original leader if in surviving set)
  leaderEpoch     = original + 1    ← signals a leadership change to clients
  partitionEpoch  = original + 1    ← invalidates stale cached metadata on clients
  directories     = [UNASSIGNED] × len(surviving)

if surviving is empty:
  → This means all 3 replicas of this partition were on brokers outside
    our region. For RF=3 with rack awareness, this should not happen.
    If it does, abort the rewrite and report the topic-partition(s).
    This is outside the baseline plan and indicates either an RF<3 topic,
    a rack-placement exception, or an unexpected snapshot mismatch.
```

**Why `leaderEpoch + 1` and `partitionEpoch + 1`**: Kafka clients and followers cache metadata including the leader epoch. Bumping these values forces them to refresh, preventing stale routing to brokers that no longer exist.

**`RegisterBrokerRecord`**:

```
Keep entries for brokers in {A, B, C} only.
Omit entries for the other 6 brokers entirely.
```

**Why**: Leaving `RegisterBrokerRecord` entries for missing brokers causes the controller to wait for them to heartbeat. They never will, so the controller eventually fences them (after ~9 seconds), which triggers ISR shrinkage across all their partitions — a cascade of `PartitionChangeRecord` writes that is unnecessary noise. Omitting them gives a cleaner startup.

**`VotersRecord`** (only present if Phase 2 found `data_version: 1`):

```
Replace voter set entries with {A, B, C}.
```

**Why**: In dynamic quorum mode (KIP-853, Kafka 3.7+), the voter set is stored inside the metadata snapshot, not in `server.properties`. If not rewritten, the cluster reads the original 9-node voter set from the snapshot and cannot form a majority.

**All other record types** (`TopicRecord`, `FeatureLevelRecord`, `ConfigRecord`, `ProducerIdsRecord`, `ClientQuotaRecord`, `AccessControlEntryRecord`, etc.):

```
Pass through unchanged.
```

#### Output

A valid `.checkpoint` file with the same offset-epoch filename as the input (drop-in replacement). Place it on all 3 nodes using that same basename:

```bash
CHECKPOINT_BASENAME="$(basename <best_checkpoint_file>)"

# On each node:
cp "<rewritten_dir>/${CHECKPOINT_BASENAME}" "${METADATA_DIR}/${CHECKPOINT_BASENAME}"
find "${METADATA_DIR}" -name "*.checkpoint" ! -name "${CHECKPOINT_BASENAME}" -delete
```

### Phase 5: Pre-Start Validation (do NOT skip)

Before starting any broker, programmatically verify the following. A single missed step can cause silent data destruction.

```bash
# 1. Every meta.properties has correct node.id and cluster.id
#    Why: Wrong node.id = startup crash; wrong cluster.id = all partitions rejected
for dir in <each log.dir on each node>; do
  grep -E "node.id|cluster.id" "${dir}/meta.properties"
done

# 2. quorum-state is ABSENT on all nodes
#    Why: If present with 9-node voter set → permanent election deadlock
for node in <each node>; do
  test ! -f "${node}/__cluster_metadata-0/quorum-state" && echo "OK: absent" || echo "FAIL: exists"
done

# 3. No stale .log segments in __cluster_metadata-0/
#    Why: Stale segments may replay 9-node records, overriding the rewritten snapshot
for node in <each node>; do
  ls "${node}/__cluster_metadata-0/"*.log 2>/dev/null && echo "FAIL: stale logs" || echo "OK: clean"
done

# 4. The rewritten .checkpoint exists on all nodes
#    Why: Without it, there is no cluster metadata at all — brokers start empty
for node in <each node>; do
  ls "${node}/__cluster_metadata-0/"*.checkpoint
done

# 5. Count partition directories — sanity check
#    Why: Gross mismatch indicates a snapshot mount error or wrong region
find <log.dirs> -maxdepth 1 -type d -name "*-*" | wc -l

# 6. file.delete.delay.ms is set to 86400000 in the recovery config
#    Why: This is the safety net — if anything is wrong, you have 24 hours to stop
#    brokers before data is permanently deleted
grep file.delete.delay.ms <recovery_server.properties>
```

### Phase 6: Start the Cluster

```bash
# Start all 3 nodes simultaneously (or as close together as possible):
kafka-server-start.sh <recovery_server.properties> &
```

**What happens at startup:**

1. Each broker loads `meta.properties` → validates `node.id` and `cluster.id`
2. Broker finds no `quorum-state` → starts fresh Raft election using `controller.quorum.voters`
3. 3 voters online → majority (2 of 3) achieved → leader elected within seconds
4. Leader loads the rewritten `.checkpoint` → cluster metadata shows only 3 brokers, all partitions assigned to them
5. Each broker scans partition directories → cross-references with metadata → `Replicas[]` includes this broker's ID → partitions load normally (no stray detection)
6. Partition log recovery runs: `.kafka_cleanshutdown` is absent (snapshot of a running cluster = unclean shutdown), so `LogLoader.recover()` reads all log segments, validates CRCs, truncates any corrupt tails from the snapshot boundary
7. ISR establishes → HWM (high watermark) advances → partitions become available for reads/writes

**Monitor:**

```bash
# Quorum health — expect 3 voters, 1 leader elected:
kafka-metadata-quorum.sh --bootstrap-controller host:9093 describe --status

# Offline partitions — expect 0 (snapshot rewrite assigned all RF=3 partitions):
kafka-topics.sh --bootstrap-server host:9092 --describe --unavailable-partitions

# Under-replicated partitions — in the steady-state recovered cluster this should
# be empty, because the rewrite collapses each in-scope partition to RF=1 with
# ISR matching Replicas. A brief startup transient is acceptable; a persistent
# result means the rewrite or broker registration state is wrong.
kafka-topics.sh --bootstrap-server host:9092 --describe --under-replicated-partitions

# Watch for stray detection (should NOT happen — indicates a rewrite or meta.properties error):
grep -i "stray" <broker-logs>/*.log
```

### Phase 7: Post-Start Stabilisation

```bash
# 1. Validate consumer group offsets
#
# Why: Consumer offsets are stored in __consumer_offsets, which was carried over
# from the snapshot. The coordinator uses hash(group.id) % num_partitions to
# find each group's offsets. Since we preserved the original topic (same UUID,
# same partition count), the mapping is intact. However, offsets may lag by
# up to a few seconds (the HWM checkpoint from the snapshot may be slightly
# stale). This self-resolves once ISR establishes and HWM catches up.
#
kafka-consumer-groups.sh --bootstrap-server host:9092 \
  --describe --group <group-name>

# 2. Reconcile recovery-only config overrides back to normal
#
# Why: file.delete.delay.ms=86400000 was injected specifically for first boot.
# Once the cluster is confirmed healthy, remove that override from the broker
# config source/overlay and roll brokers normally. If you explicitly enabled
# unclean leader election as an emergency override, remove that too.
#
# Example target end-state in the normal config:
#   file.delete.delay.ms=60000
#   unclean.leader.election.enable=false

# 3. Verify no stray directories exist
#
# Why: If any partition directories were renamed to -stray, it means the snapshot
# rewrite or meta.properties was incorrect for those partitions. Investigate
# before the deletion delay expires.
#
find <log.dirs> -maxdepth 1 -type d -name "*-stray" | head -20
```

---

## 6. Consumer Offsets Recovery

Consumer offsets deserve special attention because they determine where consumers resume reading.

**Why offsets are preserved with this approach**: The `__consumer_offsets` topic is an internal Kafka topic stored as regular partition data on disk. By keeping original broker IDs and the original metadata snapshot (with topic UUIDs intact), the `__consumer_offsets` topic is treated identically to any other topic — its partition data is loaded from the snapshot, and the coordinator rebuilds its in-memory state from the log.

The coordinator uses `hash(group.id) % num_partitions` to map each consumer group to a specific `__consumer_offsets` partition. Since we did not recreate the topic (same partition count, same data), this mapping is preserved exactly.

**What could go wrong:**

1. **Temporary HWM lag**: Until the `__consumer_offsets` ISR establishes and the HWM catches up from the snapshot's checkpoint value, some recently committed offsets may not be visible. This self-resolves within seconds of all brokers coming online.

2. **Out-of-scope topics**: If operators later choose to omit, drop, or re-create RF<3 topics separately, offset entries for those topics may still exist in `__consumer_offsets` and reference partitions that are no longer present. Consumers for those topics will get errors until offsets are reset or the groups are cleaned up.

**Validation:**

```bash
# Wait for __consumer_offsets HWM to stabilise before starting consumers:
kafka-run-class.sh kafka.tools.GetOffsetShell \
  --bootstrap-server host:9092 \
  --topic __consumer_offsets \
  --time -1

# Verify consumer groups:
kafka-consumer-groups.sh --bootstrap-server host:9092 --list
kafka-consumer-groups.sh --bootstrap-server host:9092 \
  --describe --group <each-group>
```

If offsets are incorrect, manually reset:
```bash
kafka-consumer-groups.sh --bootstrap-server host:9092 \
  --group <group> --reset-offsets --topic <topic> \
  --to-offset <offset> --execute
```

---

## 7. Multiple Log Directories

Production brokers may use multiple `log.dirs` (e.g., `log.dirs=/disk1/kafka,/disk2/kafka,/disk3/kafka`). Each directory has its own `meta.properties` with a unique `directory.id`, and Kafka distributes partitions across them.

**Why this is handled automatically with our approach:**

- Each log directory's `meta.properties` is already correct (same `node.id`, same `cluster.id`) because we keep original broker IDs
- The snapshot rewrite tool sets `directories[]` to `UNASSIGNED` for all partition replicas (see Section 4.3), which tells Kafka: "find this partition in any of the broker's `log.dirs`" — no directory-level validation occurs
- Kafka will locate each partition directory regardless of which physical disk it resides on

**Requirement**: `log.dirs` in `server.properties` must list the same paths as the original broker's configuration. Since all nodes use identical infrastructure (DevOps/GitOps), this is automatic.

---

## 8. Replication Factor After Recovery

After recovery, each partition has only the replicas that existed on the 3 selected brokers. For RF=3 topics with rack awareness, this means **RF=1 in practice** — each partition has exactly one live replica.

This is an intentional metadata collapse, not an "RF=3 but two replicas are missing" situation. In the recovered steady state, `Replicas` and `ISR` should both contain that single live replica, so `--under-replicated-partitions` should normally be empty. Under-replication reappears only when you later expand replication via reassignment.

**Options for expanding:**

| Option | Effective RF | Disk Impact | Notes |
|---|---|---|---|
| **Stay at RF=1** | 1 | No additional disk | Simplest; no redundancy; acceptable for test/DR environments |
| **Expand to RF=2** | 2 | ~2x disk per broker | Kafka handles via partition reassignment |
| **Expand to RF=3** | 3 | ~3x disk per broker | Every broker holds a full copy of all data |

To expand:
```bash
kafka-reassign-partitions.sh --bootstrap-server host:9092 \
  --topics-to-move-json-file topics.json \
  --broker-list "A,B,C" \
  --generate

kafka-reassign-partitions.sh --bootstrap-server host:9092 \
  --reassignment-json-file plan.json \
  --execute
```

**Disk space**: With 3 brokers and RF=3, every broker needs disk capacity equal to the total data volume. Verify capacity before expanding.

---

## 9. Compacted Topics

Topics with `cleanup.policy=compact` will experience a full re-compaction cycle after migration because the log cleaner's in-memory state (compaction checkpoints, cleaner offsets) is not persisted in a way that survives this type of recovery.

**Impact:**
- Temporary ~2x disk usage during re-compaction
- Higher I/O during the compaction pass
- Latest-per-key values are preserved (they exist in the log segments on disk)

**Action**: No special handling needed. Budget disk space for the temporary compaction overhead.

---

## 10. Transaction Recovery

Kafka transactions have well-defined recovery semantics that apply after snapshot restoration:

- **ONGOING transactions** (in-progress at snapshot time): The transaction coordinator auto-aborts these after `transaction.timeout.ms` expires (default 60 seconds). No manual intervention needed.

- **PREPARE_COMMIT transactions** (commit decided but not all partitions notified): The coordinator self-heals by re-sending COMMIT markers to all participating partitions. Automatic.

- **Failed-to-abort transactions**: Handled by existing operational runbooks for transaction recovery. As long as the transaction can be cancelled and a new one started, recovery proceeds normally.

**Producer reconnection**: Producers connecting to the recovered cluster must call `initTransactions()` to bump their producer epoch and reset sequence tracking. Without this, the broker will reject messages with `OutOfOrderSequenceException` because the producer's sequence numbers don't match the state recovered from the snapshot's producer state files (`.snapshot`).

---

## 11. Checklist Summary

### After Snapshot Mount, Before Edits
- [ ] Check `quorum-state` for `data_version` (0 = static quorum, 1 = dynamic quorum requiring VotersRecord rewrite)
- [ ] Identify the highest-offset `.checkpoint` across all 3 nodes
- [ ] Verify `meta.properties` on every log directory on every node

### Surgical Edits (Phase 3)
- [ ] Delete all `.log`, `.checkpoint.deleted`, `.checkpoint.part` in `__cluster_metadata-0/` on all nodes
- [ ] Delete `quorum-state` on all nodes
- [ ] Place best `.checkpoint` on all nodes (identical copy)
- [ ] Patch the existing broker config / recovery overlay with original broker IDs, 3-node voter set, and `file.delete.delay.ms=86400000`

### Snapshot Rewrite (Phase 4)
- [ ] Run snapshot rewrite tool with surviving broker IDs and UNASSIGNED directory mode
- [ ] Place rewritten `.checkpoint` on all nodes, removing original

### Pre-Start Validation (Phase 5)
- [ ] Confirm `meta.properties` node.id and cluster.id on all directories
- [ ] Confirm `quorum-state` absent on all nodes
- [ ] Confirm no `.log` files in `__cluster_metadata-0/`
- [ ] Confirm rewritten `.checkpoint` present on all nodes
- [ ] Sanity-check partition directory count
- [ ] Confirm `file.delete.delay.ms=86400000` in the recovery config

### After Start (Phases 6-7)
- [ ] Quorum formed: 3 voters, 1 leader
- [ ] 0 offline partitions
- [ ] `--under-replicated-partitions` is empty after startup settles
- [ ] No `-stray` directories in logs
- [ ] Consumer group offsets validated
- [ ] Recovery-only config overrides removed from the normal broker config path after validation

---

## 12. Risk Summary

| Risk | Severity | Mitigation |
|---|---|---|
| Stray detection deletes all partition data | **Critical** | Keep original broker IDs, rewrite `Replicas[]` to match the recovered brokers, and use `file.delete.delay.ms=24h` as a safety net |
| Topic UUID mismatch takes entire disk offline | **Critical** | Original metadata snapshot preserved → `TopicRecord` UUIDs match `partition.metadata` files; no changes to partition directories |
| 9-node quorum deadlock prevents startup | **High** | `quorum-state` deleted; `controller.quorum.voters` set to 3 nodes; VotersRecord rewritten if dynamic quorum |
| Consumer offset drift after recovery | **Medium** | Wait for `__consumer_offsets` HWM to stabilise before starting consumers; manual reset available |
| Segment tail corruption from live snapshot | **Low** | `LogLoader.recover()` detects and truncates corrupt tails automatically; expected and handled |
| Compaction disk spike | **Low** | Budget ~2x disk for compacted topics during re-compaction cycle |

---

## 13. Test Scenarios

This section defines the scenarios that a test harness must cover to prove the recovery process works in practice. Each scenario starts from the same baseline: a healthy 9-node source cluster (3 regions × 3 brokers, rack-aware, KRaft mode), from which one region's 3 brokers are copied to a new location and recovered as a standalone 3-node cluster.

The scenarios are ordered so that each builds confidence incrementally — early scenarios validate foundational mechanics, later scenarios validate production-realistic conditions. The intent is to define **what to test and what to verify**, so that the team can later choose implementation technology and build automation on top of these definitions.

### Test Baseline Setup

Every scenario begins with this shared source cluster:

```
Source cluster:
  - 9 brokers: IDs 0-8
  - 3 regions: Region A (brokers 0,1,2), Region B (brokers 3,4,5), Region C (brokers 6,7,8)
  - rack.id configured per region (e.g., rack-a, rack-b, rack-c)
  - KRaft combined mode (all nodes are both brokers and controllers)
  - controller.quorum.voters lists all 9 nodes

Recovery target:
  - 3 new nodes
  - Receive full disk copies from Region A (brokers 0, 1, 2)
  - Will run as node.id=0, node.id=1, node.id=2 (original IDs)
```

The source cluster is started, populated with data, then **stopped cleanly** (to eliminate snapshot-timing variables in early scenarios). Later scenarios introduce live snapshots.

---

### Scenario 1: Quorum Formation and Metadata Loading

**What this tests**: The most fundamental question — can 3 nodes form a KRaft quorum and load the rewritten metadata snapshot? This validates Phases 3 and 4 of the recovery process in isolation, before any partition data complexity.

**Source cluster setup**:
- 1 topic, 1 partition, RF=3 (minimal data)
- Stop cluster cleanly

**Recovery steps**:
1. Copy Region A broker disks to target nodes
2. Execute Phase 3 surgical edits (delete `quorum-state`, delete `*.log` in metadata dir)
3. Execute Phase 4 snapshot rewrite (3 surviving brokers)
4. Patch the broker config / recovery overlay with the 3-node voter set
5. Start all 3 nodes

**What to verify**:

```bash
# Quorum formed with exactly 3 voters, 1 leader
kafka-metadata-quorum.sh --bootstrap-controller host:9093 describe --status
# Assert: LeaderId is one of {0,1,2}, voters = 3, observers = 0

# The metadata contains only 3 registered brokers (not 9)
kafka-dump-log.sh \
  --files <metadata_dir>/__cluster_metadata-0/*.checkpoint \
  --cluster-metadata-decoder --print-data-log \
  | grep RegisterBrokerRecord
# Assert: exactly 3 entries, for broker IDs 0, 1, 2

# The single topic's partition is online and has a leader
kafka-topics.sh --bootstrap-server host:9092 --describe --topic test-topic
# Assert: partition 0 has leader in {0,1,2}, replicas = [one of 0,1,2], ISR non-empty
```

**Success criteria**: Quorum elects a leader within 30 seconds. The topic's single partition comes online. No errors in broker logs related to quorum, metadata loading, or stray detection.

---

### Scenario 2: Partition Data Integrity Across All Brokers

**What this tests**: That partition data files survive the copy and recovery intact — messages are readable, offsets are correct, and data is consistent across a meaningful number of partitions distributed across all 3 brokers.

**Source cluster setup**:
- 3 topics: `topic-a` (12 partitions), `topic-b` (6 partitions), `topic-c` (24 partitions)
- All RF=3
- Produce a known number of messages to each partition (e.g., 10,000 per partition)
- Record the exact message count and latest offset per partition before stopping
- Stop cluster cleanly

**Recovery steps**:
1. Full recovery process (Phases 1-6)

**What to verify**:

```bash
# All topics exist with correct partition counts
kafka-topics.sh --bootstrap-server host:9092 --list
kafka-topics.sh --bootstrap-server host:9092 --describe --topic topic-a
kafka-topics.sh --bootstrap-server host:9092 --describe --topic topic-b
kafka-topics.sh --bootstrap-server host:9092 --describe --topic topic-c
# Assert: partition counts match source (12, 6, 24)

# All partitions are online
kafka-topics.sh --bootstrap-server host:9092 --describe --unavailable-partitions
# Assert: empty output

# Message counts match (within tolerance)
for topic in topic-a topic-b topic-c; do
  kafka-run-class.sh kafka.tools.GetOffsetShell \
    --bootstrap-server host:9092 \
    --topic ${topic} --time -1
done
# Assert: each partition's latest offset matches the recorded value from the source

# Data is actually readable (consume and count)
kafka-console-consumer.sh --bootstrap-server host:9092 \
  --topic topic-a --partition 0 --from-beginning --timeout-ms 10000 \
  | wc -l
# Assert: matches expected message count for that partition
```

**Success criteria**: Every partition has the expected message count. Data is readable end-to-end. No CRC errors in broker logs (since this is a clean-shutdown snapshot).

---

### Scenario 3: Stray Detection Safety Net

**What this tests**: That the `file.delete.delay.ms=86400000` safety window works as intended, and that stray detection does NOT fire for correctly configured partitions. This also validates the real negative case for stray detection: metadata/broker identity disagreement.

**Source cluster setup**:
- 3 topics, 6 partitions each, RF=3
- Stop cluster cleanly

**Recovery steps — positive case** (everything correct):
1. Full recovery process
2. Start cluster

**What to verify (positive case)**:

```bash
# No stray directories created
find <log.dirs> -maxdepth 1 -type d -name "*-stray" | wc -l
# Assert: 0

# No stray-related log messages
grep -c "stray" <broker-logs>/*.log
# Assert: 0
```

**Recovery steps — negative case** (deliberately break one thing):
1. Full recovery process, including a correct snapshot rewrite
2. Before startup, intentionally mutate the rewritten snapshot in the test harness so that a known partition stored on broker 2 no longer lists broker 2 in `Replicas[]`
3. Start cluster with `file.delete.delay.ms=86400000`

Not running the snapshot rewrite at all is a different failure mode: with original broker IDs preserved, it primarily leaves 9-node assignments and availability problems. It is **not** the cleanest way to test stray detection specifically.

**What to verify (negative case)**:

```bash
# Stray directories ARE created for the deliberately mis-described partition(s),
# because the rewritten metadata no longer lists the on-disk broker in Replicas[]
find <log.dirs> -maxdepth 1 -type d -name "*-stray" | wc -l
# Assert: > 0 (the injected fault caused stray detection)

# But data is NOT yet deleted (within 24h window)
ls <log.dirs>/*-stray/
# Assert: partition data files still exist inside stray directories

# Recovery: stop brokers, replace the mutated snapshot with the correct
# rewritten snapshot, rename -stray dirs back
# to original names, restart
for dir in $(find <log.dirs> -maxdepth 1 -type d -name "*-stray"); do
  original="${dir%-stray}"
  mv "${dir}" "${original}"
done
```

**Success criteria**: Positive case produces zero stray directories. Negative case demonstrates that the 24h window prevents data loss and allows recovery.

---

### Scenario 4: Consumer Group Offset Continuity

**What this tests**: That consumer group offsets survive the recovery and consumers resume from the correct position — not from the beginning of the topic, and not past the end of available data.

**Source cluster setup**:
- 1 topic, 12 partitions, RF=3
- Produce 10,000 messages per partition
- Run a consumer group `test-group` that consumes roughly half the messages (stop at ~5,000 per partition)
- Record committed offsets per partition: `kafka-consumer-groups.sh --describe --group test-group`
- Stop cluster cleanly

**Recovery steps**:
1. Full recovery process

**What to verify**:

```bash
# Consumer group exists and has committed offsets
kafka-consumer-groups.sh --bootstrap-server host:9092 \
  --describe --group test-group
# Assert: group exists, has entries for all 12 partitions

# Committed offsets match source (within small tolerance)
# For each partition:
#   source_offset - recovered_offset <= 5 seconds worth of commits
#   recovered_offset > 0 (not reset to beginning)
#   recovered_offset <= source_offset (never ahead of source)

# Consumer resumes from committed offset, not from beginning
kafka-console-consumer.sh --bootstrap-server host:9092 \
  --topic test-topic --group test-group --timeout-ms 10000 \
  | wc -l
# Assert: roughly 5,000 messages per partition (the unconsumed half), not 10,000
```

**Success criteria**: Consumer group resumes from the committed offset. No messages are re-processed from the beginning. The offset drift is at most a few seconds of commit lag.

---

### Scenario 5: Topic Configuration Preservation

**What this tests**: That topic-level and broker-level configurations stored in the KRaft metadata survive the snapshot rewrite unchanged.

**Source cluster setup**:
- Create topics with non-default configurations:
  - `topic-retention`: `retention.ms=3600000` (1 hour), `retention.bytes=1073741824` (1 GB)
  - `topic-compact`: `cleanup.policy=compact`, `min.cleanable.dirty.ratio=0.1`
  - `topic-compressed`: `compression.type=zstd`, `max.message.bytes=10485760` (10 MB)
  - `topic-default`: no overrides (uses cluster defaults)
- Set a broker-level config override: e.g., `log.retention.hours=48` on broker 0
- Stop cluster cleanly

**Recovery steps**:
1. Full recovery process

**What to verify**:

```bash
# Topic-level configs preserved
kafka-configs.sh --bootstrap-server host:9092 \
  --describe --entity-type topics --entity-name topic-retention
# Assert: retention.ms=3600000, retention.bytes=1073741824

kafka-configs.sh --bootstrap-server host:9092 \
  --describe --entity-type topics --entity-name topic-compact
# Assert: cleanup.policy=compact, min.cleanable.dirty.ratio=0.1

kafka-configs.sh --bootstrap-server host:9092 \
  --describe --entity-type topics --entity-name topic-compressed
# Assert: compression.type=zstd, max.message.bytes=10485760

# Broker-level config overrides preserved
kafka-configs.sh --bootstrap-server host:9092 \
  --describe --entity-type brokers --entity-name 0
# Assert: log.retention.hours=48

# Default topic has no overrides
kafka-configs.sh --bootstrap-server host:9092 \
  --describe --entity-type topics --entity-name topic-default
# Assert: no dynamic configs (empty or defaults only)
```

**Success criteria**: All topic and broker configuration overrides match the source cluster exactly. The snapshot rewrite's pass-through of `ConfigRecord` entries is verified.

---

### Scenario 6: Compacted Topic Recovery

**What this tests**: That compacted topics recover correctly — latest-per-key values are preserved, and the log cleaner completes re-compaction without errors or data corruption.

**Source cluster setup**:
- 1 compacted topic (`cleanup.policy=compact`), 6 partitions, RF=3
- Produce messages with known keys: keys `K0` through `K999`, each written 10 times with incrementing values (`K0=v0`, `K0=v1`, ..., `K0=v9`)
- Allow the source cluster's log cleaner to run (so segments are already compacted)
- Record the latest value for each key
- Stop cluster cleanly

**Recovery steps**:
1. Full recovery process
2. Wait for the log cleaner to complete a full cycle on the recovered cluster

**What to verify**:

```bash
# Topic is online and configured as compacted
kafka-topics.sh --bootstrap-server host:9092 --describe --topic compact-test
kafka-configs.sh --bootstrap-server host:9092 \
  --describe --entity-type topics --entity-name compact-test
# Assert: cleanup.policy=compact

# Latest-per-key values are correct (consume entire topic, check last value per key)
kafka-console-consumer.sh --bootstrap-server host:9092 \
  --topic compact-test --from-beginning --timeout-ms 30000 \
  --property print.key=true
# Assert: for each key K0-K999, the most recent value matches the source

# Log cleaner completes without errors
grep -i "cleaner" <broker-logs>/*.log | grep -i "error"
# Assert: no cleaner errors

# Disk usage stabilises after re-compaction (not growing unbounded)
du -sh <log.dirs>/compact-test-*/
# Assert: size is reasonable (not 2x+ of expected)
```

**Success criteria**: All latest-per-key values match the source. Log cleaner completes without errors. Disk usage returns to expected levels after re-compaction.

---

### Scenario 7: Transaction State Recovery

**What this tests**: That the `__transaction_state` topic survives recovery, ongoing transactions are resolved, and new transactional producers can operate correctly.

**Source cluster setup**:
- 1 topic, 6 partitions, RF=3
- Transactional producer `txn-producer-1`: produce 1,000 committed transactions (each writing 10 messages)
- Transactional producer `txn-producer-2`: begin a transaction, write 10 messages, do NOT commit (leave ONGOING)
- Record state: `kafka-transactions.sh list`
- Stop cluster cleanly

**Recovery steps**:
1. Full recovery process
2. Start cluster
3. Wait `transaction.timeout.ms` (default 60s) for ongoing transactions to resolve

**What to verify**:

```bash
# __transaction_state topic is online
kafka-topics.sh --bootstrap-server host:9092 --describe --topic __transaction_state
# Assert: all partitions online

# After timeout, no ONGOING transactions remain
kafka-transactions.sh --bootstrap-server host:9092 list
# Assert: txn-producer-2 is no longer ONGOING (either ABORTED or absent)

# Committed transaction data is readable
kafka-console-consumer.sh --bootstrap-server host:9092 \
  --topic test-topic --from-beginning --timeout-ms 10000 \
  --isolation-level read_committed \
  | wc -l
# Assert: 10,000 messages (1,000 transactions × 10 messages from txn-producer-1)
# The 10 uncommitted messages from txn-producer-2 should NOT appear

# New transactional producer can start successfully
# (programmatic test: call initTransactions(), produce, commit)
# Assert: no OutOfOrderSequenceException, no ProducerFencedException
```

**Success criteria**: Committed transaction data is fully readable. Uncommitted transactions are aborted within the timeout. New transactional producers can operate without sequence errors.

---

### Scenario 8: Multiple Log Directories

**What this tests**: That the recovery works when brokers use multiple `log.dirs` — partitions are distributed across disks, and the `UNASSIGNED` directory mode in the snapshot rewrite allows Kafka to find them all.

**Source cluster setup**:
- Configure all brokers with `log.dirs=/disk1/kafka,/disk2/kafka` (2 directories per broker)
- 2 topics, 24 partitions each, RF=3 (partitions will be spread across both directories)
- Produce 5,000 messages per partition
- Stop cluster cleanly

**Recovery steps**:
1. Copy both disk volumes from each source broker to the corresponding target node
2. Full recovery process (snapshot rewrite uses `UNASSIGNED` for all directory references)
3. `server.properties` must list both paths: `log.dirs=/disk1/kafka,/disk2/kafka`

**What to verify**:

```bash
# Partitions are distributed across both directories
ls /disk1/kafka/ | grep -c "topic-"
ls /disk2/kafka/ | grep -c "topic-"
# Assert: both directories contain partition subdirectories (not all on one disk)

# All partitions online despite being on different disks
kafka-topics.sh --bootstrap-server host:9092 --describe --unavailable-partitions
# Assert: empty output

# meta.properties in BOTH directories has correct node.id and cluster.id
cat /disk1/kafka/meta.properties
cat /disk2/kafka/meta.properties
# Assert: both have same node.id, same cluster.id, different directory.id

# Data integrity: message counts match source
for topic in topic-a topic-b; do
  kafka-run-class.sh kafka.tools.GetOffsetShell \
    --bootstrap-server host:9092 \
    --topic ${topic} --time -1
done
# Assert: all partitions have expected offsets
```

**Success criteria**: All partitions across both directories are online. No stray detection on either directory. Message counts match.

---

### Scenario 9: Live Snapshot Recovery (Non-Quiesced Source)

**What this tests**: The realistic scenario — snapshots taken from a running cluster with active writes. Validates that `LogLoader.recover()` handles corrupt segment tails and that data loss is bounded.

**Source cluster setup**:
- 1 topic, 12 partitions, RF=3
- Producer: writing continuously at ~1,000 messages/second
- Consumer: reading with `READ_COMMITTED`
- Record the last acknowledged offset per partition at the moment snapshots are taken
- Take disk snapshots of Region A brokers **without stopping the cluster**
  - Introduce small delays between snapshots (2-5 seconds) to simulate real sequential snapshots
- Then stop the source cluster

**Recovery steps**:
1. Full recovery process from the live snapshots

**What to verify**:

```bash
# All partitions come online
kafka-topics.sh --bootstrap-server host:9092 --describe --unavailable-partitions
# Assert: empty output

# Check for expected segment recovery (corrupt tail truncation)
grep -i "Recovering unflushed segment" <broker-logs>/*.log
grep -i "truncat" <broker-logs>/*.log
# Assert: some truncation messages are present (expected from live snapshot)
# Assert: no fatal errors

# Measure data loss
for p in $(seq 0 11); do
  kafka-run-class.sh kafka.tools.GetOffsetShell \
    --bootstrap-server host:9092 \
    --topic test-topic --partitions ${p} --time -1
done
# Compare each partition's recovered LEO against the recorded last-ack offset
# Assert: recovered_LEO >= last_ack - (write_rate × snapshot_delta_seconds)
# (data loss bounded by the snapshot timing window)

# No stray directories
find <log.dirs> -maxdepth 1 -type d -name "*-stray" | wc -l
# Assert: 0
```

**Success criteria**: All partitions online. Data loss bounded by the snapshot timing window (a few seconds of writes). Segment recovery completes without fatal errors. No stray detection.

---

### Scenario 10: RF=1 Steady State and Replica Expansion

**What this tests**: After recovery, all partitions start as RF=1 (one live replica per partition from the snapshot rewrite). This scenario verifies the intended steady state: `Replicas` and `ISR` both collapse to that single live replica, and later replica expansion via reassignment works cleanly.

**Source cluster setup**:
- 3 topics, 12 partitions each, RF=3
- Produce 5,000 messages per partition
- Stop cluster cleanly

**Recovery steps**:
1. Full recovery process

**What to verify**:

```bash
# In the recovered steady state: partitions are online and NOT under-replicated,
# because metadata now says each partition has exactly 1 replica and 1 ISR member
kafka-topics.sh --bootstrap-server host:9092 --describe --under-replicated-partitions
# Assert: empty output after startup settles

# After stabilisation: ISR matches the replica set for each partition
kafka-topics.sh --bootstrap-server host:9092 --describe --topic topic-a
# Assert: for each partition, Replicas has length 1 and ISR = Replicas

# Verify that partition reassignment works for expanding RF
cat > expand.json << 'EXPAND'
{"version":1, "partitions":[
  {"topic":"topic-a","partition":0,"replicas":[0,1,2]}
]}
EXPAND
kafka-reassign-partitions.sh --bootstrap-server host:9092 \
  --reassignment-json-file expand.json --execute
kafka-reassign-partitions.sh --bootstrap-server host:9092 \
  --reassignment-json-file expand.json --verify
# Assert: reassignment completes; under-replication may appear temporarily during copy

# After reassignment: partition is fully replicated on all 3 brokers
kafka-topics.sh --bootstrap-server host:9092 --describe --topic topic-a
# Assert: partition 0 has Replicas=[0,1,2], ISR=[0,1,2]
```

**Success criteria**: The recovered RF=1 steady state has `ISR = Replicas` for all partitions and no persistent under-replication. Partition reassignment works for expanding RF. No data loss during reassignment.

---

### Scenario 11: End-to-End Automation Dry Run

**What this tests**: The full recovery process executed as a single scripted sequence — no manual intervention. This is the scenario that proves the process is automatable. It combines all previous scenarios' setup into one realistic cluster and runs every phase in order.

**Source cluster setup**:
- 10 topics with varied configurations:
  - 3 retention-based topics (varied partition counts: 6, 12, 24)
  - 2 compacted topics (6 partitions each)
  - 1 topic with `compression.type=zstd`
  - 1 topic with short retention (`retention.ms=3600000`)
  - 3 default-config topics
- All RF=3
- Multiple consumer groups (3 groups, each consuming different topics)
- 1 transactional producer with committed transactions
- `log.dirs` with 2 directories per broker
- Total data: enough to exercise disk I/O (e.g., 10 GB)
- Cluster running (live snapshots)

**Recovery steps** (all scripted, no manual steps):

```bash
#!/bin/bash
set -euo pipefail

# --- Phase 1: Mount ---
# (assumes snapshots already mounted at known paths)

# --- Phase 2: Analyse ---
BEST_CHECKPOINT=$(ls -1 ${NODE0_META}/__cluster_metadata-0/*.checkpoint \
                       ${NODE1_META}/__cluster_metadata-0/*.checkpoint \
                       ${NODE2_META}/__cluster_metadata-0/*.checkpoint \
                  | sort -V | tail -1)
CHECKPOINT_BASENAME=$(basename "${BEST_CHECKPOINT}")
REWRITTEN_CHECKPOINT="${PWD}/${CHECKPOINT_BASENAME}"

QUORUM_MODE=$(cat ${NODE0_META}/__cluster_metadata-0/quorum-state \
              | python3 -c "import sys,json; print(json.load(sys.stdin).get('data_version',0))")

# --- Phase 3: Surgical edits (parallelisable across nodes) ---
for NODE_META in ${NODE0_META} ${NODE1_META} ${NODE2_META}; do
  rm -f "${NODE_META}/__cluster_metadata-0/"*.log
  rm -f "${NODE_META}/__cluster_metadata-0/"*.checkpoint.deleted
  rm -f "${NODE_META}/__cluster_metadata-0/"*.checkpoint.part
  rm -f "${NODE_META}/__cluster_metadata-0/quorum-state"
  cp "${BEST_CHECKPOINT}" "${NODE_META}/__cluster_metadata-0/"
done

# --- Phase 3b: Render recovery broker configs from the existing config baseline ---
# The helper below is intentionally an overlay step: it starts from each broker's
# normal config and applies only the recovery-specific overrides.
for NODE in 0 1 2; do
  render_recovery_server_properties \
    --base "/configs/node${NODE}/server.properties" \
    --output "/recovery/node${NODE}/server.properties" \
    --node-id "${NODE}" \
    --controller-voters "0@node0:9093,1@node1:9093,2@node2:9093" \
    --file-delete-delay-ms 86400000
done

# --- Phase 4: Snapshot rewrite ---
snapshot-rewrite-tool \
  --input "${BEST_CHECKPOINT}" \
  --output "${REWRITTEN_CHECKPOINT}" \
  --surviving-brokers "0,1,2" \
  --directory-mode UNASSIGNED \
  $([ "${QUORUM_MODE}" = "1" ] && echo "--rewrite-voters")

for NODE_META in ${NODE0_META} ${NODE1_META} ${NODE2_META}; do
  cp "${REWRITTEN_CHECKPOINT}" "${NODE_META}/__cluster_metadata-0/${CHECKPOINT_BASENAME}"
  find "${NODE_META}/__cluster_metadata-0/" -name "*.checkpoint" \
    ! -name "${CHECKPOINT_BASENAME}" -delete
done

# --- Phase 5: Pre-start validation ---
ERRORS=0
for NODE in 0 1 2; do
  for DIR in <log_dirs_for_node_$NODE>; do
    NODE_ID=$(grep "node.id=" "${DIR}/meta.properties" | cut -d= -f2)
    [ "${NODE_ID}" = "${NODE}" ] || { echo "FAIL: node.id mismatch in ${DIR}"; ERRORS=$((ERRORS+1)); }
  done
  META_DIR=<metadata_dir_for_node_$NODE>/__cluster_metadata-0
  [ ! -f "${META_DIR}/quorum-state" ] || { echo "FAIL: quorum-state exists"; ERRORS=$((ERRORS+1)); }
  ls "${META_DIR}"/*.log 2>/dev/null && { echo "FAIL: stale logs"; ERRORS=$((ERRORS+1)); }
  ls "${META_DIR}"/*.checkpoint >/dev/null 2>&1 || { echo "FAIL: no checkpoint"; ERRORS=$((ERRORS+1)); }
done
[ ${ERRORS} -eq 0 ] || { echo "Pre-start validation failed"; exit 1; }

# --- Phase 6: Start ---
for NODE in 0 1 2; do
  ssh node${NODE} "kafka-server-start.sh /recovery/node${NODE}/server.properties &"
done

# --- Phase 7: Post-start validation ---
# Wait for quorum
TIMEOUT=60
while [ $TIMEOUT -gt 0 ]; do
  kafka-metadata-quorum.sh --bootstrap-controller host:9093 describe --status 2>/dev/null && break
  sleep 2; TIMEOUT=$((TIMEOUT-2))
done

# Check offline partitions
OFFLINE=$(kafka-topics.sh --bootstrap-server host:9092 \
  --describe --unavailable-partitions 2>/dev/null | wc -l)
echo "Offline partitions: ${OFFLINE}"

# Check stray directories
STRAYS=$(find <all_log_dirs> -maxdepth 1 -type d -name "*-stray" | wc -l)
echo "Stray directories: ${STRAYS}"

# Check consumer groups
kafka-consumer-groups.sh --bootstrap-server host:9092 --list

# Reconcile the temporary recovery config overlay back to the normal broker config
# path after validation. This is a config-management step, not a fresh hand-written
# replacement.
```

**What to verify**:

```bash
# All assertions from Scenarios 1-10 apply:
# - Quorum formed with 3 voters
# - 0 offline partitions
# - 0 stray directories
# - Message counts match source for all topics
# - Consumer group offsets match source
# - Topic configs preserved
# - Compacted topic data correct
# - Transactions resolved
# - Both log directories functional
# - No persistent under-replicated partitions in the recovered RF=1 steady state

# Additionally: measure total recovery time
echo "Recovery completed in ${SECONDS} seconds"
```

**Success criteria**: The entire process completes without manual intervention. All assertions pass. Recovery time is measured and recorded as a baseline for future runs.

---

### Scenario 12: Repeatability — Same Snapshots, Multiple Recoveries

**What this tests**: That the recovery process is deterministic — given the same input snapshots, running the full process twice produces identical results. This is essential for automation confidence.

**Source**: Archived snapshots from any previous scenario.

**Recovery steps**:
1. Run 1: full recovery process → record all metrics (message counts, offsets, configs, partition assignments)
2. Destroy target cluster (wipe all data)
3. Run 2: full recovery process from the same archived snapshots → record same metrics

**What to verify**:

```bash
# Compare Run 1 vs Run 2 outputs:
diff run1-topic-describe.txt run2-topic-describe.txt
diff run1-consumer-groups.txt run2-consumer-groups.txt
diff run1-offsets.txt run2-offsets.txt
diff run1-configs.txt run2-configs.txt

# Assert: identical output (or document any expected non-determinism, e.g., leader
# assignment order may vary, but partition data and offsets must match exactly)
```

**Success criteria**: Message counts, consumer group offsets, and topic configurations are identical between runs. Any non-deterministic aspects (e.g., which broker becomes leader for a given partition) are documented and do not affect data correctness.

---

### Scenario Execution Order

The scenarios are designed to be run in order, with each building on the confidence established by the previous:

| Phase | Scenarios | What it proves |
|---|---|---|
| **Foundation** | 1, 2 | Quorum works, data survives the copy |
| **Safety mechanisms** | 3 | Stray detection safety net functions correctly |
| **State preservation** | 4, 5, 6, 7 | Consumer offsets, configs, compacted data, transactions all survive |
| **Infrastructure** | 8 | Multiple disk directories handled correctly |
| **Realistic conditions** | 9, 10 | Live snapshots, ISR re-establishment, RF expansion |
| **Automation readiness** | 11, 12 | Full scripted run, repeatability confirmed |

Each scenario should be independently runnable (for debugging) but the recommended first pass is sequential. Once all scenarios pass individually, Scenario 11 serves as the integration test that combines them all.
