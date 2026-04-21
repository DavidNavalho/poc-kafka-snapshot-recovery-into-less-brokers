package io.saxo.recovery.rewrite;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.apache.kafka.common.DirectoryId;
import org.apache.kafka.common.Uuid;
import org.apache.kafka.common.compress.Compression;
import org.apache.kafka.common.metadata.BrokerRegistrationChangeRecord;
import org.apache.kafka.common.metadata.NoOpRecord;
import org.apache.kafka.common.metadata.PartitionChangeRecord;
import org.apache.kafka.common.metadata.PartitionRecord;
import org.apache.kafka.common.metadata.RegisterBrokerRecord;
import org.apache.kafka.common.metadata.RegisterControllerRecord;
import org.apache.kafka.common.protocol.ObjectSerializationCache;
import org.apache.kafka.common.protocol.Readable;
import org.apache.kafka.common.protocol.ByteBufferAccessor;
import org.apache.kafka.common.record.CompressionType;
import org.apache.kafka.common.record.FileLogInputStream.FileChannelRecordBatch;
import org.apache.kafka.common.record.FileRecords;
import org.apache.kafka.common.record.MemoryRecords;
import org.apache.kafka.common.record.MemoryRecordsBuilder;
import org.apache.kafka.common.record.Record;
import org.apache.kafka.common.record.TimestampType;
import org.apache.kafka.metadata.MetadataRecordSerde;
import org.apache.kafka.server.common.ApiMessageAndVersion;

final class MetadataLogSegmentWriter {
    private static final int DEFAULT_MAX_INDEX_SIZE_BYTES = 10 * 1024 * 1024;
    private static final int OFFSET_INDEX_ENTRY_SIZE_BYTES = 8;
    private static final int TIME_INDEX_ENTRY_SIZE_BYTES = 12;
    private static final MetadataRecordSerde SERDE = MetadataRecordSerde.INSTANCE;
    private static final int LEADER_NO_CHANGE = -2;

    void rewrite(Path inputLogPath, Path outputLogPath, CheckpointSnapshot rewrittenSnapshot, RewriteOptions options) {
        Path normalizedInput = inputLogPath.toAbsolutePath().normalize();
        Path normalizedOutput = outputLogPath.toAbsolutePath().normalize();
        Path outputDir = normalizedOutput.getParent();
        if (outputDir == null) {
            throw new RewriteException("output metadata log path has no parent directory: " + outputLogPath);
        }
        if (!Files.isRegularFile(normalizedInput)) {
            throw new RewriteException("input metadata log does not exist: " + inputLogPath);
        }

        Map<TopicPartitionKey, PartitionTailState> partitionStates = partitionStatesFrom(rewrittenSnapshot.records());
        Set<Integer> survivingSet = new LinkedHashSet<>(options.survivingBrokers());

        try {
            Files.createDirectories(outputDir);
            Files.deleteIfExists(normalizedOutput);
            try (
                FileRecords inputRecords = FileRecords.open(normalizedInput.toFile(), true);
                FileChannel outputChannel = FileChannel.open(
                    normalizedOutput,
                    StandardOpenOption.CREATE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE
                )
            ) {
                long snapshotEndOffset = rewrittenSnapshot.snapshotId().offset();
                for (FileChannelRecordBatch batch : inputRecords.batches()) {
                    batch.ensureValid();
                    if (batch.lastOffset() < snapshotEndOffset) {
                        continue;
                    }
                    if (batch.baseOffset() < snapshotEndOffset) {
                        throw new RewriteException(
                            "snapshot offset " + snapshotEndOffset +
                                " falls in the middle of metadata batch " +
                                batch.baseOffset() + "-" + batch.lastOffset()
                        );
                    }
                    MemoryRecords rewrittenBatch = rewriteTailBatch(batch, partitionStates, survivingSet);
                    rewrittenBatch.writeFullyTo(outputChannel);
                }
                outputChannel.force(true);
            }
            writeKafkaSidecarIndexes(normalizedInput, normalizedOutput);
        } catch (RewriteException exception) {
            throw exception;
        } catch (IOException exception) {
            throw new RewriteException("failed to rewrite metadata log: " + outputLogPath, exception);
        }
    }

