# Kafka 9-Node → 3-Node Snapshot Recovery: Final Plan

## Context & Constraints

| Constraint | Detail |
|---|---|
| **Source cluster** | 9 brokers, 3 regions, 3 brokers per region, KRaft mode, rack-aware |
| **Target cluster** | 3 brokers (one region's worth) |
| **Data loss** | Acceptable and expected — goal is best-effort recovery |
| **Infrastructure** | IBM hardware snapshots, DevOps/GitOps, identical configs across nodes |
| **Tiered storage** | Not in use, not planned |
| **Kafka version** | Target will always match source binary version |
| **Existing tooling** | Snapshot-based recovery runbook already exists |

---

## 1. Why One Region Is the Right Selection

With rack awareness enabled and RF=3, Kafka places one replica in each of the 3 regions. Selecting all 3 brokers from a single region gives us:

- **One copy of every RF=3 partition** — rack awareness guarantees it
- **No metadata analysis needed for broker selection** (for RF=3 topics)
- **Simplest snapshot workflow** — snapshot one region's infrastructure as a unit

**Exception — RF < 3 topics**: Any topic with RF=1 or RF=2 may not have a replica in the selected region. Phase 0 must identify these. For a region-based selection with rack awareness, RF=2 topics have a 2/3 chance of having a replica in the selected region; RF=1 topics have a 1/3 chance.

**Action**: Before snapshotting, dump `PartitionRecord` entries from the KRaft metadata snapshot and confirm coverage for ALL topics, not just RF=3 ones. Flag any gaps.

---

## 2. Recommended Strategy: Keep Original Broker IDs + Snapshot Rewrite

After reviewing all three documents and correcting the original ADR's assumptions, the recommended strategy is **Strategy 2 from the internals findings**: keep original broker IDs, mass-copy full disk images, and rewrite the KRaft metadata snapshot.

### Why This Strategy

| Factor | Strategy C (original ADR) | Strategy 2 (recommended) |
|---|---|---|
| **TB-scale feasibility** | Requires per-topic CLI recreation — fragile at scale | Mass-copy, no per-topic work |
| **Topic UUIDs** | New UUIDs generated → must delete all `partition.metadata` | Original UUIDs preserved → no `partition.metadata` changes |
| **Consumer offsets** | Partition count must match exactly when recreating `__consumer_offsets` | Preserved automatically — same topic, same UUIDs |
| **Topic configs** | Must export and re-apply all configs | Preserved in snapshot metadata |
| **Custom tooling** | None (uses `kafka-storage format`) | ~150 lines Java (snapshot rewrite tool) |
| **Offline partitions at startup** | 0% (all brokers are replicas) | 0% (snapshot rewrite assigns all partitions to live brokers) |
| **ACLs, quotas, SCRAM** | Lost (fresh KRaft) | Preserved |

The snapshot rewrite tool is a one-time investment that makes recovery clean and repeatable. It uses Kafka's own `BatchFileReader`/`BatchFileWriter` APIs from the `kafka-metadata` jar.

---

## 3. Recovery Process

### Phase 0: Snapshot Analysis (minutes)

**On the live cluster or from any node's metadata directory:**

```bash
# 1. Find the latest metadata snapshot
ls -1 <any_node>/__cluster_metadata-0/*.checkpoint | sort -V | tail -1

# 2. Dump it
kafka-dump-log.sh \
  --files <above-file> \
  --cluster-metadata-decoder \
  --deep-iteration \
  --print-data-log \
  > cluster-state.json

# 3. Check quorum mode (GATE — must do before anything else)
cat <any_node>/__cluster_metadata-0/quorum-state | python3 -m json.tool
# If data_version: 1 → dynamic quorum → snapshot rewrite MUST also update VotersRecord
# If data_version: 0 → static quorum → voter set handled via server.properties only

# 4. Identify RF < 3 topics
# Parse cluster-state.json for PartitionRecord entries where len(replicas) < 3
# Flag any partition where none of the selected region's broker IDs appear in replicas[]

# 5. Record __consumer_offsets and __transaction_state partition counts
kafka-topics.sh --bootstrap-server prod-broker:9092 \
  --describe --topic __consumer_offsets
kafka-topics.sh --bootstrap-server prod-broker:9092 \
  --describe --topic __transaction_state

# 6. Note the metadata.version from FeatureLevelRecord in cluster-state.json
# Target Kafka binaries must support this exact version

# 7. Document log.dirs configuration and directory.id from each broker's meta.properties
# Critical if multiple log.dirs are in use (see Section 5)
```

**Choose 3 brokers**: All brokers from one region. Prefer the region where most partition leaders reside (data will be most current). In a balanced cluster, any region is equivalent.

**Identify the best metadata snapshot**: Use the `.checkpoint` with the highest offset number across all nodes. Compare offsets from multiple nodes — prefer the most recent.

### Phase 1: Take Snapshots (IBM hardware)

Snapshot all 3 brokers from the selected region. IBM hardware snapshots should be taken as close to simultaneously as possible to minimise cross-node divergence.

Each broker snapshot must include:
- All `log.dirs` volumes
- The `metadata.log.dir` volume (if separate)

### Phase 2: Mass Copy (hours — disk throughput bound)

Mount or restore each snapshot to a corresponding new node:

```
New Node 1 ← snapshot of original broker A  (will run as node.id=A)
New Node 2 ← snapshot of original broker B  (will run as node.id=B)
New Node 3 ← snapshot of original broker C  (will run as node.id=C)
```

Each new node keeps the **original broker ID**. No ID remapping needed.

### Phase 3: Surgical File Edits (minutes per node)

On each node, after the snapshot volume is mounted:

```bash
METADATA_DIR="<path to __cluster_metadata-0>"

# 1. Remove stale Raft log segments (may reference all 9 brokers)
rm -f "${METADATA_DIR}"/*.log
rm -f "${METADATA_DIR}"/*.checkpoint.deleted
rm -f "${METADATA_DIR}"/*.checkpoint.part

# 2. Remove quorum-state (will be recreated fresh on startup)
rm -f "${METADATA_DIR}/quorum-state"

# 3. Place the best .checkpoint on all nodes
#    If snapshots differ in offset, copy the highest-offset one to all nodes

# 4. Write server.properties
cat > /path/to/server.properties << 'EOF'
node.id=<original_broker_id>
process.roles=broker,controller
controller.quorum.voters=A@host1:9093,B@host2:9093,C@host3:9093
listeners=PLAINTEXT://:9092,CONTROLLER://:9093
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER
log.dirs=<same paths as original snapshot>
metadata.log.dir=<same path as original snapshot>
# Safety: extend stray deletion window to 24h for first boot
file.delete.delay.ms=86400000
# Allow unclean election for partitions whose ISR members are missing
unclean.leader.election.enable=true
EOF

# 5. Verify meta.properties matches (should already be correct since we keep original IDs)
for dir in <each log.dir>; do
  grep node.id "${dir}/meta.properties"
  # Must return: node.id=<same as server.properties>
done
```

### Phase 4: Snapshot Rewrite (the key step)

Run the snapshot rewrite tool against the best `.checkpoint`:

```
Input:
  - source: <best_snapshot>.checkpoint
  - surviving_broker_ids: {A, B, C}  (the 3 original IDs from our region)
  - directory_mode: UNASSIGNED  (eliminates directory.id tracking)

Processing per record type:
  PartitionRecord:
    surviving = replicas[] ∩ {A, B, C}
    if surviving is non-empty:
      replicas     = surviving
      isr          = surviving
      leader       = first of surviving (prefer original leader if present)
      leaderEpoch  = original + 1
      partitionEpoch = original + 1
      directories  = [UNASSIGNED] × len(surviving)
    if surviving is empty:
      → assign to any live broker (partition comes online empty; data loss accepted)

  RegisterBrokerRecord:
    Keep only entries for {A, B, C}; omit the other 6

  TopicRecord, FeatureLevelRecord, ConfigRecord, ProducerIdsRecord,
  ClientQuotaRecord, AccessControlEntryRecord:
    Pass through unchanged

  VotersRecord (dynamic quorum only):
    Replace voter set with {A, B, C}

Output: rewritten.checkpoint (same offset-epoch filename, drop-in replacement)
```

Place the rewritten snapshot on all 3 nodes:
```bash
cp rewritten.checkpoint "${METADATA_DIR}/"
# Remove original checkpoint if it has a different filename
```

### Phase 5: Pre-Start Validation (do NOT skip)

Before starting any broker, programmatically verify:

```bash
# 1. Every meta.properties has correct node.id and cluster.id
for dir in <each log.dir on each node>; do
  grep -E "node.id|cluster.id" "${dir}/meta.properties"
done

# 2. quorum-state is ABSENT on all nodes
ls <each_node>/__cluster_metadata-0/quorum-state  # should not exist

# 3. No stale .log segments in __cluster_metadata-0/
ls <each_node>/__cluster_metadata-0/*.log  # should be empty

# 4. The rewritten .checkpoint exists on all nodes
ls <each_node>/__cluster_metadata-0/*.checkpoint

# 5. Count partition directories — sanity check
find <log.dirs> -maxdepth 1 -type d -name "*-*" | wc -l
# Compare against expected partition count from Phase 0

# 6. file.delete.delay.ms is set to 86400000 in server.properties (24h safety net)
grep file.delete.delay.ms /path/to/server.properties
```

### Phase 6: Start the Cluster

```bash
# Start all 3 nodes simultaneously
kafka-server-start.sh /path/to/server.properties &
```

**Monitor:**
```bash
# Quorum health — expect 1 leader elected within seconds
kafka-metadata-quorum.sh --bootstrap-controller host:9093 describe --status

# Offline partitions — expect 0 with snapshot rewrite
kafka-topics.sh --bootstrap-server host:9092 --describe --unavailable-partitions

# Under-replicated partitions — expected initially, resolves as ISR establishes
kafka-topics.sh --bootstrap-server host:9092 --describe --under-replicated-partitions

# Watch for stray detection (should not happen with rewrite, but check)
grep -i "stray" <broker-logs>/*.log
```

### Phase 7: Post-Start Stabilisation

```bash
# 1. If any partitions are offline (only RF<3 topics with no replica in our region):
kafka-leader-election.sh \
  --bootstrap-server host:9092 \
  --election-type UNCLEAN \
  --all-topic-partitions

# 2. For truly unreachable partitions (0 replicas on our brokers):
# Reassign as empty partitions — data loss accepted
kafka-reassign-partitions.sh \
  --bootstrap-server host:9092 \
  --reassignment-json-file reassign-offline.json \
  --execute

# 3. Validate consumer group offsets
kafka-consumer-groups.sh --bootstrap-server host:9092 \
  --describe --group <group-name>
# Offsets should be close to production values

# 4. Once stable, disable unclean election
kafka-configs.sh --bootstrap-server host:9092 \
  --alter --entity-type brokers --entity-default \
  --add-config unclean.leader.election.enable=false

# 5. Reset file.delete.delay.ms to default
kafka-configs.sh --bootstrap-server host:9092 \
  --alter --entity-type brokers --entity-default \
  --add-config file.delete.delay.ms=60000
```

---

## 4. Consumer Offsets Recovery

Consumer offsets are a critical concern. With Strategy 2 (keep original IDs + snapshot rewrite):

- `__consumer_offsets` partition data is carried over from the snapshot
- Topic UUIDs are preserved, so `partition.metadata` is valid
- The coordinator partition assignment uses `hash(group.id) % num_partitions` — since we keep the same `__consumer_offsets` topic (same partition count, same data), mapping is preserved

**What could go wrong:**
1. **HWM lag**: Until `__consumer_offsets` ISR establishes and HWM catches up, some committed offsets may not be visible. Self-resolves in seconds.
2. **Orphaned entries**: If any user topic was not migrated (RF=1, broker not selected), offset entries for those topics still exist but reference non-existent partitions. Consumers will get errors for those specific topic-partitions.

**Validation step:**
```bash
# Wait for __consumer_offsets HWM to stabilise before starting consumers
kafka-run-class.sh kafka.tools.GetOffsetShell \
  --bootstrap-server host:9092 \
  --topic __consumer_offsets \
  --time -1

# Then verify consumer groups
kafka-consumer-groups.sh --bootstrap-server host:9092 --list
kafka-consumer-groups.sh --bootstrap-server host:9092 \
  --describe --group <each-group>
```

If offsets are wrong, manually reset:
```bash
kafka-consumer-groups.sh --bootstrap-server host:9092 \
  --group <group> --reset-offsets --topic <topic> \
  --to-offset <offset> --execute
```

---

## 5. Multiple Log Directories

Production brokers may use multiple `log.dirs` (e.g., `/disk1/kafka,/disk2/kafka`). Each directory has its own `meta.properties` with a unique `directory.id`.

**With our strategy (keep original IDs + UNASSIGNED directories in snapshot rewrite):**
- Each log directory's `meta.properties` is already correct (same node.id, same cluster.id)
- Setting `directories[]` to `UNASSIGNED` in the rewritten snapshot eliminates directory-level validation
- Kafka will find partition directories in any of the broker's `log.dirs` automatically

**Action**: Ensure `log.dirs` in `server.properties` lists the same paths as the original broker's configuration. Since infrastructure is identical (DevOps/GitOps), this should be automatic.

---

## 6. Replication Factor After Recovery

After recovery, each partition has only the replicas that existed on the 3 selected brokers. For RF=3 topics with rack awareness, this means **RF=1 in practice** — each partition has exactly one live replica.

**Options for expanding:**

| Option | RF | Disk impact | Complexity |
|---|---|---|---|
| **Stay at RF=1** | 1 | No additional disk | Simplest; no redundancy |
| **Expand to RF=2** | 2 | ~2× disk per broker | Moderate; Kafka handles via reassignment |
| **Expand to RF=3** | 3 | ~3× disk per broker | Requires sufficient disk capacity |

To expand:
```bash
# Generate reassignment plan
kafka-reassign-partitions.sh --bootstrap-server host:9092 \
  --topics-to-move-json-file topics.json \
  --broker-list "A,B,C" \
  --generate

# Execute (Kafka will replicate data across brokers)
kafka-reassign-partitions.sh --bootstrap-server host:9092 \
  --reassignment-json-file plan.json \
  --execute
```

**Disk space consideration**: With 3 brokers and RF=3, every broker holds a copy of every partition. Each broker needs ~(total data / 3 × 3) = total data worth of disk. Verify capacity before expanding.

---

## 7. Compacted Topics

Topics with `cleanup.policy=compact` will experience a full re-compaction cycle after migration because the log cleaner's in-memory state is lost. This means:

- Temporary ~2× disk usage during re-compaction
- Higher I/O during the compaction pass
- Latest-per-key values are preserved (they're in the log segments)

No special handling needed — just budget disk space for the compaction overhead.

---

## 8. Transaction Recovery

The existing transaction recovery harness covers this. Key behaviours after snapshot recovery:

- **ONGOING transactions**: Auto-aborted after `transaction.timeout.ms` (default 60s)
- **PREPARE_COMMIT transactions**: Coordinator self-heals (re-sends COMMIT markers)
- **Failed-to-abort transactions**: The existing recovery harness handles cancellation and restart

Producers reconnecting to the recovered cluster must call `initTransactions()` to bump the epoch and reset sequence tracking.

---

## 9. The Snapshot Rewrite Tool

### Specification

**Input**: A `.checkpoint` file + set of surviving broker IDs + directory mode (UNASSIGNED)

**Output**: A valid `.checkpoint` file where every partition references only live brokers

**Implementation**: ~100-150 lines of Java using:
- `BatchFileReader` (reads `.checkpoint`)
- `BatchFileWriter` (writes new `.checkpoint` with `SnapshotHeader`/`Footer`)
- Both ship in the `kafka-metadata` jar in every Kafka installation's `libs/` directory

**Processing rules**: See Phase 4 above for the complete per-record-type specification.

**Why it's small**: The metadata snapshot is only cluster topology — no message data. Regardless of TBs of partition data, the snapshot is typically 10-100 MB. Reading and rewriting takes seconds.

---

## 10. Known Limitations & Deferred Items

| Item | Status | Notes |
|---|---|---|
| **Listener/security config** | Deferred | Known solvable; not blocking for initial tests |
| **Per-topic validation framework** | Deferred | Build after basic recovery is validated |
| **Throttle/quota cleanup** | Deferred | Not critical for test environment |
| **metadata.version pinning** | Note | Use same Kafka binary version; no version skew |
| **Dynamic quorum (KIP-853)** | Gate check | If `data_version: 1`, snapshot rewrite must update `VotersRecord` |

---

## 11. Checklist Summary

### Before Snapshotting
- [ ] Dump KRaft metadata snapshot and identify all topics/partitions
- [ ] Confirm RF < 3 topics and assess coverage
- [ ] Check `quorum-state` for `data_version` (static vs dynamic quorum)
- [ ] Record `__consumer_offsets` and `__transaction_state` partition counts
- [ ] Document `log.dirs` and `directory.id` from each broker
- [ ] Select region (prefer region with most partition leaders)

### After Snapshot, Before Start
- [ ] Mass-copy snapshot volumes to new nodes
- [ ] Delete `quorum-state` on all nodes
- [ ] Delete all `.log` segments in `__cluster_metadata-0/`
- [ ] Place best (highest-offset) `.checkpoint` on all nodes
- [ ] Run snapshot rewrite tool → rewritten `.checkpoint` on all nodes
- [ ] Write `server.properties` with original broker IDs, 3-node voter set
- [ ] Set `file.delete.delay.ms=86400000` (24h safety window)
- [ ] Verify all `meta.properties` match expected `node.id` and `cluster.id`
- [ ] Run pre-start validation (Section 3, Phase 5)

### After Start
- [ ] Confirm quorum: 3 voters, 1 leader
- [ ] Confirm 0 offline partitions (or only expected RF<3 gaps)
- [ ] Handle any offline partitions via unclean election or reassignment
- [ ] Validate consumer group offsets
- [ ] Disable `unclean.leader.election.enable`
- [ ] Reset `file.delete.delay.ms` to default
- [ ] Verify no `-stray` directories in logs

---

## 12. Risk Summary

| Risk | Severity | Mitigation |
|---|---|---|
| Stray detection deletes all data | **Critical** | Snapshot rewrite ensures `Replicas[]` matches broker IDs; `file.delete.delay.ms=24h` as safety net |
| Topic UUID mismatch kills a disk | **Critical** | Keep original snapshot → UUIDs match; no `partition.metadata` changes needed |
| 9-node quorum deadlock | **High** | Delete `quorum-state`; set `controller.quorum.voters` to 3 nodes |
| RF<3 topics with no replica | **Medium** | Phase 0 identifies these; data loss accepted per constraints |
| Consumer offset drift | **Medium** | Wait for `__consumer_offsets` HWM to stabilise before starting consumers |
| Segment tail corruption | **Low** | `LogLoader.recover()` truncates automatically; expected from live snapshots |
| Compaction disk spike | **Low** | Budget 2× disk for compacted topics during re-compaction |
