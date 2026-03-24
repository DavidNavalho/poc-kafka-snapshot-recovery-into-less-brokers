# Kafka 9-Node → 3-Node Snapshot Migration: Architecture Decision Record

## Executive Summary

This ADR addresses the feasibility and methodology of taking a disk snapshot of a running 9-node production Kafka cluster and migrating that data into a fresh 3-node test environment. The target cluster must be **fully live**: producers and consumers should run against it. The source cluster uses RF=3 topics across 9 brokers with KRaft mode. The target uses fresh node IDs (0, 1, 2) and some data loss is acceptable.

This is a non-trivial operation because Kafka's data is split across two fundamentally different layers: the **KRaft metadata layer** (which describes the cluster topology, partition assignments, and broker identities) and the **partition data layer** (the actual log files). These two layers use different file formats, different identifiers, and different recovery mechanisms. Migrating between cluster sizes requires reconciling both layers from scratch.

The ADR is structured as: feasibility analysis → what survives vs. what must be rebuilt → three concrete strategies → a step-by-step migration playbook → failure mode catalogue → test harness designs.

---

# PART 1: FEASIBILITY ANALYSIS

## The Core Question: Can We Actually Do This?

**Short answer: Yes, with careful disk selection and a well-defined process.**

### RF=3 on 9 Nodes — The Mathematics

In a 9-node Kafka cluster with RF=3, each partition has exactly 3 replicas spread across 3 different brokers. Kafka's `StripedReplicaPlacer` distributes replicas using a deterministic striping algorithm to achieve rack-awareness and balance.

For a topic with N partitions:

```
Partition 0:  replicas = [broker_0, broker_3, broker_6]
Partition 1:  replicas = [broker_1, broker_4, broker_7]
Partition 2:  replicas = [broker_2, broker_5, broker_8]
Partition 3:  replicas = [broker_3, broker_6, broker_0]  ← wraps around
Partition 4:  replicas = [broker_4, broker_7, broker_1]
...
```

The striping pattern means that **no two consecutive partitions share the same replica set**. For a cluster with many partitions (typical production: hundreds or thousands), every broker participates in roughly N/3 partitions as a replica.

### The Disk Selection Problem

If we take only 3 disks from the 9-node cluster, we get the data from 3 brokers. The question is: how much partition data is recoverable?

**Worst case (3 consecutive brokers, e.g., 0, 1, 2):**

```
Partition 0: [0, 3, 6] → 1 replica available (broker 0)  ✓
Partition 1: [1, 4, 7] → 1 replica available (broker 1)  ✓
Partition 2: [2, 5, 8] → 1 replica available (broker 2)  ✓
Partition 3: [3, 6, 0] → 1 replica available (broker 0)  ✓
Partition 4: [4, 7, 1] → 1 replica available (broker 1)  ✓
...
```

With the striped pattern, **every partition has at least 1 replica** on brokers {0, 1, 2} because the stripe cycles through all 9 brokers and wraps. With enough partitions, this holds for essentially all partitions.

**Key insight for RF=3, 9 brokers**: Because the striping is modular, ANY set of 3 brokers will have at least 1 replica of every partition IF the number of partitions is ≥ 3 (which it always is in practice). This means we can recover ALL partition data from any 3 disks, but only as a **single replica** (no redundancy until the cluster self-replicates).

**With randomly chosen 3 brokers** (e.g., {2, 5, 7}):

```
Partition 0: [0, 3, 6] → 0 replicas  ✗  ← OFFLINE
Partition 1: [1, 4, 7] → 1 replica (7)  ✓
Partition 2: [2, 5, 8] → 2 replicas (2, 5)  ✓✓
Partition 3: [3, 6, 0] → 0 replicas  ✗  ← OFFLINE
Partition 4: [4, 7, 1] → 1 replica (7)  ✓
...
```

With random 3 brokers, partitions on brokers {0, 3, 6} are entirely missing (0 replicas available). Approximately 1/3 of partition replica-sets will have 0 coverage if 3 brokers are chosen that happen to miss a stripe.

### The Optimal Disk Selection Strategy

**Goal**: Maximize the number of partitions for which at least 1 replica is available.

**Optimal strategy**: Choose 3 brokers from different "stripes" of the assignment pattern. For a striped pattern mod-9:

```
Group A (stripe 0): brokers 0, 3, 6
Group B (stripe 1): brokers 1, 4, 7
Group C (stripe 2): brokers 2, 5, 8

Optimal selection: one broker from each group, e.g., {0, 1, 2} or {3, 4, 5} or {0, 4, 8}
```

With {0, 1, 2}:
- Partition 0 [0,3,6]: broker 0 available ✓
- Partition 1 [1,4,7]: broker 1 available ✓
- Partition 2 [2,5,8]: broker 2 available ✓
- **Every partition has exactly 1 replica** → 100% partition coverage

**How to determine optimal selection before taking snapshots:**

1. Run `kafka-metadata-shell.sh` against the live cluster
2. Navigate to `/topics` and `cat` each partition record
3. Build a matrix: partition → [replica broker IDs]
4. Solve: pick 3 brokers that maximize partition coverage (greedy set cover is sufficient at scale)

In practice, for production clusters with hundreds of partitions and RF=3, **any 3 brokers that include at least one from each modular stripe group will give 100% partition coverage**. The safest bet is {0, 1, 2} (the first 3 brokers) if the original cluster used sequential IDs from 0.

### Snapshot Consistency Considerations

As covered in the previous ADR (snapshot recovery scenarios), each node's disk is snapshotted at a slightly different instant. With RF=3, the "canonical" data for a partition is whichever replica was the most recent leader. After migration, the new cluster will use whichever copy it gets from our 3 disks — which may lag the actual committed state by milliseconds to seconds.

**Implication**: The test cluster will not be byte-for-byte identical to production at any specific moment in time. This is acceptable for a test environment.

---

# PART 2: WHAT SURVIVES, WHAT MUST BE REBUILT

## The Two-Layer Architecture Problem

Kafka on KRaft stores cluster state in two entirely separate places:

```
LAYER 1: KRaft Metadata Layer
Location:  {metadata-log-dir}/__cluster_metadata-0/
Contents:  Cluster topology, broker IDs, partition assignments,
           topic configs, quorum voter set
Format:    Binary Raft log + snapshots
Problem:   References 9 specific node IDs; quorum expects 9 voters

LAYER 2: Partition Data Layer
Location:  {log.dir}/{topic}-{partition}/
Contents:  Actual message data, offset/time indexes, producer snapshots
Format:    Binary Kafka log segments
Problem:   Broker-ID-agnostic! Data can live on any broker.
           The partition directory name (e.g., my-topic-0/) does NOT
           contain the broker ID; it's portable between brokers.
```

The crucial insight is that **partition data files do not embed the broker ID**. A directory `my-topic-0/` on broker 7 can be moved to broker 1 and Kafka will read it correctly — provided the KRaft metadata is updated to say "broker 1 is a replica for my-topic-0".

## What Must Change for a Fresh 3-Node Cluster

### Cannot Reuse → Must Regenerate

| Component | File | Why It Must Change |
|-----------|------|-------------------|
| KRaft voter set | `quorum-state` | References 9 voters; 3-node cluster needs only 3 |
| Broker registrations | `__cluster_metadata-0/*.log` | RegisterBrokerRecord entries reference old node IDs 0-8 |
| Partition assignments | `__cluster_metadata-0/*.log` | PartitionRecord.Replicas references old broker IDs |
| Node identity | `meta.properties` | node.id must match new cluster's broker IDs |
| Directory UUIDs | `meta.properties` | directory.id is per-disk; new machines have new UUIDs |
| KRaft metadata log | `__cluster_metadata-0/` | Entire log tied to old topology |

### Can Reuse → Carry Over

| Component | File | Conditions for Reuse |
|-----------|------|---------------------|
| Partition log data | `{topic}-{partition}/*.log` | Always portable |
| Offset index | `{topic}-{partition}/*.index` | Always portable |
| Time index | `{topic}-{partition}/*.timeindex` | Always portable |
| Transaction index | `{topic}-{partition}/*.txnindex` | Always portable |
| Producer snapshots | `{topic}-{partition}/*.snapshot` | Portable (tracks per-producer state) |
| Leader epoch cache | `{topic}-{partition}/leader-epoch-checkpoint` | Reusable with care (see Part 5) |

### Must Regenerate With Care

| Component | File | Strategy |
|-----------|------|---------|
| HWM checkpoint | `replication-offset-checkpoint` | Set conservatively (to 0 or LEO; see Part 5) |
| Recovery point checkpoint | `recovery-point-offset-checkpoint` | Set to 0 (force full recovery on startup) |
| Log start offset checkpoint | `log-start-offset-checkpoint` | Set to actual log start offset |
| `__consumer_offsets` data | Internal topic partition files | Carry over log files; HWM will be rebuilt |
| `__transaction_state` data | Internal topic partition files | Carry over log files; coordinator will rebuild state |