    void writeTruncated(Path inputLogPath, Path outputLogPath, long snapshotEndOffset) {
        Path normalizedInput = inputLogPath.toAbsolutePath().normalize();
        Path normalizedOutput = outputLogPath.toAbsolutePath().normalize();
        Path outputDir = normalizedOutput.getParent();
        if (outputDir == null) {
            throw new RewriteException("output metadata log path has no parent directory: " + outputLogPath);
        }
        if (!Files.isRegularFile(normalizedInput)) {
            throw new RewriteException("input metadata log does not exist: " + inputLogPath);
        }

        try {
            Files.createDirectories(outputDir);
            Files.deleteIfExists(normalizedOutput);
            try (
                FileRecords inputRecords = FileRecords.open(normalizedInput.toFile(), true);
                FileChannel outputChannel = FileChannel.open(
                    normalizedOutput,
                    StandardOpenOption.CREATE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE
                )
            ) {
                long lastRetainedOffset = -1L;
                boolean sawHigherOffset = false;

                for (FileChannelRecordBatch batch : inputRecords.batches()) {
                    batch.ensureValid();
                    if (batch.lastOffset() < snapshotEndOffset) {
                        writeRawBatch(batch, outputChannel);
                        lastRetainedOffset = batch.lastOffset();
                        continue;
                    }

                    sawHigherOffset = true;
                    if (batch.baseOffset() < snapshotEndOffset) {
                        throw new RewriteException(
                            "snapshot offset " + snapshotEndOffset +
                                " falls in the middle of metadata batch " +
                                batch.baseOffset() + "-" + batch.lastOffset()
                        );
                    }
                    break;
                }

                long expectedLastRetainedOffset = snapshotEndOffset - 1;
                if (lastRetainedOffset != expectedLastRetainedOffset) {
                    String detail = sawHigherOffset
                        ? "last retained offset was " + lastRetainedOffset
                        : "metadata log ended at offset " + lastRetainedOffset;
                    throw new RewriteException(
                        "metadata log truncation did not land immediately before snapshot offset " +
                            snapshotEndOffset + ": " + detail
                    );
                }
                outputChannel.force(true);
            }
            writeKafkaSidecarIndexes(normalizedInput, normalizedOutput);
        } catch (RewriteException exception) {
            throw exception;
        } catch (IOException exception) {
            throw new RewriteException(
                "failed to write truncated metadata log: " + outputLogPath,
                exception
            );
        }
    }

    private MemoryRecords rewriteTailBatch(
        FileChannelRecordBatch sourceBatch,
        Map<TopicPartitionKey, PartitionTailState> partitionStates,
        Set<Integer> survivingSet
    ) {
        if (sourceBatch.compressionType() != CompressionType.NONE) {
            throw new RewriteException("compressed metadata log batches are not supported");
        }

        ByteBuffer buffer = ByteBuffer.allocate(Math.max(sourceBatch.sizeInBytes() * 2, sourceBatch.sizeInBytes() + 256));
        MemoryRecordsBuilder builder = MemoryRecords.builder(
            buffer,
            sourceBatch.magic(),
            Compression.NONE,
            timestampTypeFor(sourceBatch),
            sourceBatch.baseOffset(),
            sourceBatch.maxTimestamp(),
            sourceBatch.producerId(),
            sourceBatch.producerEpoch(),
            sourceBatch.baseSequence(),
            sourceBatch.isTransactional(),
            sourceBatch.isControlBatch(),
            sourceBatch.partitionLeaderEpoch()
        );

        for (Record sourceRecord : sourceBatch) {
            ApiMessageAndVersion original = deserialize(sourceRecord);
            ApiMessageAndVersion rewritten = rewriteTailRecord(original, partitionStates, survivingSet);
            ByteBuffer value = serialize(rewritten);
            builder.appendWithOffset(sourceRecord.offset(), new org.apache.kafka.common.record.SimpleRecord(sourceRecord.timestamp(), null, value));
        }
        return builder.build();
    }

