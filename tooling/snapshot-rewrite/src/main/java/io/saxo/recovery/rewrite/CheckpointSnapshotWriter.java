package io.saxo.recovery.rewrite;

import java.nio.file.Files;
import java.nio.file.Path;
import org.apache.kafka.metadata.MetadataRecordSerde;
import org.apache.kafka.snapshot.FileRawSnapshotWriter;
import org.apache.kafka.snapshot.RecordsSnapshotWriter;

final class CheckpointSnapshotWriter {
    private static final int MAX_BATCH_SIZE = 1024 * 1024;

    void write(Path outputPath, CheckpointSnapshot snapshot) {
        Path normalizedOutput = outputPath.toAbsolutePath().normalize();
        Path logDir = normalizedOutput.getParent();
        if (logDir == null) {
            throw new RewriteException("output checkpoint path has no parent directory: " + outputPath);
        }

        try {
            Files.createDirectories(logDir);
            Files.deleteIfExists(normalizedOutput);
            try (
                RecordsSnapshotWriter<?> writer = new RecordsSnapshotWriter.Builder()
                    .setRawSnapshotWriter(FileRawSnapshotWriter.create(logDir, snapshot.snapshotId()))
                    .setLastContainedLogTimestamp(snapshot.lastContainedLogTimestamp())
                    .setKraftVersion(snapshot.kraftVersion())
                    .setVoterSet(snapshot.voterSet())
                    .setMaxBatchSize(MAX_BATCH_SIZE)
                    .build(MetadataRecordSerde.INSTANCE)
            ) {
                @SuppressWarnings("unchecked")
                RecordsSnapshotWriter<org.apache.kafka.server.common.ApiMessageAndVersion> typedWriter =
                    (RecordsSnapshotWriter<org.apache.kafka.server.common.ApiMessageAndVersion>) writer;
                typedWriter.append(snapshot.records());
                typedWriter.freeze();
            }

            if (!Files.isRegularFile(normalizedOutput)) {
                throw new RewriteException("writer did not produce the expected checkpoint file: " + normalizedOutput);
            }
        } catch (RewriteException exception) {
            throw exception;
        } catch (Exception exception) {
            throw new RewriteException("failed to write checkpoint: " + outputPath, exception);
        }
    }
}
