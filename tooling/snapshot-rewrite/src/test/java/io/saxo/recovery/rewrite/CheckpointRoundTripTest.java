package io.saxo.recovery.rewrite;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Path;
import java.util.List;
import java.util.Optional;
import org.apache.kafka.common.DirectoryId;
import org.apache.kafka.common.Uuid;
import org.apache.kafka.common.metadata.PartitionRecord;
import org.apache.kafka.common.metadata.RegisterBrokerRecord;
import org.apache.kafka.common.metadata.RegisterControllerRecord;
import org.apache.kafka.common.metadata.TopicRecord;
import org.apache.kafka.server.common.ApiMessageAndVersion;
import org.apache.kafka.server.common.KRaftVersion;
import org.apache.kafka.server.common.OffsetAndEpoch;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class CheckpointRoundTripTest {
    @TempDir
    Path tempDir;

    @Test
    void rewritesAndRoundTripsARealSnapshotFile() {
        Uuid topicId = Uuid.randomUuid();
        CheckpointSnapshot inputSnapshot = new CheckpointSnapshot(
            new OffsetAndEpoch(42L, 3),
            123456789L,
            KRaftVersion.KRAFT_VERSION_0,
            Optional.empty(),
            List.of(
                new ApiMessageAndVersion(new TopicRecord().setName("orders").setTopicId(topicId), (short) 0),
                new ApiMessageAndVersion(registerBroker(0), (short) 3),
                new ApiMessageAndVersion(registerBroker(2), (short) 3),
                new ApiMessageAndVersion(registerBroker(4), (short) 3),
                new ApiMessageAndVersion(registerController(0), (short) 0),
                new ApiMessageAndVersion(registerController(2), (short) 0),
                new ApiMessageAndVersion(registerController(4), (short) 0),
                new ApiMessageAndVersion(
                    new PartitionRecord()
                        .setTopicId(topicId)
                        .setPartitionId(1)
                        .setReplicas(List.of(0, 4))
                        .setIsr(List.of(0, 4))
                        .setRemovingReplicas(List.of())
                        .setAddingReplicas(List.of())
                        .setLeader(4)
                        .setLeaderRecoveryState((byte) 0)
                        .setLeaderEpoch(5)
                        .setPartitionEpoch(8)
                        .setDirectories(List.of(Uuid.randomUuid(), Uuid.randomUuid()))
                        .setEligibleLeaderReplicas(List.of(0, 4))
                        .setLastKnownElr(List.of(4)),
                    (short) 2
                )
            )
        );

        Path inputPath = tempDir.resolve("input").resolve("00000000000000000042-0000000003.checkpoint");
        Path outputPath = tempDir.resolve("output").resolve("00000000000000000042-0000000003.checkpoint");

        CheckpointSnapshotWriter writer = new CheckpointSnapshotWriter();
        writer.write(inputPath, inputSnapshot);

        CheckpointSnapshotReader reader = new CheckpointSnapshotReader();
        CheckpointSnapshot loadedSnapshot = reader.read(inputPath);

        RewriteExecutionResult result = new CheckpointRewriteEngine().rewrite(
            loadedSnapshot,
            new RewriteOptions(
                inputPath,
                outputPath,
                List.of(0, 2),
                DirectoryMode.UNASSIGNED,
                false,
                tempDir.resolve("report.json"),
                Optional.empty(),
                Optional.empty()
            )
        );

        writer.write(outputPath, result.snapshot());
        CheckpointSnapshot rewrittenSnapshot = reader.read(outputPath);

        assertEquals(new OffsetAndEpoch(42L, 3), rewrittenSnapshot.snapshotId());
        assertEquals(123456789L, rewrittenSnapshot.lastContainedLogTimestamp());
        assertEquals(KRaftVersion.KRAFT_VERSION_0, rewrittenSnapshot.kraftVersion());
        assertFalse(rewrittenSnapshot.voterSet().isPresent());
        assertEquals(2, rewrittenSnapshot.records().size());

        PartitionRecord partitionRecord = rewrittenSnapshot.records()
            .stream()
            .map(ApiMessageAndVersion::message)
            .filter(PartitionRecord.class::isInstance)
            .map(PartitionRecord.class::cast)
            .findFirst()
            .orElseThrow();
        assertEquals(List.of(0), partitionRecord.replicas());
        assertEquals(List.of(0), partitionRecord.isr());
        assertEquals(0, partitionRecord.leader());
        assertEquals(6, partitionRecord.leaderEpoch());
        assertEquals(9, partitionRecord.partitionEpoch());
        assertEquals(List.of(DirectoryId.UNASSIGNED), partitionRecord.directories());
        assertEquals(List.of(), partitionRecord.eligibleLeaderReplicas());
        assertEquals(List.of(), partitionRecord.lastKnownElr());

        List<Integer> brokerIds = rewrittenSnapshot.records()
            .stream()
            .map(ApiMessageAndVersion::message)
            .filter(RegisterBrokerRecord.class::isInstance)
            .map(RegisterBrokerRecord.class::cast)
            .map(RegisterBrokerRecord::brokerId)
            .toList();
        assertEquals(List.of(), brokerIds);

        List<Integer> controllerIds = rewrittenSnapshot.records()
            .stream()
            .map(ApiMessageAndVersion::message)
            .filter(RegisterControllerRecord.class::isInstance)
            .map(RegisterControllerRecord.class::cast)
            .map(RegisterControllerRecord::controllerId)
            .toList();
        assertEquals(List.of(), controllerIds);

        assertEquals(8, result.outcome().recordsProcessed().total());
        assertEquals(1, result.outcome().recordsProcessed().byType().get("PartitionRecord"));
        assertEquals(3, result.outcome().recordsProcessed().byType().get("RegisterBrokerRecord"));
        assertEquals(3, result.outcome().recordsProcessed().byType().get("RegisterControllerRecord"));
        assertEquals(1, result.outcome().recordsProcessed().byType().get("TopicRecord"));
        assertEquals(1, result.outcome().partitionSummary().leaderReassigned());
        assertTrue(result.outcome().warnings().isEmpty());
    }

    @Test
    void rewriteHandlesNullAuxiliaryPartitionLists() {
        Uuid topicId = Uuid.randomUuid();
        CheckpointSnapshot snapshot = new CheckpointSnapshot(
            new OffsetAndEpoch(42L, 3),
            123456789L,
            KRaftVersion.KRAFT_VERSION_0,
            Optional.empty(),
            List.of(
                new ApiMessageAndVersion(new TopicRecord().setName("orders").setTopicId(topicId), (short) 0),
                new ApiMessageAndVersion(
                    new PartitionRecord()
                        .setTopicId(topicId)
                        .setPartitionId(1)
                        .setReplicas(List.of(0, 4))
                        .setIsr(List.of(0, 4))
                        .setLeader(4)
                        .setLeaderRecoveryState((byte) 0)
                        .setLeaderEpoch(5)
                        .setPartitionEpoch(8)
                        .setDirectories(List.of(Uuid.randomUuid(), Uuid.randomUuid())),
                    (short) 2
                )
            )
        );

        RewriteExecutionResult result = new CheckpointRewriteEngine().rewrite(
            snapshot,
            new RewriteOptions(
                tempDir.resolve("in.checkpoint"),
                tempDir.resolve("out.checkpoint"),
                List.of(0, 2),
                DirectoryMode.UNASSIGNED,
                false,
                tempDir.resolve("report.json"),
                Optional.empty(),
                Optional.empty()
            )
        );

        PartitionRecord rewrittenPartition = assertInstanceOf(
            PartitionRecord.class,
            result.snapshot().records().get(1).message()
        );
        assertEquals(List.of(), rewrittenPartition.removingReplicas());
        assertEquals(List.of(), rewrittenPartition.addingReplicas());
        assertEquals(List.of(), rewrittenPartition.eligibleLeaderReplicas());
        assertEquals(List.of(), rewrittenPartition.lastKnownElr());
    }

    private RegisterBrokerRecord registerBroker(int brokerId) {
        return new RegisterBrokerRecord()
            .setBrokerId(brokerId)
            .setIsMigratingZkBroker(false)
            .setIncarnationId(Uuid.randomUuid())
            .setBrokerEpoch(1L)
            .setEndPoints(new RegisterBrokerRecord.BrokerEndpointCollection())
            .setFeatures(new RegisterBrokerRecord.BrokerFeatureCollection())
            .setRack(null)
            .setFenced(false)
            .setInControlledShutdown(false)
            .setLogDirs(List.of(Uuid.randomUuid()));
    }

    private RegisterControllerRecord registerController(int controllerId) {
        return new RegisterControllerRecord()
            .setControllerId(controllerId)
            .setIncarnationId(Uuid.randomUuid())
            .setZkMigrationReady(false)
            .setEndPoints(new RegisterControllerRecord.ControllerEndpointCollection())
            .setFeatures(new RegisterControllerRecord.ControllerFeatureCollection());
    }
}
