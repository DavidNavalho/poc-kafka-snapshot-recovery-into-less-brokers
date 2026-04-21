package io.saxo.recovery.rewrite;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import org.apache.kafka.common.DirectoryId;
import org.apache.kafka.common.Uuid;
import org.apache.kafka.common.metadata.BrokerRegistrationChangeRecord;
import org.apache.kafka.common.metadata.NoOpRecord;
import org.apache.kafka.common.metadata.PartitionChangeRecord;
import org.apache.kafka.common.metadata.PartitionRecord;
import org.apache.kafka.common.metadata.TopicRecord;
import org.apache.kafka.server.common.ApiMessageAndVersion;
import org.apache.kafka.server.common.KRaftVersion;
import org.apache.kafka.server.common.OffsetAndEpoch;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class MetadataLogSegmentWriterTest {
    @TempDir
    Path tempDir;

    @Test
    void truncatesMetadataLogImmediatelyBeforeSnapshotEndOffset() throws Exception {
        Path input = tempDir.resolve("input.log");
        Path output = tempDir.resolve("00000000000000000000.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        support.writeSingleRecordBatches(input, 0L, noOp(), noOp(), noOp(), noOp(), noOp());

        new MetadataLogSegmentWriter().writeTruncated(input, output, 3L);

        assertEquals(List.of(0L, 1L, 2L), support.batchOffsets(output));
        assertTrue(Files.isRegularFile(sidecarPath(output, ".index")));
        assertTrue(Files.isRegularFile(sidecarPath(output, ".timeindex")));
        List<MetadataLogSegmentWriterTestSupport.BatchInfo> batches = support.batchInfos(output);
        assertEquals(
            List.of(
                new OffsetIndexEntry(0, 0),
                new OffsetIndexEntry(1, Math.toIntExact(batches.get(1).position())),
                new OffsetIndexEntry(2, Math.toIntExact(batches.get(2).position()))
            ),
            readOffsetIndexEntries(sidecarPath(output, ".index"), 3)
        );
        List<TimeIndexEntry> timeEntries = readTimeIndexEntries(sidecarPath(output, ".timeindex"), 1);
        assertEquals(0, timeEntries.getFirst().relativeOffset());
        assertTrue(timeEntries.getFirst().timestamp() >= 0L);
    }

    @Test
    void rejectsSnapshotOffsetsThatFallInsideABatch() throws Exception {
        Path input = tempDir.resolve("input.log");
        Path output = tempDir.resolve("output.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        support.writeBatch(input, 0L, noOp(), noOp());
        support.writeBatch(input, 2L, noOp());

        RewriteException exception = assertThrows(
            RewriteException.class,
            () -> new MetadataLogSegmentWriter().writeTruncated(input, output, 1L)
        );

        assertEquals("snapshot offset 1 falls in the middle of metadata batch 0-1", exception.getMessage());
    }

    @Test
    void allowsSnapshotEndOffsetAtStartOfFirstBatch() throws Exception {
        Path input = tempDir.resolve("input.log");
        Path output = tempDir.resolve("output.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        support.writeBatch(input, 0L, noOp(), noOp());
        support.writeBatch(input, 2L, noOp());

        new MetadataLogSegmentWriter().writeTruncated(input, output, 0L);

        assertTrue(support.batchOffsets(output).isEmpty());
    }

    @Test
    void truncatesRealMetadataLogAtScenarioCheckpointBoundary() throws Exception {
        Path input = Path.of(
            "..", "..", "fixtures", "snapshots", "baseline-clean-v1",
            "brokers", "broker-0", "metadata", "__cluster_metadata-0",
            "00000000000000000000.log"
        ).normalize();
        Path output = tempDir.resolve("baseline-truncated.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        Assumptions.assumeTrue(Files.isRegularFile(input), "baseline metadata fixture is not available in this test environment");

        new MetadataLogSegmentWriter().writeTruncated(input, output, 8030L);

        List<Long> offsets = support.batchOffsets(output);
        assertEquals(0L, offsets.getFirst());
        assertEquals(8029L, offsets.getLast());
        assertEquals(8029L, offsets.stream().mapToLong(Long::longValue).max().orElseThrow());
    }

    @Test
    void rewritesBrokerChangeRecordsToNoOpBecauseBrokerRegistrationsAreDropped() throws Exception {
        Path input = tempDir.resolve("input.log");
        Path output = tempDir.resolve("00000000000000000000.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        support.writeSingleRecordBatches(input, 8030L, noOp(), brokerChange(8), brokerChange(0));

        new MetadataLogSegmentWriter().rewrite(input, output, emptySnapshot(8030L), options(List.of(0, 1, 2)));

        List<MetadataLogSegmentWriterTestSupport.DecodedRecord> records = support.records(output);
        assertEquals(List.of(8030L, 8031L, 8032L), records.stream().map(MetadataLogSegmentWriterTestSupport.DecodedRecord::offset).toList());
        assertInstanceOf(NoOpRecord.class, records.get(0).record().message());
        assertInstanceOf(NoOpRecord.class, records.get(1).record().message());
        assertInstanceOf(NoOpRecord.class, records.get(2).record().message());
        assertTrue(Files.isRegularFile(sidecarPath(output, ".index")));
        assertTrue(Files.isRegularFile(sidecarPath(output, ".timeindex")));
        List<MetadataLogSegmentWriterTestSupport.BatchInfo> batches = support.batchInfos(output);
        assertEquals(
            List.of(
                new OffsetIndexEntry(8030, 0),
                new OffsetIndexEntry(8031, Math.toIntExact(batches.get(1).position())),
                new OffsetIndexEntry(8032, Math.toIntExact(batches.get(2).position()))
            ),
            readOffsetIndexEntries(sidecarPath(output, ".index"), 3)
        );
    }

    @Test
    void rewritesPartitionChangeRecordsAgainstRewrittenCheckpointState() throws Exception {
        Path input = tempDir.resolve("input.log");
        Path output = tempDir.resolve("output.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        Uuid topicId = Uuid.randomUuid();
        support.writeSingleRecordBatches(input, 8030L, noOp(), partitionChange(topicId));

        new MetadataLogSegmentWriter().rewrite(
            input,
            output,
            snapshotWithPartition(8030L, topicId),
            options(List.of(0, 1, 2))
        );

        List<MetadataLogSegmentWriterTestSupport.DecodedRecord> records = support.records(output);
        assertEquals(List.of(8030L, 8031L), records.stream().map(MetadataLogSegmentWriterTestSupport.DecodedRecord::offset).toList());
        assertInstanceOf(NoOpRecord.class, records.get(0).record().message());
        PartitionChangeRecord rewritten = assertInstanceOf(PartitionChangeRecord.class, records.get(1).record().message());
        assertEquals(List.of(0), rewritten.replicas());
        assertEquals(List.of(0), rewritten.isr());
        assertEquals(0, rewritten.leader());
        assertEquals(List.of(DirectoryId.UNASSIGNED), rewritten.directories());
    }

    @Test
    void rewritesPartitionChangeRecordsByClearingRecoveredElrState() throws Exception {
        Path input = tempDir.resolve("input-with-elr.log");
        Path output = tempDir.resolve("output-with-elr.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        Uuid topicId = Uuid.randomUuid();
        support.writeSingleRecordBatches(input, 8030L, noOp(), partitionChangeWithElr(topicId));

        new MetadataLogSegmentWriter().rewrite(
            input,
            output,
            snapshotWithPartition(8030L, topicId),
            options(List.of(0, 1, 2))
        );

        List<MetadataLogSegmentWriterTestSupport.DecodedRecord> records = support.records(output);
        assertEquals(List.of(8030L, 8031L), records.stream().map(MetadataLogSegmentWriterTestSupport.DecodedRecord::offset).toList());
        assertInstanceOf(NoOpRecord.class, records.get(0).record().message());
        PartitionChangeRecord rewritten = assertInstanceOf(PartitionChangeRecord.class, records.get(1).record().message());
        assertEquals(List.of(0), rewritten.replicas());
        assertEquals(List.of(0), rewritten.isr());
        assertEquals(0, rewritten.leader());
        assertEquals(List.of(DirectoryId.UNASSIGNED), rewritten.directories());
        assertEquals(List.of(), rewritten.eligibleLeaderReplicas());
        assertEquals(List.of(), rewritten.lastKnownElr());
    }

    @Test
    void appliesExplicitFaultOverrideToPartitionTailRecords() throws Exception {
        Path input = tempDir.resolve("input-fault-override.log");
        Path output = tempDir.resolve("output-fault-override.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        Uuid topicId = Uuid.randomUuid();
        support.writeSingleRecordBatches(input, 8030L, noOp(), partitionChange(topicId));

        new MetadataLogSegmentWriter().rewrite(
            input,
            output,
            snapshotWithNamedPartition(8030L, topicId, "recovery.default.6p"),
            options(List.of(0, 1, 2), Optional.of(new PartitionReplicaOverride("recovery.default.6p", 0, List.of(8), 8)))
        );

        List<MetadataLogSegmentWriterTestSupport.DecodedRecord> records = support.records(output);
        assertEquals(List.of(8030L, 8031L), records.stream().map(MetadataLogSegmentWriterTestSupport.DecodedRecord::offset).toList());
        assertInstanceOf(NoOpRecord.class, records.get(0).record().message());
        PartitionChangeRecord rewritten = assertInstanceOf(PartitionChangeRecord.class, records.get(1).record().message());
        assertEquals(List.of(8), rewritten.replicas());
        assertEquals(List.of(8), rewritten.isr());
        assertEquals(8, rewritten.leader());
        assertEquals(List.of(DirectoryId.UNASSIGNED), rewritten.directories());
    }

    @Test
    void passesThroughNonPartitionMetadataTailRecordsUnchanged() throws Exception {
        Path input = tempDir.resolve("input-topic-tail.log");
        Path output = tempDir.resolve("output-topic-tail.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        Uuid topicId = Uuid.randomUuid();
        support.writeSingleRecordBatches(
            input,
            8030L,
            noOp(),
            new ApiMessageAndVersion(new TopicRecord().setName("tail-topic").setTopicId(topicId), (short) 0)
        );

        new MetadataLogSegmentWriter().rewrite(input, output, emptySnapshot(8030L), options(List.of(0, 1, 2)));

        List<MetadataLogSegmentWriterTestSupport.DecodedRecord> records = support.records(output);
        assertEquals(List.of(8030L, 8031L), records.stream().map(MetadataLogSegmentWriterTestSupport.DecodedRecord::offset).toList());
        assertInstanceOf(NoOpRecord.class, records.get(0).record().message());
        TopicRecord topicRecord = assertInstanceOf(TopicRecord.class, records.get(1).record().message());
        assertEquals("tail-topic", topicRecord.name());
        assertEquals(topicId, topicRecord.topicId());
    }

    @Test
    void rewritesRealMetadataTailThatContainsControlBatchAfterCheckpoint() throws Exception {
        Path checkpoint = Path.of(
            "..", "..", "fixtures", "snapshots", "baseline-clean-v3",
            "brokers", "broker-0", "metadata", "__cluster_metadata-0",
            "00000000000000001952-0000000001.checkpoint"
        ).normalize();
        Path input = checkpoint.resolveSibling("00000000000000000000.log");
        Path output = tempDir.resolve("baseline-clean-v3-tail.log");
        Assumptions.assumeTrue(Files.isRegularFile(checkpoint), "baseline-clean-v3 checkpoint fixture is not available in this test environment");
        Assumptions.assumeTrue(Files.isRegularFile(input), "baseline-clean-v3 metadata log fixture is not available in this test environment");
        CheckpointSnapshot snapshot = new CheckpointSnapshotReader().read(checkpoint);
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();

        new MetadataLogSegmentWriter().rewrite(input, output, snapshot, options(List.of(0, 1, 2)));

        List<MetadataLogSegmentWriterTestSupport.DecodedRecord> records = support.records(output);
        assertEquals(11, records.size());
        assertEquals(List.of(1952L, 1953L, 1954L, 1955L, 1956L, 1957L, 1958L, 1959L, 1960L, 1961L, 1962L),
            records.stream().map(MetadataLogSegmentWriterTestSupport.DecodedRecord::offset).toList());
        for (MetadataLogSegmentWriterTestSupport.DecodedRecord record : records) {
            assertInstanceOf(NoOpRecord.class, record.record().message());
        }
    }

    private RewriteOptions options(List<Integer> survivingBrokers) {
        return options(survivingBrokers, Optional.empty());
    }

    private RewriteOptions options(List<Integer> survivingBrokers, Optional<PartitionReplicaOverride> partitionReplicaOverride) {
        return new RewriteOptions(
            tempDir.resolve("input.checkpoint"),
            tempDir.resolve("output.checkpoint"),
            survivingBrokers,
            DirectoryMode.UNASSIGNED,
            false,
            tempDir.resolve("report.json"),
            Optional.empty(),
            Optional.empty(),
            partitionReplicaOverride
        );
    }

    private CheckpointSnapshot emptySnapshot(long offset) {
        return new CheckpointSnapshot(
            new OffsetAndEpoch(offset, 1),
            123L,
            KRaftVersion.KRAFT_VERSION_0,
            Optional.empty(),
            List.of()
        );
    }

    private CheckpointSnapshot snapshotWithPartition(long offset, Uuid topicId) {
        return snapshotWithNamedPartition(offset, topicId, null);
    }

    private CheckpointSnapshot snapshotWithNamedPartition(long offset, Uuid topicId, String topicName) {
        List<ApiMessageAndVersion> records = new ArrayList<>();
        if (topicName != null) {
            records.add(new ApiMessageAndVersion(new TopicRecord().setName(topicName).setTopicId(topicId), (short) 0));
        }
        records.add(
            new ApiMessageAndVersion(
                new PartitionRecord()
                    .setTopicId(topicId)
                    .setPartitionId(0)
                    .setReplicas(List.of(0))
                    .setIsr(List.of(0))
                    .setRemovingReplicas(List.of())
                    .setAddingReplicas(List.of())
                    .setLeader(0)
                    .setLeaderRecoveryState((byte) 0)
                    .setLeaderEpoch(5)
                    .setPartitionEpoch(8)
                    .setDirectories(List.of(DirectoryId.UNASSIGNED))
                    .setEligibleLeaderReplicas(List.of(0))
                    .setLastKnownElr(List.of()),
                (short) 2
            )
        );
        return new CheckpointSnapshot(
            new OffsetAndEpoch(offset, 1),
            123L,
            KRaftVersion.KRAFT_VERSION_0,
            Optional.empty(),
            List.copyOf(records)
        );
    }

    private ApiMessageAndVersion noOp() {
        return new ApiMessageAndVersion(new NoOpRecord(), (short) 0);
    }

    private ApiMessageAndVersion brokerChange(int brokerId) {
        return new ApiMessageAndVersion(
            new BrokerRegistrationChangeRecord()
                .setBrokerId(brokerId)
                .setBrokerEpoch(1L)
                .setFenced((byte) 0)
                .setInControlledShutdown((byte) 0)
                .setLogDirs(List.of()),
            (short) 0
        );
    }

    private ApiMessageAndVersion partitionChange(Uuid topicId) {
        return new ApiMessageAndVersion(
            new PartitionChangeRecord()
                .setTopicId(topicId)
                .setPartitionId(0)
                .setReplicas(List.of(0, 8))
                .setIsr(List.of(0, 8))
                .setLeader(8)
                .setDirectories(List.of(Uuid.randomUuid(), Uuid.randomUuid())),
            (short) 2
        );
    }

    private ApiMessageAndVersion partitionChangeWithElr(Uuid topicId) {
        return new ApiMessageAndVersion(
            new PartitionChangeRecord()
                .setTopicId(topicId)
                .setPartitionId(0)
                .setReplicas(List.of(0, 8))
                .setIsr(List.of(0, 8))
                .setLeader(8)
                .setDirectories(List.of(Uuid.randomUuid(), Uuid.randomUuid()))
                .setEligibleLeaderReplicas(List.of(0, 8))
                .setLastKnownElr(List.of(8)),
            (short) 2
        );
    }

    private Path sidecarPath(Path logPath, String newSuffix) {
        String fileName = logPath.getFileName().toString();
        String baseName = fileName.endsWith(".log")
            ? fileName.substring(0, fileName.length() - ".log".length())
            : fileName;
        return logPath.resolveSibling(baseName + newSuffix);
    }

    private List<OffsetIndexEntry> readOffsetIndexEntries(Path indexPath, int count) throws Exception {
        byte[] bytes = Files.readAllBytes(indexPath);
        ByteBuffer buffer = ByteBuffer.wrap(bytes);
        List<OffsetIndexEntry> entries = new ArrayList<>();
        for (int index = 0; index < count; index++) {
            entries.add(new OffsetIndexEntry(buffer.getInt(), buffer.getInt()));
        }
        return entries;
    }

    private List<TimeIndexEntry> readTimeIndexEntries(Path indexPath, int count) throws Exception {
        byte[] bytes = Files.readAllBytes(indexPath);
        ByteBuffer buffer = ByteBuffer.wrap(bytes);
        List<TimeIndexEntry> entries = new ArrayList<>();
        for (int index = 0; index < count; index++) {
            entries.add(new TimeIndexEntry(buffer.getLong(), buffer.getInt()));
        }
        return entries;
    }

    private record OffsetIndexEntry(int relativeOffset, int position) {
    }

    private record TimeIndexEntry(long timestamp, int relativeOffset) {
    }
}