## The meta.properties Identity Problem

The `meta.properties` file ties a disk directory to a specific node identity:

```properties
version=1
cluster.id=MkQkDy5fTnShlSYvMZcXAA
node.id=7          ← This is the problem
directory.id=J8aAPcfLQt2bqs1JT_rMgQ
```

When we copy broker 7's partition data to new broker 1, the `meta.properties` in the log directory still says `node.id=7`. If we start broker 1 with this `meta.properties`, Kafka will either:
- **Fail with**: `Stored node id 7 doesn't match configured node id 1` (if config says node.id=1)
- **Start as node 7**: Which is wrong for our new cluster

**Solution**: Replace `meta.properties` in every directory with the correct new node.id and a new or preserved cluster.id. The partition data subdirectories (`{topic}-{partition}/`) do not contain `meta.properties` — only the root log directory does. So we regenerate `meta.properties` and leave the partition data directories untouched.

---

# PART 3: THREE MIGRATION STRATEGIES

## Strategy A: Clean Format + Manual Data Injection (Recommended)

**Philosophy**: Start fresh. Use Kafka's own tooling to create a valid 3-node cluster. Then inject production partition data as if it were a new replica that needs to catch up.

### Overview

```
Step 1: Analyse source cluster → identify best 3 disks → take snapshots
Step 2: Format fresh 3-node KRaft cluster (kafka-storage format)
Step 3: Export topic configs from production cluster
Step 4: Start 3-node cluster (empty, no data)
Step 5: Re-create all topics using exported configs
Step 6: Stop cluster
Step 7: Copy partition log files from snapshots into broker directories
Step 8: Regenerate checkpoint files
Step 9: Start cluster → data is loaded, HWM is rebuilt via replication
Step 10: Monitor for OFFLINE partitions → reassign as needed
```

### Pros
- ✅ Cleanest approach; no risk of metadata corruption
- ✅ Uses official Kafka tooling
- ✅ New cluster is a proper citizen (correct voter set, correct broker IDs)
- ✅ Any issues are isolated to the data injection step

### Cons
- ❌ Requires exporting topic configs from live production cluster (AdminClient access needed)
- ❌ Topics must be recreated in the right order (dependencies)
- ❌ Data injection step is manual (copy files, fix checkpoints)
- ❌ After injection, cluster must do leader epoch reset (leader-epoch-checkpoint shows old epochs)

### Critical Detail: Partition Directory Naming

Partition data directories are named `{topicName}-{partitionId}/`. They do NOT contain the broker ID or topic UUID. When we copy `my-topic-0/` from broker 7 into broker 1's log directory, Kafka will:

1. Load `meta.properties` from the broker's root log dir → confirms node.id=1
2. Scan all subdirectories for topic-partition patterns
3. Cross-reference with KRaft metadata: "Does my-topic partition 0 list broker 1 as a replica?"
4. If yes: Load the directory as this broker's replica
5. If no: Directory is orphaned (ignored or moved to `-stray` suffix)

**Therefore**: After creating topics in Step 5, the KRaft metadata will say "broker 0,1,2 are replicas for every partition". Then in Step 7, when we copy the data files, they will be found and loaded correctly by each broker.

---

## Strategy B: Metadata Transplant (Preserve Production cluster.id)

**Philosophy**: Keep the production `cluster.id` so that partition data is recognized without re-creating topics. Surgically edit the KRaft metadata to remove 6 of the 9 brokers.

### Overview

```
Step 1: Take snapshots of 3 optimal production nodes
Step 2: For each of the 3 nodes, update meta.properties:
        - Keep cluster.id (preserve production identity)
        - Change node.id to new ID (0, 1, 2)
        - Generate new directory.id UUID
Step 3: Edit quorum-state on all 3 nodes to reference only [0,1,2]
Step 4: Edit KRaft metadata snapshot:
        - Remove RegisterBrokerRecord for old broker IDs 3-8
        - Update PartitionRecord.Replicas to reference [0,1,2] only
        - Update VotersRecord to [0,1,2]
Step 5: Start cluster (3 brokers claim new IDs but serve production data)
Step 6: Handle OFFLINE partitions (unclean leader election if needed)
```

### Why This Is Harder Than It Looks

The KRaft metadata log is a **binary Raft log** — it is not directly editable with a text editor. The metadata snapshot (`.checkpoint` file) is also binary. To edit it:

1. Read the snapshot using `kafka-metadata-shell.sh` or `kafka-dump-log.sh --files`
2. There is **no built-in tool** to write a new snapshot offline
3. You would need to: write custom code using `MetadataRecordSerde` to produce a new snapshot with modified records, or reconstruct the metadata by replaying the log through a modified `SnapshotFileReader`

Additionally, the `PartitionRecord.Directories` field (v1+) maps each replica to a specific `directory.id` UUID. If we change node IDs and directory UUIDs (as we must), the `Directories` field in PartitionRecord will reference UUIDs that don't exist on the new nodes. This will cause:
- Partitions to appear as having unknown directories (`DirectoryId.UNASSIGNED`)
- Potential partition load failures depending on Kafka version

**Verdict**: Strategy B is theoretically possible but requires custom tooling not available out of the box. It is the right choice if you need to preserve the exact `cluster.id` for some operational reason, but it is significantly more error-prone than Strategy A.

### Pros
- ✅ Cluster.id preserved (important if external systems track it)
- ✅ No need to re-create topics manually
- ✅ Consumer group offsets may be inherited more cleanly

### Cons
- ❌ Requires custom metadata log editing (no standard tool)
- ❌ Directory UUID mismatches require additional handling
- ❌ Risk of starting a corrupted cluster if edits are wrong
- ❌ Must surgically remove 6 brokers from all metadata records

---

## Strategy C: Hybrid — Same cluster.id, Fresh KRaft, Data Injection (Recommended for Test Harness)

**Philosophy**: Combine the clean KRaft formation of Strategy A with the cluster identity preservation of Strategy B, without needing to edit binary metadata files.

### Overview

```
Step 1: Take snapshots of 3 optimal production nodes
Step 2: Extract cluster.id from production's meta.properties
Step 3: Format fresh 3-node cluster using the SAME cluster.id:
        kafka-storage format --cluster-id <production-cluster-id> \
                             --config server.properties
Step 4: Recreate all topics using configs exported from production
        (topic name, partition count, RF=3, configs)
Step 5: Stop 3-node cluster
Step 6: Copy partition log files from snapshots into broker directories
        (Choose which broker gets which partition's copy)
Step 7: Set checkpoint files safely (HWM=0, recovery-point=0)
Step 8: Start 3-node cluster
Step 9: Cluster loads data, rebuilds HWM via ISR negotiation
Step 10: Reassign any OFFLINE partitions; verify consumer group offsets
```

### The cluster.id Preservation Benefit

By using the same `cluster.id` as production (but a freshly formatted KRaft log), we ensure:
- External systems that use cluster.id as an identifier see the same value
- If you later want to run tools that compare this cluster to production, they see the same identity
- `meta.properties` is generated fresh with correct `node.id` values (0, 1, 2) and the matching `cluster.id`

This is distinct from Strategy B in one critical way: **we don't try to reuse the old KRaft metadata log**. We format fresh, which gives a clean quorum-state, clean VotersRecord, and clean broker registrations — but with the same cluster identifier.

### Pros
- ✅ cluster.id matches production
- ✅ Clean KRaft formation (no binary editing)
- ✅ Uses official `kafka-storage format` tooling
- ✅ Data injection is the same as Strategy A (well-understood)
- ✅ Best choice for a reproducible test harness

### Cons
- ❌ Still requires topic re-creation (same as Strategy A)
- ❌ Consumer group offsets need to be manually re-imported

**This is the strategy the rest of the ADR focuses on.**

---

# PART 4: STEP-BY-STEP MIGRATION PLAYBOOK (STRATEGY C)

## Phase 0: Pre-Migration Analysis (Against Live Production)

Before any snapshots are taken, gather the information needed to reconstruct the cluster.

### Step 0.1: Extract cluster.id

From any production broker's log directory:
```
cat {prod-log-dir}/meta.properties | grep cluster.id
# cluster.id=MkQkDy5fTnShlSYvMZcXAA
```

Save this value. It will be used in `kafka-storage format`.

### Step 0.2: Identify Optimal 3 Disks to Snapshot

Use the KRaft metadata shell to dump partition assignments:
```
kafka-metadata-shell.sh \
  --snapshot {prod-log-dir}/__cluster_metadata-0/<latest>.checkpoint
> ls /topics
> cat /topics/<topic-id>/partitions/0
```

Or use the dump-log tool:
```
kafka-dump-log.sh \
  --files {prod-log-dir}/__cluster_metadata-0/00000...00000.log \
  --cluster-metadata-decoder
```

This outputs `PartitionRecord` entries with `Replicas` arrays. Build a coverage matrix:

```
Broker → Partitions it hosts (as any replica)
Broker 0: {partition 0, 3, 6, 9, 12, ...}
Broker 1: {partition 1, 4, 7, 10, 13, ...}
Broker 2: {partition 2, 5, 8, 11, 14, ...}
...
```

Apply greedy set cover: pick 3 brokers that together cover the most partitions.

For a well-balanced cluster, **{0, 1, 2}** will always achieve 100% coverage with the striped placement algorithm.

### Step 0.3: Export All Topic Configurations

While the production cluster is still live:

```
kafka-topics.sh --bootstrap-server prod-broker:9092 \
  --list > topics.txt

# For each topic:
kafka-topics.sh --bootstrap-server prod-broker:9092 \
  --describe --topic <topic-name>
```

Capture for each topic:
- Name
- Number of partitions
- Replication factor (RF=3)
- All topic-level configs (retention.ms, cleanup.policy, compression.type, etc.)
- Topic UUID (from metadata shell: `/topics/<uuid>`)

### Step 0.4: Export Consumer Group Offsets (Optional but Important)

```
kafka-consumer-groups.sh --bootstrap-server prod-broker:9092 \
  --list > consumer-groups.txt

# For each group:
kafka-consumer-groups.sh --bootstrap-server prod-broker:9092 \
  --describe --group <group-name>
```

Save the committed offsets per group per topic-partition. These will be used to validate or restore consumer positions after migration.

### Step 0.5: Note Producer Transactional IDs (If Applicable)

```
kafka-transactions.sh --bootstrap-server prod-broker:9092 list
```

Note any active transactional IDs and their current state.

---

## Phase 1: Take Disk Snapshots

### Step 1.1: Quiesce (Optional but Recommended)

For the cleanest snapshot:
- Pause producers if possible
- Wait for all ISR replicas to catch up (no under-replicated partitions)
- Verify with: `kafka-topics.sh --describe --under-replicated-partitions`
- This minimises HWM divergence across replicas

If quiescing is not possible, proceed with live snapshots (as discussed in the previous ADR, this is recoverable).

### Step 1.2: Snapshot Disks for 3 Selected Brokers

For the 3 selected brokers (e.g., brokers 0, 1, 2), take a disk snapshot of their log directories.

For each broker, you need ALL log directories:
- The KRaft metadata log directory (`__cluster_metadata-0/` — only present on controller nodes, which in combined mode is all nodes)
- All data log directories (`{log.dir}/`)

Note the **snapshot time** for each broker (they will differ by seconds — this is expected and handled).

### Step 1.3: Restore Snapshots to Test Environment

Mount or restore the snapshots to the test environment's 3 machines:
- Broker 0: Receives data from production broker X (one of {0,1,2})
- Broker 1: Receives data from production broker Y
- Broker 2: Receives data from production broker Z

The mapping of old-broker-ID → new-broker-ID is arbitrary. Choose it based on which production broker had which partitions as leaders, so that you minimise the number of partitions that need a new leader after migration.

---

## Phase 2: Format the Fresh 3-Node KRaft Cluster

This creates a valid KRaft identity for the new cluster, without touching the partition data files.

### Step 2.1: Prepare server.properties for Each Broker

For each of the 3 test brokers, create a `server.properties`:

```properties
# Node identity
node.id=0        # (or 1 or 2 for the other brokers)
process.roles=broker,controller

# KRaft quorum — all 3 nodes are voters
controller.quorum.voters=0@broker0:9093,1@broker1:9093,2@broker2:9093

# Listener config
listeners=PLAINTEXT://:9092,CONTROLLER://:9093
inter.broker.listener.name=PLAINTEXT

# Log directories (these contain the partition data from snapshot)
log.dirs=/data/kafka/logs

# Metadata log directory (this will be freshly formatted)
metadata.log.dir=/data/kafka/metadata

# Important: Allow unclean leader elections initially to bring up partitions
# whose ISR members are missing
unclean.leader.election.enable=true

# Reduce session timeouts for faster partition recovery in test
broker.session.timeout.ms=18000
```

### Step 2.2: Run kafka-storage format on All 3 Nodes

**Critical**: Format ONLY the metadata log directory, NOT the data log directory.

```bash
# On all 3 brokers, run:
kafka-storage.sh format \
  --cluster-id MkQkDy5fTnShlSYvMZcXAA \
  --config /path/to/server.properties

# This creates:
# {metadata.log.dir}/meta.properties              ← New, with node.id=0 (or 1,2)
# {metadata.log.dir}/__cluster_metadata-0/
#   00000000000000000000.log                       ← Bootstrap metadata log
#   00000000000000000000.index
#   quorum-state                                   ← 3-node voter set
```

The format command with `--initial-controllers` or in combined mode automatically generates:
- `quorum-state` with `currentVoters: [0, 1, 2]`
- Bootstrap `PartitionRecord` and `VotersRecord` entries in the metadata log
- `meta.properties` with the correct `cluster.id`, `node.id`, and a fresh `directory.id`

**Do NOT run format on the data log directories** (`/data/kafka/logs`). Those contain the partition data from the snapshot and must not be touched by `format`.

### Step 2.3: Verify meta.properties in Data Log Dirs

The data log directories from the snapshot contain a `meta.properties` that references the OLD node ID (e.g., `node.id=7`). This must be updated.

For each data log directory:
```properties
# Edit /data/kafka/logs/meta.properties
version=1
cluster.id=MkQkDy5fTnShlSYvMZcXAA  ← Must match new cluster
node.id=0                            ← Must match this broker's new ID (not old 7!)
directory.id=<new-random-UUID>       ← Generate a fresh UUID
```

**Important**: The `directory.id` is referenced by the KRaft metadata `PartitionRecord.Directories` field. Since we're using a fresh KRaft cluster (Strategy C), the metadata will initially not reference any specific directory UUIDs — the broker will register its new directory UUID, and partitions will be assigned `DirectoryId.UNASSIGNED` (meaning "any available directory").

---

## Phase 3: Re-create Topics

With the fresh cluster formatted (but not yet started), we need to create topic metadata in the KRaft log.

### Step 3.1: Start the Cluster (Briefly, Without Data)

At this point, the fresh cluster has no topics (they were never created). Start all 3 brokers:

```bash
# On all 3 nodes simultaneously:
kafka-server-start.sh /path/to/server.properties &
```

Wait for the cluster to stabilize:
```bash
kafka-metadata-quorum.sh --bootstrap-controller broker0:9093 \
  describe --status
# Expect: Leader elected, 3 voters, 0 observers
```

### Step 3.2: Re-create All Topics from Exported Configs

For each topic captured in Step 0.3:

```bash
kafka-topics.sh --bootstrap-server broker0:9092 \
  --create \
  --topic my-topic \
  --partitions 12 \
  --replication-factor 3 \
  --config retention.ms=604800000 \
  --config cleanup.policy=delete
```

**Important nuances**:
- Create topics in the correct order if there are dependencies
- Use the SAME partition count as production (critical for partition-directory name matching)
- Use RF=3 (even though the cluster is 3 nodes; this is now valid — all 3 brokers will be replicas)
- Apply all topic-level configs (retention, compaction, compression, etc.)

After topic creation, the KRaft metadata will contain:
```
PartitionRecord {
  topicId: <new-uuid>,    ← New UUID (different from production's topic UUID)
  partitionId: 0,
  replicas: [0, 1, 2],   ← All 3 test brokers
  leader: 0,             ← Initial leader
  isr: [0, 1, 2]
}
```

**Note on Topic UUIDs**: Topic UUIDs will differ from production because Kafka generates them at topic creation time. This doesn't affect partition data (data is in directories named by topic-name, not UUID). However, if you have any tools that track topics by UUID, they will see different UUIDs.

### Step 3.3: Stop the Cluster

```bash
kafka-server-stop.sh
```

Wait for clean shutdown (`.kafka_cleanshutdown` files are created).

---

## Phase 4: Inject Production Partition Data

This is the core data migration step. We copy production log files into the test cluster directories.

### Step 4.1: Understand Directory Mapping

After Step 3.2, each broker has directories like:
```
/data/kafka/logs/
├── meta.properties                    ← Updated in Step 2.3
├── replication-offset-checkpoint      ← Will be regenerated
├── recovery-point-offset-checkpoint   ← Will be set to 0
├── log-start-offset-checkpoint        ← Will be updated
├── .kafka_cleanshutdown               ← From Step 3.3 stop
└── my-topic-0/                        ← Empty! Created by Kafka in Step 3.2
    ├── 00000000000000000000.log        ← Empty log segment
    ├── 00000000000000000000.index
    ├── 00000000000000000000.timeindex
    └── leader-epoch-checkpoint         ← Points to epoch 0
```

From the production snapshot, broker X had:
```
{prod-snapshot}/
└── my-topic-0/                        ← Production data!
    ├── 00000000000000000000.log        ← Actual messages
    ├── 00000000000000000000.index
    ├── 00000000000000000100.log
    ├── 00000000000000000100.index
    ...
    ├── 00000000000001234567.snapshot   ← Producer state
    └── leader-epoch-checkpoint
```