    private ApiMessageAndVersion rewriteTailRecord(
        ApiMessageAndVersion original,
        Map<TopicPartitionKey, PartitionTailState> partitionStates,
        Set<Integer> survivingSet
    ) {
        if (original.message() instanceof NoOpRecord) {
            return original;
        }

        if (original.message() instanceof BrokerRegistrationChangeRecord) {
            return new ApiMessageAndVersion(new NoOpRecord(), (short) 0);
        }

        if (original.message() instanceof RegisterBrokerRecord || original.message() instanceof RegisterControllerRecord) {
            return new ApiMessageAndVersion(new NoOpRecord(), (short) 0);
        }

        if (original.message() instanceof PartitionChangeRecord partitionChangeRecord) {
            TopicPartitionKey key = new TopicPartitionKey(partitionChangeRecord.topicId(), partitionChangeRecord.partitionId());
            PartitionTailState currentState = partitionStates.get(key);
            if (currentState == null) {
                throw new RewriteException("partition change references unknown partition after checkpoint rewrite: " + key);
            }

            PartitionChangeRecord rewritten = partitionChangeRecord.duplicate();
            List<Integer> effectiveReplicas = currentState.replicas();

            if (partitionChangeRecord.replicas() != null) {
                effectiveReplicas = filterSurviving(partitionChangeRecord.replicas(), survivingSet);
                if (effectiveReplicas.isEmpty()) {
                    throw new RewriteException("partition change leaves zero surviving replicas for " + key);
                }
                rewritten.setReplicas(effectiveReplicas);
            }

            if (partitionChangeRecord.isr() != null) {
                List<Integer> effectiveIsr = filterSurviving(partitionChangeRecord.isr(), survivingSet);
                rewritten.setIsr(effectiveIsr.isEmpty() ? effectiveReplicas : effectiveIsr);
            }

            if (partitionChangeRecord.removingReplicas() != null) {
                rewritten.setRemovingReplicas(filterSurviving(partitionChangeRecord.removingReplicas(), survivingSet));
            }

            if (partitionChangeRecord.addingReplicas() != null) {
                rewritten.setAddingReplicas(filterSurviving(partitionChangeRecord.addingReplicas(), survivingSet));
            }

            if (partitionChangeRecord.eligibleLeaderReplicas() != null) {
                rewritten.setEligibleLeaderReplicas(List.of());
            }

            if (partitionChangeRecord.lastKnownElr() != null) {
                rewritten.setLastKnownElr(List.of());
            }

            if (partitionChangeRecord.leader() != LEADER_NO_CHANGE) {
                int rewrittenLeader = survivingSet.contains(partitionChangeRecord.leader())
                    ? partitionChangeRecord.leader()
                    : effectiveReplicas.getFirst();
                rewritten.setLeader(rewrittenLeader);
            }

            if (partitionChangeRecord.directories() != null || partitionChangeRecord.replicas() != null) {
                rewritten.setDirectories(List.of(DirectoryId.unassignedArray(effectiveReplicas.size())));
            }

            partitionStates.put(key, applyChange(currentState, rewritten));
            return new ApiMessageAndVersion(rewritten, original.version());
        }

        throw new RewriteException(
            "unsupported metadata log tail record type after checkpoint rewrite: " +
                original.message().getClass().getSimpleName()
        );
    }

    private PartitionTailState applyChange(PartitionTailState currentState, PartitionChangeRecord record) {
        List<Integer> replicas = record.replicas() != null ? record.replicas() : currentState.replicas();
        List<Integer> isr = record.isr() != null ? record.isr() : currentState.isr();
        int leader = record.leader() != LEADER_NO_CHANGE ? record.leader() : currentState.leader();
        return new PartitionTailState(replicas, isr, leader);
    }

    private Map<TopicPartitionKey, PartitionTailState> partitionStatesFrom(List<ApiMessageAndVersion> records) {
        Map<TopicPartitionKey, PartitionTailState> partitionStates = new HashMap<>();
        for (ApiMessageAndVersion record : records) {
            if (record.message() instanceof PartitionRecord partitionRecord) {
                partitionStates.put(
                    new TopicPartitionKey(partitionRecord.topicId(), partitionRecord.partitionId()),
                    new PartitionTailState(partitionRecord.replicas(), partitionRecord.isr(), partitionRecord.leader())
                );
            }
        }
        return partitionStates;
    }

