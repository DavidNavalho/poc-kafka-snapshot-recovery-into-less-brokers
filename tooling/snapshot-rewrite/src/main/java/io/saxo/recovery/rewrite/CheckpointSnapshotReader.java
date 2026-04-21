package io.saxo.recovery.rewrite;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import org.apache.kafka.common.message.KRaftVersionRecord;
import org.apache.kafka.common.message.SnapshotHeaderRecord;
import org.apache.kafka.common.message.VotersRecord;
import org.apache.kafka.common.utils.BufferSupplier;
import org.apache.kafka.common.utils.LogContext;
import org.apache.kafka.metadata.MetadataRecordSerde;
import org.apache.kafka.raft.Batch;
import org.apache.kafka.raft.ControlRecord;
import org.apache.kafka.raft.VoterSet;
import org.apache.kafka.server.common.ApiMessageAndVersion;
import org.apache.kafka.server.common.KRaftVersion;
import org.apache.kafka.server.common.OffsetAndEpoch;
import org.apache.kafka.snapshot.FileRawSnapshotReader;
import org.apache.kafka.snapshot.RecordsSnapshotReader;

final class CheckpointSnapshotReader {
    private static final int MAX_BATCH_SIZE = 1024 * 1024;

    CheckpointSnapshot read(Path checkpointPath) {
        CheckpointFilename checkpointFilename = CheckpointFilename.parse(checkpointPath.getFileName().toString());
        OffsetAndEpoch snapshotId = new OffsetAndEpoch(checkpointFilename.offset(), checkpointFilename.epoch());
        Path logDir = checkpointPath.toAbsolutePath().normalize().getParent();
        if (logDir == null) {
            throw new RewriteException("checkpoint path has no parent directory: " + checkpointPath);
        }

        try (
            FileRawSnapshotReader rawReader = FileRawSnapshotReader.open(logDir, snapshotId);
            RecordsSnapshotReader<ApiMessageAndVersion> snapshotReader = RecordsSnapshotReader.of(
                rawReader,
                MetadataRecordSerde.INSTANCE,
                BufferSupplier.NO_CACHING,
                MAX_BATCH_SIZE,
                true,
                new LogContext("[snapshot-rewrite-reader] ")
            )
        ) {
            if (!snapshotReader.hasNext()) {
                throw new RewriteException("snapshot contains no batches: " + checkpointPath);
            }

            long lastContainedLogTimestamp = snapshotReader.lastContainedLogTimestamp();
            KRaftVersion kraftVersion = KRaftVersion.KRAFT_VERSION_0;
            Optional<VoterSet> voterSet = Optional.empty();
            List<ApiMessageAndVersion> records = new ArrayList<>();

            while (snapshotReader.hasNext()) {
                Batch<ApiMessageAndVersion> batch = snapshotReader.next();
                for (ControlRecord controlRecord : batch.controlRecords()) {
                    if (controlRecord.message() instanceof SnapshotHeaderRecord headerRecord) {
                        lastContainedLogTimestamp = headerRecord.lastContainedLogTimestamp();
                    } else if (controlRecord.message() instanceof KRaftVersionRecord versionRecord) {
                        kraftVersion = KRaftVersion.fromFeatureLevel(versionRecord.kRaftVersion());
                    } else if (controlRecord.message() instanceof VotersRecord votersRecord) {
                        voterSet = Optional.of(VoterSet.fromVotersRecord(votersRecord));
                    }
                }
                records.addAll(batch.records());
            }

            return new CheckpointSnapshot(
                snapshotId,
                lastContainedLogTimestamp,
                kraftVersion,
                voterSet,
                List.copyOf(records)
            );
        } catch (RewriteException exception) {
            throw exception;
        } catch (Exception exception) {
            throw new RewriteException("failed to read checkpoint: " + checkpointPath, exception);
        }
    }
}