### Step 4.2: Decide Which Production Copy Goes Where

For each partition, decide which production broker's copy will go to which test broker:

**Decision criteria**:
1. **Prefer the most recent data**: If broker X was the leader for this partition, its data is the most current
2. **Prefer the copy with the highest LEO**: More data is better
3. **Balance across test brokers**: Distribute partitions so each test broker gets roughly 1/3 of the data

**Optimal strategy**: Use the `leader` field from the production `PartitionRecord` to identify which broker was the leader, and assign that broker's data to the test broker that will become the leader for this partition. This minimizes the number of partitions that have stale data.

### Step 4.3: Copy Partition Directories

For each partition:
```bash
# Remove the empty directory created by Kafka
rm -rf /data/kafka/logs/my-topic-0/

# Copy production partition directory
cp -r {prod-snapshot}/my-topic-0/ /data/kafka/logs/my-topic-0/
```

**Note**: Copy ALL files in the directory:
- `.log` files (message data)
- `.index` files (offset index)
- `.timeindex` files (timestamp index)
- `.txnindex` files (transaction index)
- `.snapshot` files (producer state)
- `leader-epoch-checkpoint` (leader epoch history)

**Do NOT copy**:
- `partition.metadata` file (contains production topic UUID; let Kafka create a new one)

After the copy, the directory structure becomes:
```
/data/kafka/logs/
└── my-topic-0/
    ├── 00000000000000000000.log     ← Production messages!
    ├── 00000000000000000000.index
    ...
    ├── 00000000000001234567.snapshot
    └── leader-epoch-checkpoint      ← From production (may have old epochs)
```

### Step 4.4: Handle Internal Topics

Internal topics require special treatment:

**`__consumer_offsets`**:
- This is a topic with 50 partitions by default
- It was created automatically in Step 3.2 (Kafka creates it on first consumer group activity, or you can pre-create it)
- Copy production `__consumer_offsets-N/` directories for each partition N
- The coordinator will rebuild in-memory state from these logs on startup

**`__transaction_state`**:
- 50 partitions by default
- Copy production `__transaction_state-N/` directories
- The transaction coordinator will rebuild state from these logs
- ONGOING transactions at snapshot time will be auto-aborted after `transaction.timeout.ms`

**`__cluster_metadata`**:
- **DO NOT COPY** this from production. It is the KRaft metadata log and was freshly formatted in Phase 2.
- Copying it would overwrite the clean 3-node metadata with the 9-node metadata.

### Step 4.5: Set Checkpoint Files

The checkpoint files from the production snapshot reference old offsets and broker IDs. Replace them with safe values:

**`recovery-point-offset-checkpoint`**:
Set to 0 for all partitions. This forces Kafka to recover all segments on startup (safe, just slower):
```
0
<number-of-partitions>
my-topic 0 0
my-topic 1 0
...
```

Setting to 0 means: "Nothing is guaranteed to be flushed; recover everything."

**`replication-offset-checkpoint`** (High Watermark):
Set conservatively. Two options:

Option A (Safest — no data visible until ISR established):
```
0
<number-of-partitions>
my-topic 0 0
my-topic 1 0
...
```

Option B (More data visible immediately, small risk):
Copy the production checkpoint but subtract a safety margin (e.g., set HWM to 90% of production HWM). This risks consumers seeing a HWM that's higher than the actual recovered LEO if truncation happens.

**Recommendation**: Use Option A (HWM=0) for the test harness. The cluster will rebuild HWM via ISR negotiation within seconds of all 3 brokers coming online.

**`log-start-offset-checkpoint`**:
Copy this from the production snapshot — it correctly records the oldest message offset, which is relevant for retention-deleted data.

---

## Phase 5: Start the Test Cluster

### Step 5.1: Start All 3 Brokers Simultaneously

```bash
# On all 3 nodes, simultaneously:
kafka-server-start.sh /path/to/server.properties &
```

### Step 5.2: What Happens at Startup

The startup sequence for each broker:

```
1. Load meta.properties:
   → cluster.id: matches cluster (OK)
   → node.id: 0, 1, or 2 (OK)
   → directory.id: new UUID (OK)

2. Load quorum-state (from fresh format):
   → currentVoters: [0, 1, 2] (OK, 3-node quorum)

3. KRaft leader election:
   → 3 voters online, majority achieved immediately
   → Leader elected (e.g., broker 0 at epoch 1)

4. Load KRaft metadata log (fresh, from format):
   → Topics exist: my-topic (12 partitions), etc.
   → PartitionRecord: replicas=[0,1,2] for all partitions

5. Load partition data directories (from snapshot):
   → For each {topic}-{partition}/ directory:
     a. Check .kafka_cleanshutdown: ABSENT (production snapshot = dirty)
     b. recovery-point-offset-checkpoint = 0: recover all segments
     c. LogLoader.recover(): reads all log segments, validates CRC
     d. Truncates any corrupted tail
     e. Rebuilds indexes from log
     f. Loads .snapshot files for producer state
     g. Rebuilds producer state from log above snapshot point

6. Register with controller:
   → BrokerRegistrationRequest with new node.id and directory UUIDs

7. Leader assignment:
   → KRaft metadata says replicas=[0,1,2] for all partitions
   → Controller assigns leaders based on preferred replica list
   → All 3 brokers online → HWM computed from ISR agreement

8. HWM negotiation:
   → Each broker reports its LEO to the leader
   → Leader computes min(ISR LEOs) = new HWM
   → HWM advances from 0 to actual committed offset

9. Cluster becomes ONLINE
```

### Step 5.3: Monitor Startup

```bash
# Check quorum (should show 3 voters, 1 leader):
kafka-metadata-quorum.sh \
  --bootstrap-controller broker0:9093 \
  describe --status

# Check for offline partitions:
kafka-topics.sh --bootstrap-server broker0:9092 \
  --describe --unavailable-partitions

# Check under-replicated partitions (should resolve quickly):
kafka-topics.sh --bootstrap-server broker0:9092 \
  --describe --under-replicated-partitions

# Check HWM progress:
kafka-consumer-groups.sh --bootstrap-server broker0:9092 \
  --describe --group test-consumer
```

---

## Phase 6: Post-Startup Recovery Operations

### Step 6.1: Handle OFFLINE Partitions

If any partitions are OFFLINE after startup (which should not happen given we copied data for all partitions to all 3 brokers, but may occur due to segment corruption), use:

```bash
# Identify offline partitions:
kafka-topics.sh --bootstrap-server broker0:9092 \
  --describe --unavailable-partitions

# For each offline partition, force an unclean leader election
# (if unclean.leader.election.enable=true, this may happen automatically)
# Or use Admin API to trigger election:
kafka-leader-election.sh \
  --bootstrap-server broker0:9092 \
  --election-type UNCLEAN \
  --topic my-topic \
  --partition 5
```

### Step 6.2: Validate Consumer Group Offsets

Compare committed offsets in the test cluster against what was exported in Step 0.4:

```bash
kafka-consumer-groups.sh --bootstrap-server broker0:9092 \
  --describe --group my-consumer-group
```

Expected: Committed offsets should be close to (but not greater than) what was in production at snapshot time. They may be slightly lower due to the HWM checkpoint being stale (up to 5 seconds).

If consumer offsets are significantly different:
- Check the `__consumer_offsets` partition data was correctly copied
- Check the HWM recovery proceeded correctly
- Manually reset offsets if needed:
  ```bash
  kafka-consumer-groups.sh --bootstrap-server broker0:9092 \
    --group my-consumer-group \
    --reset-offsets \
    --topic my-topic \
    --to-offset 5000 \
    --execute
  ```

### Step 6.3: Handle In-Flight Transactions

Any transactions that were ONGOING at snapshot time will be auto-aborted by the transaction coordinator after `transaction.timeout.ms` (default 60 seconds). No manual intervention needed for this.

Transactions in PREPARE_COMMIT state will be completed by the coordinator (it will re-send COMMIT markers to all partitions). This is also automatic.

Monitor:
```bash
kafka-transactions.sh --bootstrap-server broker0:9092 list
# After transaction.timeout.ms: ONGOING transactions should be gone
```

### Step 6.4: Disable Unclean Leader Election

Once the cluster is stable and all partitions are online:

```bash
# Update the cluster-wide default:
kafka-configs.sh --bootstrap-server broker0:9092 \
  --alter \
  --entity-type brokers \
  --entity-default \
  --add-config unclean.leader.election.enable=false
```

### Step 6.5: Verify Data Integrity

Spot-check that the data in the test cluster matches what was in production:

```bash
# Compare message count (approximate):
kafka-run-class.sh kafka.tools.GetOffsetShell \
  --bootstrap-server broker0:9092 \
  --topic my-topic \
  --time -1  # latest offset

# Should be close to (but not greater than) production latest offset
```

---

# PART 5: FAILURE MODES SPECIFIC TO THIS MIGRATION

## Failure Mode 1: Partition Directory Not Found by Kafka