    private TimestampType timestampTypeFor(FileChannelRecordBatch batch) {
        TimestampType timestampType = batch.timestampType();
        return timestampType == TimestampType.NO_TIMESTAMP_TYPE ? TimestampType.CREATE_TIME : timestampType;
    }

    private ApiMessageAndVersion deserialize(Record record) {
        ByteBuffer value = record.value().duplicate();
        Readable readable = new ByteBufferAccessor(value);
        return SERDE.read(readable, value.remaining());
    }

    private ByteBuffer serialize(ApiMessageAndVersion record) {
        ObjectSerializationCache cache = new ObjectSerializationCache();
        ByteBuffer buffer = ByteBuffer.allocate(SERDE.recordSize(record, cache));
        SERDE.write(record, cache, new ByteBufferAccessor(buffer));
        buffer.flip();
        return buffer;
    }

    private List<Integer> filterSurviving(List<Integer> brokerIds, Set<Integer> survivingSet) {
        return brokerIds.stream().filter(survivingSet::contains).toList();
    }

    private void writeRawBatch(FileChannelRecordBatch batch, FileChannel outputChannel) throws IOException {
        ByteBuffer buffer = ByteBuffer.allocate(batch.sizeInBytes());
        batch.writeTo(buffer);
        buffer.flip();
        while (buffer.hasRemaining()) {
            outputChannel.write(buffer);
        }
    }

    private void writeKafkaSidecarIndexes(Path inputLogPath, Path outputLogPath) throws IOException {
        Path offsetIndexPath = siblingPath(outputLogPath, ".index");
        Path timeIndexPath = siblingPath(outputLogPath, ".timeindex");
        int offsetIndexSize = resolveIndexSize(siblingPath(inputLogPath, ".index"), OFFSET_INDEX_ENTRY_SIZE_BYTES);
        int timeIndexSize = resolveIndexSize(siblingPath(inputLogPath, ".timeindex"), TIME_INDEX_ENTRY_SIZE_BYTES);
        long baseOffset = metadataSegmentBaseOffset(outputLogPath);

        try (
            FileRecords outputRecords = FileRecords.open(outputLogPath.toFile(), true);
            FileChannel offsetIndexChannel = openPreallocatedIndex(offsetIndexPath, offsetIndexSize);
            FileChannel timeIndexChannel = openPreallocatedIndex(timeIndexPath, timeIndexSize)
        ) {
            long position = 0L;
            long lastIndexedTimestamp = Long.MIN_VALUE;
            long lastTimeIndexOffset = baseOffset - 1L;
            int offsetEntriesWritten = 0;
            int timeEntriesWritten = 0;

            for (FileChannelRecordBatch batch : outputRecords.batches()) {
                batch.ensureValid();
                writeOffsetIndexEntry(offsetIndexChannel, baseOffset, batch.lastOffset(), position, offsetIndexSize, offsetEntriesWritten);
                offsetEntriesWritten++;

                long maxTimestamp = batch.maxTimestamp();
                if (maxTimestamp >= 0 && maxTimestamp > lastIndexedTimestamp && batch.lastOffset() > lastTimeIndexOffset) {
                    writeTimeIndexEntry(timeIndexChannel, baseOffset, maxTimestamp, batch.lastOffset(), timeIndexSize, timeEntriesWritten);
                    lastIndexedTimestamp = maxTimestamp;
                    lastTimeIndexOffset = batch.lastOffset();
                    timeEntriesWritten++;
                }

                position += batch.sizeInBytes();
            }

            offsetIndexChannel.force(true);
            timeIndexChannel.force(true);
        }
    }

    private Path siblingPath(Path logPath, String newSuffix) {
        String fileName = logPath.getFileName().toString();
        String baseName = fileName.endsWith(".log")
            ? fileName.substring(0, fileName.length() - ".log".length())
            : fileName;
        return logPath.resolveSibling(baseName + newSuffix);
    }