### Symptoms
After startup, some partitions are OFFLINE. The broker logs show:
```
WARN ReplicaManager - Partition my-topic-5 is not found in log directory /data/kafka/logs
```

### Root Causes

**Root Cause A**: Topic was created with a different number of partitions than production. The partition directory `my-topic-5/` doesn't match what Kafka expects for a partition within the topic's range.
- **Fix**: Drop and re-create the topic with the correct partition count.

**Root Cause B**: The directory copy went to the wrong broker. Kafka finds `my-topic-5/` on broker 0 but the KRaft metadata says partition 5's replicas are [0,1,2] — so it should be fine. But if the directory was accidentally copied to a directory named `my-topic5/` (missing the hyphen), Kafka won't find it.
- **Fix**: Verify directory naming: must be `{topic-name}-{partition-id}` exactly.

**Root Cause C**: `partition.metadata` file was copied from production, containing the old topic UUID. Kafka checks this against the KRaft metadata and finds a mismatch (new topic UUID differs from old).
- **Fix**: Delete `partition.metadata` from each partition directory before starting the cluster. Kafka will regenerate it with the new topic UUID.
- **Code reference**: `PartitionMetadataFile.java` — checked during log loading; mismatch causes the directory to be moved to `-stray` suffix and ignored.

### Specific Error Pattern

```
ERROR LogManager - Error loading partition my-topic-0 from {log.dir}:
  InconsistentTopicIdException: Topic ID of my-topic-0 is
  <old-production-uuid> but does not match the metadata topic ID
  <new-test-uuid>
INFO LogManager - Renaming directory my-topic-0 to my-topic-0-stray
```

**Prevention**: Always delete `partition.metadata` files from copied directories before starting.

---

## Failure Mode 2: KRaft Quorum Cannot Achieve Majority

### Symptoms
Brokers start but hang indefinitely:
```
INFO KafkaRaftClient - Waiting to join the quorum (leaderId=optional.empty, epoch=0)
```

### Root Causes

**Root Cause A**: The freshly formatted `quorum-state` references voters [0,1,2] but network connectivity between the 3 brokers is broken. The quorum requires 2 of 3 votes.
- **Fix**: Verify network connectivity on the controller port (9093 by default).

**Root Cause B**: Node IDs in `server.properties` don't match `quorum-state`. For example, `server.properties` says `node.id=0` but `quorum-state` was generated with different voter IDs.
- **Fix**: Verify all `controller.quorum.voters` entries match the `node.id` in each broker's `server.properties`.

**Root Cause C**: `meta.properties` was not updated and still references the old node ID. Kafka validates that `node.id` in `meta.properties` matches the configured `node.id`.
- **Error**: `RuntimeException: Stored node id 7 doesn't match previous node id 0`
- **Fix**: Update `meta.properties` on every log directory.

---

## Failure Mode 3: Leader Epoch Checkpoint Ahead of Actual Log

### Symptoms
On startup, broker logs show:
```
INFO LeaderEpochFileCache - Truncating leader epoch file for partition my-topic-0
  from epoch 15 (stale, beyond log end offset 12345)
```

### What Happens

The production `leader-epoch-checkpoint` file may reference epochs that go beyond the actual log data (because the log was truncated during snapshot recovery). Kafka correctly handles this by truncating the epoch file from the end.

**Result**: The leader epoch cache shows fewer epochs than production. This is harmless — the broker simply starts with a slightly compressed epoch history. However, if a follower connects and has a different (longer) epoch history, it will detect divergence and truncate its own log to match the leader's epoch boundaries.

### Risk

If the new test cluster's broker 0 has its epoch file truncated to epoch 12, but broker 1 still has epoch 15 in its epoch file (because it got a later snapshot), then:
1. Broker 0 is elected leader
2. Broker 1 fetches from broker 0
3. Broker 0 tells broker 1: "My epoch ends at offset X for epoch 12"
4. Broker 1 truncates from that point, losing data that was in epochs 13-15

**Mitigation**: Use the same source disk's data for both the leader copy and follower copies where possible, or set all `leader-epoch-checkpoint` files to a conservative single-epoch entry (epoch 0, offset 0) and let the cluster rebuild from scratch.

---

## Failure Mode 4: HWM Higher Than Available Data

### Symptoms
Consumer receives:
```
org.apache.kafka.clients.consumer.internals.OffsetFetcherUtils$OffsetOutOfRangeException:
  Offsets out of range with no configured reset policy for partitions:
  {my-topic-0=5000}
```

### What Happens

This occurs when:
1. The production `replication-offset-checkpoint` (HWM) was not reset to 0 in Step 4.5
2. The HWM checkpoint says offset 5000 is committed
3. But the actual log data (after recovery and truncation) only goes to offset 4800
4. Consumer tries to fetch offset 5000: broker returns OFFSET_OUT_OF_RANGE

### Fix

After startup, the leader should automatically reset its HWM to `min(ISR-member LEOs)`. If this doesn't happen quickly enough (consumer starts before ISR is fully established):
- Wait for ISR to stabilize before starting consumers
- Or: Ensure HWM checkpoint files are set to 0 during Phase 4 (recommended)

---

## Failure Mode 5: Producer Sequence Number Mismatch

### Symptoms
Transactional or idempotent producers connecting to the test cluster receive:
```
org.apache.kafka.common.errors.OutOfOrderSequenceException:
  Out of order sequence number for producer 456 at offset 4800 in partition
  my-topic-0: 5 (incoming seq. number), 99 (current end sequence number)
```

### What Happens

1. The production `.snapshot` files recorded producer state: `(producerId=456, epoch=3, lastSequence=99)`
2. After migration, the test cluster loads this state from the `.snapshot` files
3. A producer connects to the test cluster with a fresh session: it starts with sequence 0
4. Broker expects sequence 100 (nextExpected = lastSequence + 1 = 100)
5. Producer sends sequence 0 → mismatch → exception

### Fix

For the test cluster, producers should call `initTransactions()` (for transactional producers) or reconnect fresh (for idempotent producers). This causes:
- The broker to bump the epoch for the transactional ID
- The sequence tracking to reset for the new epoch
- Old sequence state to be abandoned

**Or**: Configure test producers to NOT use idempotence/transactions (acceptable for test environments if exactly-once isn't required).

---

## Failure Mode 6: `__consumer_offsets` Shows Wrong Positions

### Symptoms
Consumer groups start from unexpected offsets — either too far back (reprocessing) or too far forward (missing messages).

### What Happens

The `__consumer_offsets` topic is carried over from production. But:
1. The HWM for `__consumer_offsets` partitions is also reset to 0 initially
2. Until the HWM for `__consumer_offsets` catches up, some committed offsets are not visible
3. Consumers query the coordinator: "Where should I start?"
4. Coordinator reads from `__consumer_offsets` up to HWM
5. If HWM is below the last committed offset: coordinator returns an older position

**Duration**: This self-resolves once the `__consumer_offsets` ISR is established and HWM catches up. This takes seconds after startup.

### Fix

Wait for `__consumer_offsets` HWM to stabilize before starting consumers. Check:
```bash
# Verify __consumer_offsets HWM is advancing:
kafka-run-class.sh kafka.tools.GetOffsetShell \
  --bootstrap-server broker0:9092 \
  --topic __consumer_offsets \
  --time -1
```

---

## Failure Mode 7: `partition.metadata` Topic UUID Mismatch

### Symptoms
Broker logs:
```
INFO LogManager - Renaming /data/kafka/logs/my-topic-0 to /data/kafka/logs/my-topic-0-stray
```

### What Happens

Each partition directory contains a `partition.metadata` file:
```
version=0
topic_id=MkQkDy5fTnShlSYvMZcXAAXXXXX
```

This `topic_id` is the Kafka-internal topic UUID, generated when the topic was created. When we re-create the topic in Step 3.2, a **new UUID** is generated. If the `partition.metadata` file from production is present, it will contain the OLD UUID.

Kafka validates this file on startup:
- Reads `partition.metadata`: topic_id = OLD_UUID
- Queries KRaft metadata: "my-topic has UUID = NEW_UUID"
- Mismatch → Moves directory to `-stray` → Partition is OFFLINE

### Prevention

**Always** delete `partition.metadata` from every copied partition directory before starting the cluster. Kafka will recreate it with the new UUID on next startup.

```bash
# Before starting cluster, remove all partition.metadata files:
find /data/kafka/logs -name "partition.metadata" -delete
```

---

## Failure Mode 8: `__cluster_metadata` Contamination

### Symptoms
Cluster starts but shows 9 voters instead of 3, or old broker IDs appear:
```
INFO KafkaRaftClient - Quorum state: leaderId=0, epoch=5, voters=[0,1,2,3,4,5,6,7,8]
```

### What Happens

The `__cluster_metadata-0/` directory from the production snapshot was accidentally copied into the test cluster's metadata log directory (overwriting the freshly formatted one from Step 2.2).

The test cluster is now running the production KRaft metadata log, which references 9 voters. Only 3 are present → quorum cannot elect a leader with epoch = production's epoch.

### Fix

Stop all brokers. Re-run `kafka-storage format` on the metadata log directory to restore the clean 3-node KRaft log. Then re-create topics (Step 3.2 onwards). Do NOT copy `__cluster_metadata-0/` from production.

---

## Failure Mode 9: Segment CRC Errors on Recovery

### Symptoms
```
WARN LogSegment - Found invalid messages in log segment
  /data/kafka/logs/my-topic-0/00000000000001000000.log
  at byte position 204800, discarding invalid messages and
  tailing this log at offset 1001234
```

### What Happens

As covered in the previous ADR, snapshot data can include partially-written records at the tail of the active segment. Kafka's `LogLoader.recover()` detects these, truncates the segment, and continues.

**Result**: The partition's LEO is slightly lower than expected. Data in the truncated portion is lost.

This is expected behaviour and is handled automatically. No manual intervention needed.

### Risk: If HWM > LEO After Truncation

If the production `replication-offset-checkpoint` was copied without resetting to 0, and HWM > actual LEO after truncation, consumers will get OFFSET_OUT_OF_RANGE. **Prevention**: Always reset HWM checkpoints to 0 during Phase 4.

---

# PART 6: TEST HARNESS DESIGNS

Each test design below covers a specific migration scenario. They are ordered from simplest to most complex and are designed to be run against the test harness infrastructure described at the end of this section.

---

## Test Design TM1: Baseline Happy Path Migration

### Goal
Verify that the full Strategy C migration works end-to-end under ideal conditions (quiesced production cluster, optimal disk selection, all partitions recoverable).

### Setup Design

```
Source: 9-node cluster
  - 3 topics: topic-a (12 partitions), topic-b (6 partitions), topic-c (24 partitions)
  - RF=3 for all
  - 10,000 messages per partition
  - No in-flight transactions
  - All consumers committed

Target: 3-node cluster (fresh VMs)

Steps:
  1. Start 9-node source cluster
  2. Produce 10,000 messages per partition per topic
  3. Commit consumer offsets for each topic
  4. Wait for all ISR to be in sync
  5. Stop 9-node cluster cleanly (SIGTERM, not SIGKILL)
  6. Take disk snapshots of brokers 0, 1, 2 (optimal stripe)
  7. Execute full Strategy C migration steps
  8. Start 3-node cluster
  9. Consume all data from all topics
```

### Observations to Assert

- [ ] All topics visible: 3 topics with correct partition counts
- [ ] All partitions ONLINE (no OFFLINE partitions)
- [ ] Message count per partition matches (within tolerance for snapshot timing)
- [ ] Consumer groups show committed offsets close to production
- [ ] No `OutOfOrderSequenceException` or `PRODUCER_FENCED` errors
- [ ] HWM per partition = LEO (cluster fully in sync)
- [ ] `kafka-metadata-quorum.sh describe --status` shows 3 voters, 1 leader

---

## Test Design TM2: Wrong Disk Selection — Suboptimal Coverage

### Goal
Measure how many partitions go OFFLINE when non-optimal disks are chosen, and verify the recovery path for OFFLINE partitions.

### Setup Design

```
Source: 9-node cluster (simulated as 9 local brokers)
  - 3 topics, 9 partitions each (to match 9-broker pattern)
  - RF=3

Target: 3-node cluster

Disk selection: Brokers {0, 3, 6} (all from the same stripe)
  → This maximises the chance of missing some partitions
  (Partition 1's replicas = [1,4,7]: NONE of {0,3,6} → OFFLINE)

Steps:
  1. Identify which partitions will have 0 replicas on {0,3,6}
  2. Execute migration with these "wrong" 3 disks
  3. Start 3-node cluster
  4. Observe OFFLINE partitions
  5. For each OFFLINE partition: run unclean leader election
     → But there are no replicas at all! Can't elect.
  6. Option A: Create fresh (empty) partition in place of OFFLINE
  7. Option B: Go back and snapshot another broker (0,3,6 + one of {1,2})
```

### Observations to Assert

- [ ] Predict correctly which partitions will be OFFLINE before starting cluster
- [ ] `kafka-topics.sh --unavailable-partitions` lists exactly the predicted partitions
- [ ] Unclean leader election fails for 0-replica partitions (expected)
- [ ] After creating fresh empty partition for missing ones: Cluster fully ONLINE
- [ ] Consumers on missing partitions: Must reset to earliest (offset 0, no data)
- [ ] Metric: Percentage of data recovered = (partitions with ≥1 replica) / (total partitions)

---

## Test Design TM3: Live Cluster Snapshot (Non-Quiesced)

### Goal
Verify recovery from a snapshot taken of a live, actively-writing cluster. Measures actual data loss from page-cache loss and segment truncation.

### Setup Design

```
Source: 9-node cluster (running)
  - 1 topic with 12 partitions, RF=3
  - Producer: 10,000 msg/sec continuously writing
  - Consumer: reading with READ_COMMITTED

Steps:
  1. Start source cluster + producer + consumer
  2. After 60 seconds, take disk snapshots of brokers 0, 1, 2
     - DO NOT stop the cluster
     - Each broker snapshotted at different instant (simulate with 2s delays)
  3. Stop source cluster (after snapshot; to prevent further changes)
  4. Execute migration on snapshots
  5. Start 3-node cluster

Measure:
  - Highest offset committed (from producer) before snapshot
  - Highest offset recoverable in test cluster
  - Difference = data loss
```

### Key Metric

```
data_loss = last_producer_ack_before_snapshot - first_unreachable_offset_in_test_cluster
```

For RF=3 and ISR=[0,1,2], data acknowledged by all 3 brokers should survive (≤ 5s stale HWM).

### Observations to Assert

- [ ] Test cluster HWM < source cluster LEO at snapshot time (expected)
- [ ] Test cluster HWM ≥ source cluster HWM - (5 × producer rate) (stale checkpoint tolerance)
- [ ] All partitions come ONLINE
- [ ] CRC errors logged for some segment tails (expected from live snapshot)
- [ ] No cluster-wide OFFLINE partitions

---

## Test Design TM4: partition.metadata Contamination

### Goal
Verify and document the exact failure mode when `partition.metadata` is NOT deleted before starting the test cluster.

### Setup Design

```
Source: 9-node cluster (stopped cleanly)
Target: 3-node cluster

Steps:
  1. Execute full migration (Strategy C)
  2. Deliberately SKIP the step that deletes partition.metadata files
  3. Start 3-node cluster

Observe:
  - Which partitions go to -stray suffix?
  - How many are OFFLINE?
  - What are the exact log messages?

Recovery:
  4. Stop 3-node cluster
  5. Rename all -stray directories back to correct names
  6. Delete partition.metadata from each partition directory
  7. Start 3-node cluster
  8. Verify all partitions ONLINE
```

### Observations to Assert

- [ ] All partition directories renamed to -stray (Kafka treats them as unknown)
- [ ] All partitions OFFLINE (no data loaded)
- [ ] Exact error message captured: "InconsistentTopicIdException"
- [ ] After fix (remove partition.metadata, rename -stray back): all ONLINE
- [ ] Data fully recovered (no loss from the -stray detour)

---

## Test Design TM5: meta.properties node.id Mismatch

### Goal
Verify the exact failure mode when `meta.properties` is not updated before starting the test cluster.

### Setup Design

```
Target: 3-node cluster

Steps:
  1. Execute migration (Strategy C), Phase 2
  2. Deliberately SKIP updating meta.properties in data log directory
     (Leave old node.id=7 in /data/kafka/logs/meta.properties)
  3. Start broker 0 (which has old node.id=7 in its data dir)

Observe:
  - Startup failure or unexpected behavior
  - Exact exception

Recovery:
  4. Fix meta.properties: set node.id=0 (matching broker config)
  5. Restart broker 0
  6. Verify cluster forms correctly
```

### Observations to Assert

- [ ] Broker 0 fails to start with clear error about node.id mismatch
- [ ] Error: "Stored node id 7 doesn't match previous node id 0"
- [ ] Brokers 1 and 2 start correctly (their data dirs are also wrong — same failure)
- [ ] After fix: All brokers start, quorum forms, partitions come ONLINE
- [ ] No data loss from the failed start attempts

---

## Test Design TM6: In-Flight Transaction at Snapshot Time

### Goal
Measure how long it takes for ONGOING transactions (captured in the `__transaction_state` snapshot) to resolve in the test cluster, and verify consumer behavior during this window.

### Setup Design

```
Source: 9-node cluster

Steps:
  1. Start transactional producer: transactional.id="test-txn-1"
     transaction.timeout.ms=120000 (2 minutes)
  2. Producer.beginTransaction()
  3. Send 100 messages to my-topic
  4. DO NOT commit (leave ONGOING)
  5. Take disk snapshots of brokers 0, 1, 2
  6. Execute migration (Strategy C)
  7. Start 3-node cluster

Observe:
  Phase A (T=0 to T=120s):
    - __transaction_state shows "test-txn-1" in ONGOING state
    - Consumer (READ_COMMITTED) blocked before the 100 transactional messages
    - Consumer (READ_UNCOMMITTED) can read the 100 messages

  Phase B (T=120s):
    - Transaction coordinator auto-aborts "test-txn-1"
    - ABORT marker written to my-topic
    - Consumer (READ_COMMITTED) skips the 100 messages, continues reading

Measure:
  - Exact duration from cluster start to consumer unblocking
  - Whether ABORT marker is correctly written to all partitions
```

### Observations to Assert

- [ ] READ_COMMITTED consumer blocked for ~120 seconds
- [ ] READ_UNCOMMITTED consumer sees transactional messages immediately
- [ ] After 120s: ABORT marker appears in partition
- [ ] READ_COMMITTED consumer unblocks and skips the 100 messages
- [ ] No consumer exception — clean unblock

---

## Test Design TM7: HWM Checkpoint Reset vs. Not Reset

### Goal
Compare the startup behaviour and consumer experience with HWM=0 (recommended) vs. HWM=production-value (risky) checkpoint files.

### Setup Design

```
Source: 9-node cluster (stopped cleanly)
  - 1 topic, 3 partitions, RF=3
  - 5000 messages produced, HWM=5000 on all partitions

Target: 3-node cluster

Scenario A (HWM=0):
  1. Set replication-offset-checkpoint to 0 for all partitions
  2. Start cluster
  3. Start consumer immediately (before ISR established)
  4. Measure: How long before consumer sees data?

Scenario B (HWM=production):
  1. Leave replication-offset-checkpoint as-is (HWM=5000)
  2. Start cluster
  3. Start consumer immediately
  4. Measure: Does consumer immediately see data?
  5. If LEO < 5000 after recovery (due to truncation): does OFFSET_OUT_OF_RANGE occur?

Scenario C (HWM=production, but one broker has truncated LEO):
  1. Keep HWM=5000
  2. Artificially truncate one broker's log to offset 4800
  3. Start cluster (that broker is elected leader)
  4. Observe: OFFSET_OUT_OF_RANGE for offsets 4801-5000
```

### Observations to Assert

- [ ] Scenario A: Consumer waits (few seconds) then receives all 5000 messages safely
- [ ] Scenario B: Consumer immediately starts at offset 0 (no wait) and reads all 5000
- [ ] Scenario B: No errors if LEO = HWM (no truncation occurred)
- [ ] Scenario C: OFFSET_OUT_OF_RANGE for consumer at offset 4801-5000
- [ ] Scenario C: HWM resets to 4800 (new LEO) after leader recognizes the gap

---

## Test Design TM8: Consumer Group Offset Inheritance

### Goal
Verify that consumer group offsets from production are correctly inherited in the test cluster, and measure the exact offset drift between production and test.

### Setup Design

```
Source: 9-node cluster (stopped cleanly)
  - 1 topic, 12 partitions, RF=3
  - Consumer group "my-app" has committed offsets:
    Partition 0: offset 5000
    Partition 1: offset 4800
    ...
    Partition 11: offset 5100

Target: 3-node cluster (Strategy C migration)

Steps:
  1. Execute full migration including __consumer_offsets data copy
  2. Start 3-node cluster
  3. Immediately start consumer group "my-app"
  4. Do NOT produce any new messages
  5. Let consumer run for 5 minutes (consuming any missed data)
```

### Measure

```
For each partition:
  production_committed_offset[p]    ← From Step 0.4
  test_cluster_committed_offset[p]  ← From consumer group describe
  drift[p] = production - test      ← How many messages will be re-processed?

Sum(drift) = total duplicate message count expected
```

### Observations to Assert

- [ ] Consumer group "my-app" starts from inherited committed offsets (not from beginning)
- [ ] drift[p] ≥ 0 for all partitions (test offset ≤ production offset, never ahead)
- [ ] drift[p] ≤ 5 × commit_rate[p] (at most 5 seconds of commits missed due to HWM staleness)
- [ ] Consumer processes only the small drift (not entire topic from beginning)
- [ ] No consumer exceptions

---

## Test Design TM9: Large-Scale Migration — Multiple Topics with Mixed Configs

### Goal
Stress-test the migration process with a realistic production-scale topic landscape: many topics, varied configurations, high data volume.

### Setup Design

```
Source: 9-node cluster
  - 50 topics
  - Varied partition counts: 3, 6, 12, 24, 48 partitions
  - Varied configs: compacted topics, high-retention, low-retention
  - RF=3 for all
  - 100GB of data total
  - Some topics with transactional producers (varied states)
  - Some topics with multiple consumer groups

Target: 3-node cluster

Steps:
  1. Generate the 50-topic production environment
  2. Run producers and consumers for 1 hour
  3. Stop cluster cleanly
  4. Snapshot brokers 0, 1, 2
  5. Execute Strategy C migration (automated via test harness)
  6. Start 3-node cluster
  7. Verify all 50 topics are accessible
  8. Verify all consumer groups have sensible offsets
  9. Start all consumer groups, verify no systemic issues
```

### Observations to Assert

- [ ] All 50 topics visible with correct partition counts
- [ ] No OFFLINE partitions (all partitions have ≥1 replica from disks 0,1,2)
- [ ] Topic configs preserved (retention, compaction, etc.)
- [ ] Compacted topics: latest-per-key values preserved
- [ ] All consumer groups start and progress without exceptions
- [ ] Producer reconnection: No OutOfOrderSequenceException after initTransactions()
- [ ] Total migration time < 30 minutes (measure for SLA purposes)

---

## Test Design TM10: Replay Migration — Rebuild Test Cluster from Same Snapshots

### Goal
Verify that the migration process is **reproducible**: given the same disk snapshots, we can destroy and rebuild the test cluster multiple times and get a consistent result each time.

### Setup Design

```
Given: Disk snapshots from TM1 (archived)

Run 1:
  1. Execute full Strategy C migration from archived snapshots
  2. Capture baseline: message counts, HWM per partition, consumer offsets
  3. Destroy 3-node cluster (wipe all data)

Run 2:
  1. Execute full Strategy C migration from same archived snapshots
  2. Capture same metrics
  3. Compare against Run 1 baseline

Run 3:
  1. Same, compare against Run 1
```

### Observations to Assert

- [ ] Run 1 vs Run 2: HWM per partition differs by ≤ 1 (deterministic recovery)
- [ ] Run 1 vs Run 2: Message count per partition is identical
- [ ] Run 1 vs Run 2: Consumer group committed offsets are identical
- [ ] Migration time is consistent (±10% variance)
- [ ] No "first run only" failures (all errors are deterministic and reproducible)

---

# PART 7: TEST HARNESS ARCHITECTURE

## Components Overview

```
MigrationTestHarness
├── SourceClusterManager
│   ├── startCluster(nodeCount=9)
│   ├── stopCluster(mode: CLEAN | KILL)
│   ├── analysePartitionCoverage(brokerSet: Set<Int>) → CoverageReport
│   ├── selectOptimalBrokers(targetCount=3) → Set<Int>
│   ├── exportTopicConfigs() → List<TopicConfig>
│   ├── exportConsumerGroupOffsets() → Map<Group, Map<TopicPartition, Long>>
│   └── takeSnapshot(brokerIds: Set<Int>) → DiskSnapshot
│
├── DiskSnapshot
│   ├── dataFor(brokerId: Int, topic: String, partition: Int) → PartitionData
│   ├── metaPropertiesFor(brokerId: Int) → MetaProperties
│   ├── quorumStateFor(brokerId: Int) → QuorumState
│   ├── checkpointFiles(brokerId: Int) → CheckpointSet
│   └── archive() / restore() → Path
│
├── MigrationExecutor
│   ├── extractClusterId(snapshot: DiskSnapshot) → String
│   ├── formatFreshCluster(clusterId: String, nodeIds: List<Int>, config: KRaftConfig)
│   ├── recreateTopics(topics: List<TopicConfig>, targetCluster: TargetCluster)
│   ├── injectPartitionData(
│   │     snapshot: DiskSnapshot,
│   │     mapping: Map<(sourceBroker,topic,partition), targetBroker>,
│   │     options: InjectionOptions)
│   ├── resetCheckpoints(strategy: HWM_ZERO | HWM_CONSERVATIVE | HWM_PRESERVE)
│   ├── deletePartitionMetadata()   ← Critical: prevents InconsistentTopicIdException
│   └── verifyDirectoryStructure() → ValidationReport
│
├── TargetClusterManager
│   ├── startCluster()
│   ├── waitForQuorum(timeout)
│   ├── waitForAllPartitionsOnline(timeout)
│   ├── describeOfflinePartitions() → List<TopicPartition>
│   ├── triggerUncleanLeaderElection(tp: TopicPartition)
│   ├── disableUncleanLeaderElection()
│   └── stopCluster()
│
├── ValidationSuite
│   ├── verifyTopicExists(topic, partitionCount, rf)
│   ├── verifyPartitionOnline(topic, partition)
│   ├── verifyHwm(topic, partition, expectedMin, expectedMax)
│   ├── verifyConsumerGroupOffset(group, topic, partition, expectedOffset)
│   ├── verifyMessageCount(topic, partition, expectedMin)
│   ├── verifyNoOfflinePartitions()
│   └── compareClusters(source: ClusterState, target: ClusterState) → DriftReport
│
└── ScenarioDriver (per test design TM1-TM10)
    ├── setup()
    ├── trigger()     ← The failure mode injection
    ├── observe()     ← Collect metrics and logs
    ├── assert()      ← Verify expected conditions
    └── teardown()
```

## InjectionOptions (for injectPartitionData)

```
InjectionOptions {
  deletePartitionMetadata: Boolean = true    // ALWAYS true in practice
  resetHwmToZero: Boolean = true            // Recommended
  resetRecoveryPointToZero: Boolean = true  // Recommended
  copyLeaderEpochCheckpoint: Boolean = true // Usually yes
  copyProducerSnapshots: Boolean = true     // Usually yes
  skipInternalTopics: Boolean = false       // Set true to skip __consumer_offsets, __transaction_state
  conflictResolution: PREFER_LEADER | PREFER_HIGHEST_LEO | PREFER_BROKER_N
}
```

## Partition Coverage Analysis

```
CoverageReport {
  totalPartitions: Int
  coveredPartitions: Int           // Has ≥1 replica on selected brokers
  fullyCoveredPartitions: Int      // Has all 3 replicas on selected brokers
  missingPartitions: List<TopicPartition>  // 0 replicas → will be OFFLINE
  coveragePercent: Double
  expectedDataLossPartitions: List<TopicPartition>
}
```

## Recommended Test Execution Order

```
Phase 1 (Baseline and tooling):
  TM1: Baseline happy path — verify migration works before injecting failures

Phase 2 (Individual failure modes):
  TM5: meta.properties mismatch — startup failure, easy to fix
  TM4: partition.metadata contamination — common mistake, easy to fix
  TM7: HWM checkpoint scenarios — understand consumer behaviour

Phase 3 (Data-level scenarios):
  TM6: In-flight transactions — measure timeout and recovery
  TM8: Consumer group offset inheritance — measure drift

Phase 4 (Coverage and scale):
  TM2: Wrong disk selection — measure OFFLINE partition rate
  TM3: Live cluster snapshot — measure real data loss

Phase 5 (Robustness):
  TM9: Large-scale migration — stress test at scale
  TM10: Replay migration — verify reproducibility
```

---

# PART 8: DECISION SUMMARY

## Is 9-Node → 3-Node Migration Feasible?

**Yes**, under these conditions:

| Condition | Requirement |
|-----------|-------------|
| RF=3 across 9 nodes | Pick 3 disks that cover each stripe group (e.g., {0,1,2}) → 100% partition coverage |
| RF=3 across 9 nodes | Any 3 disks → ≥67% partition coverage (some OFFLINE partitions possible) |
| RF > 3 | More replicas available; better chance of coverage from any 3 disks |
| RF = 1 | Only the specific broker that held the partition must be in the 3 disks selected |

## Recommended Strategy

**Strategy C (Hybrid: Same cluster.id, Fresh KRaft)** is recommended:
- Uses official `kafka-storage format` tooling
- Preserves production `cluster.id`
- No binary metadata editing required
- Reproducible and automatable

## Critical Steps That Must Not Be Skipped

1. **Delete `partition.metadata` from all copied partition directories** — failure causes all partitions to be moved to `-stray` and become OFFLINE
2. **Update `meta.properties` in all log directories** — failure causes startup error or wrong node ID
3. **Do NOT copy `__cluster_metadata-0/`** from production — contamination overwrites the fresh 3-node KRaft metadata
4. **Set `recovery-point-offset-checkpoint` to 0** — forces full recovery, ensures no stale data is treated as valid
5. **Set `replication-offset-checkpoint` (HWM) to 0** — prevents OFFSET_OUT_OF_RANGE when HWM > actual LEO after truncation

## Data Loss Expectations

For a well-executed migration with optimal disk selection and a briefly quiesced source cluster:

| Data | Loss | Reason |
|------|------|--------|
| Messages below HWM at snapshot time | None | Replicated to all 3 selected brokers |
| Messages between HWM and LEO at snapshot time | Possible | Uncommitted at snapshot time |
| Messages in page cache at snapshot time | Possible | Never reached disk |
| ONGOING transactions at snapshot time | Yes (after timeout) | Auto-aborted by coordinator |
| PREPARE_COMMIT transactions | None | Coordinator self-heals |
| Consumer committed offsets | Up to 5s drift | HWM checkpoint stale |
| Producer sequence state | Requires initTransactions() | Epoch bump on reconnect |

---

# APPENDIX: Critical File Paths

## Tools

| Tool | Path | Purpose |
|------|------|---------|
| `kafka-storage.sh` | `bin/kafka-storage.sh` → `core/src/main/scala/kafka/tools/StorageTool.scala` | Format KRaft metadata directories |
| `kafka-metadata-shell.sh` | `bin/kafka-metadata-shell.sh` → `shell/src/main/java/org/apache/kafka/shell/MetadataShell.java` | Inspect KRaft snapshots |
| `kafka-dump-log.sh` | `bin/kafka-dump-log.sh` → `tools/src/main/java/org/apache/kafka/tools/DumpLogSegments.java` | Dump metadata log records |
| `kafka-metadata-quorum.sh` | `bin/kafka-metadata-quorum.sh` → `tools/src/main/java/org/apache/kafka/tools/MetadataQuorumCommand.java` | Manage KRaft quorum |
| `kafka-reassign-partitions.sh` | `bin/kafka-reassign-partitions.sh` → `tools/src/main/java/org/apache/kafka/tools/reassign/ReassignPartitionsCommand.java` | Reassign partition replicas |
| `kafka-topics.sh` | `bin/kafka-topics.sh` | Create/describe/delete topics |
| `kafka-consumer-groups.sh` | `bin/kafka-consumer-groups.sh` | Inspect consumer group offsets |

## Key Classes

| Class | File | Role in Migration |
|-------|------|------------------|
| `Formatter` | `metadata/src/main/java/org/apache/kafka/metadata/storage/Formatter.java` | Formats KRaft log directories |
| `MetaProperties` | `metadata/src/main/java/org/apache/kafka/metadata/properties/MetaProperties.java` | meta.properties structure |
| `MetaPropertiesEnsemble` | `metadata/src/main/java/org/apache/kafka/metadata/properties/MetaPropertiesEnsemble.java` | Validates meta.properties on startup |
| `FileQuorumStateStore` | `raft/src/main/java/org/apache/kafka/raft/FileQuorumStateStore.java` | quorum-state file R/W |
| `PartitionRecord` | `metadata/src/main/resources/common/metadata/PartitionRecord.json` | Partition replica assignment |
| `RegisterBrokerRecord` | `metadata/src/main/resources/common/metadata/RegisterBrokerRecord.json` | Broker registration in metadata |
| `PartitionMetadataFile` | `storage/src/main/java/org/apache/kafka/storage/internals/log/PartitionMetadataFile.java` | `partition.metadata` per partition |
| `LogLoader` | `storage/src/main/java/org/apache/kafka/storage/internals/log/LogLoader.java` | Segment recovery on startup |
| `ProducerStateManager` | `storage/src/main/java/org/apache/kafka/storage/internals/log/ProducerStateManager.java` | Producer snapshot loading |
| `OffsetCheckpointFile` | `storage/src/main/java/org/apache/kafka/storage/internals/checkpoint/OffsetCheckpointFile.java` | HWM and recovery point checkpoints |
| `StripedReplicaPlacer` | `metadata/src/main/java/org/apache/kafka/metadata/placement/StripedReplicaPlacer.java` | Replica placement algorithm |
| `DirectoryId` | `server-common/src/main/java/org/apache/kafka/common/DirectoryId.java` | Directory UUID constants |
| `MetadataImage` | `metadata/src/main/java/org/apache/kafka/image/MetadataImage.java` | Complete cluster state snapshot |
| `SnapshotFileReader` | `metadata/src/main/java/org/apache/kafka/metadata/util/SnapshotFileReader.java` | Read KRaft snapshots |

## Key Metadata Record Types

| Record | apiKey | Role |
|--------|--------|------|
| `RegisterBrokerRecord` | 0 | Broker joins cluster |
| `UnregisterBrokerRecord` | 1 | Broker leaves cluster |
| `TopicRecord` | 2 | Topic created |
| `PartitionRecord` | 3 | Partition assignment |
| `PartitionChangeRecord` | 5 | Partition state update |
| `FenceBrokerRecord` | 7 | Broker fenced |
| `UnfenceBrokerRecord` | 8 | Broker unfenced |
| `VotersRecord` | — | KRaft voter set |
| `FeatureLevelRecord` | — | Feature version |