    private int resolveIndexSize(Path sourceIndexPath, int entrySizeBytes) throws IOException {
        long requestedSize = Files.isRegularFile(sourceIndexPath)
            ? Files.size(sourceIndexPath)
            : DEFAULT_MAX_INDEX_SIZE_BYTES;
        long alignedSize = requestedSize - (requestedSize % entrySizeBytes);
        if (alignedSize < entrySizeBytes) {
            alignedSize = entrySizeBytes;
        }
        if (alignedSize > Integer.MAX_VALUE) {
            throw new RewriteException("metadata index size exceeds supported limit: " + sourceIndexPath);
        }
        return (int) alignedSize;
    }

    private long metadataSegmentBaseOffset(Path outputLogPath) {
        String fileName = outputLogPath.getFileName().toString();
        String candidate = fileName.endsWith(".log")
            ? fileName.substring(0, fileName.length() - ".log".length())
            : fileName;
        if (!candidate.isEmpty() && candidate.chars().allMatch(Character::isDigit)) {
            try {
                return Long.parseLong(candidate);
            } catch (NumberFormatException ignored) {
                return 0L;
            }
        }
        return 0L;
    }

    private FileChannel openPreallocatedIndex(Path indexPath, int sizeBytes) throws IOException {
        Files.createDirectories(indexPath.toAbsolutePath().normalize().getParent());
        FileChannel channel = FileChannel.open(
            indexPath,
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING,
            StandardOpenOption.WRITE
        );
        if (sizeBytes > 0) {
            channel.position(sizeBytes - 1L);
            channel.write(ByteBuffer.wrap(new byte[] {0}));
            channel.position(0L);
        }
        return channel;
    }

    private void writeOffsetIndexEntry(
        FileChannel channel,
        long baseOffset,
        long offset,
        long position,
        int indexSizeBytes,
        int entriesWritten
    ) throws IOException {
        ensureCapacity(indexSizeBytes, OFFSET_INDEX_ENTRY_SIZE_BYTES, entriesWritten, "offset");
        ByteBuffer entry = ByteBuffer.allocate(OFFSET_INDEX_ENTRY_SIZE_BYTES);
        entry.putInt(relativeOffset(baseOffset, offset));
        entry.putInt(Math.toIntExact(position));
        entry.flip();
        while (entry.hasRemaining()) {
            channel.write(entry);
        }
    }

    private void writeTimeIndexEntry(
        FileChannel channel,
        long baseOffset,
        long timestamp,
        long offset,
        int indexSizeBytes,
        int entriesWritten
    ) throws IOException {
        ensureCapacity(indexSizeBytes, TIME_INDEX_ENTRY_SIZE_BYTES, entriesWritten, "time");
        ByteBuffer entry = ByteBuffer.allocate(TIME_INDEX_ENTRY_SIZE_BYTES);
        entry.putLong(timestamp);
        entry.putInt(relativeOffset(baseOffset, offset));
        entry.flip();
        while (entry.hasRemaining()) {
            channel.write(entry);
        }
    }

    private void ensureCapacity(int indexSizeBytes, int entrySizeBytes, int entriesWritten, String indexType) {
        long usedBytes = (long) entriesWritten * entrySizeBytes;
        if (usedBytes + entrySizeBytes > indexSizeBytes) {
            throw new RewriteException("rewritten metadata " + indexType + " index exceeded max size");
        }
    }

    private int relativeOffset(long baseOffset, long offset) {
        long relativeOffset = offset - baseOffset;
        if (relativeOffset < 0 || relativeOffset > Integer.MAX_VALUE) {
            throw new RewriteException("metadata log offset cannot be indexed relative to base offset " + baseOffset + ": " + offset);
        }
        return Math.toIntExact(relativeOffset);
    }

    private record TopicPartitionKey(Uuid topicId, int partitionId) {
        @Override
        public String toString() {
            return topicId + "-" + partitionId;
        }
    }

    private record PartitionTailState(List<Integer> replicas, List<Integer> isr, int leader) {
    }
}
