package io.saxo.recovery.rewrite;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import org.apache.kafka.common.compress.Compression;
import org.apache.kafka.common.protocol.ObjectSerializationCache;
import org.apache.kafka.common.protocol.ByteBufferAccessor;
import org.apache.kafka.common.protocol.Readable;
import org.apache.kafka.common.record.FileRecords;
import org.apache.kafka.common.record.MemoryRecords;
import org.apache.kafka.common.record.Record;
import org.apache.kafka.common.record.RecordBatch;
import org.apache.kafka.common.record.SimpleRecord;
import org.apache.kafka.common.record.TimestampType;
import org.apache.kafka.metadata.MetadataRecordSerde;
import org.apache.kafka.server.common.ApiMessageAndVersion;

final class MetadataLogSegmentWriterTestSupport {
    private static final MetadataRecordSerde SERDE = MetadataRecordSerde.INSTANCE;

    void writeSingleRecordBatches(Path output, long firstOffset, ApiMessageAndVersion... records) throws IOException {
        for (int index = 0; index < records.length; index++) {
            writeBatch(output, firstOffset + index, records[index]);
        }
    }

    void writeBatch(Path output, long baseOffset, ApiMessageAndVersion... records) throws IOException {
        Files.createDirectories(output.toAbsolutePath().normalize().getParent());
        try (
            FileChannel channel = FileChannel.open(
                output,
                StandardOpenOption.CREATE,
                StandardOpenOption.WRITE,
                StandardOpenOption.APPEND
            )
        ) {
            SimpleRecord[] encodedRecords = new SimpleRecord[records.length];
            for (int index = 0; index < records.length; index++) {
                ByteBuffer value = serialize(records[index]);
                byte[] bytes = new byte[value.remaining()];
                value.get(bytes);
                encodedRecords[index] = new SimpleRecord(bytes);
            }
            MemoryRecords memoryRecords = MemoryRecords.withRecords(
                RecordBatch.CURRENT_MAGIC_VALUE,
                baseOffset,
                Compression.NONE,
                TimestampType.CREATE_TIME,
                encodedRecords
            );
            ByteBuffer buffer = memoryRecords.buffer().duplicate();
            while (buffer.hasRemaining()) {
                channel.write(buffer);
            }
        }
    }

    List<Long> batchOffsets(Path logPath) throws IOException {
        List<Long> offsets = new ArrayList<>();
        try (FileRecords records = FileRecords.open(logPath.toFile(), true)) {
            records.batches().forEach(batch -> offsets.add(batch.lastOffset()));
        }
        return offsets;
    }

    List<DecodedRecord> records(Path logPath) throws IOException {
        List<DecodedRecord> decoded = new ArrayList<>();
        try (FileRecords records = FileRecords.open(logPath.toFile(), true)) {
            for (org.apache.kafka.common.record.FileLogInputStream.FileChannelRecordBatch batch : records.batches()) {
                for (Record record : batch) {
                    decoded.add(new DecodedRecord(record.offset(), deserialize(record)));
                }
            }
        }
        return decoded;
    }

    List<BatchInfo> batchInfos(Path logPath) throws IOException {
        List<BatchInfo> batches = new ArrayList<>();
        try (FileRecords records = FileRecords.open(logPath.toFile(), true)) {
            long position = 0L;
            for (org.apache.kafka.common.record.FileLogInputStream.FileChannelRecordBatch batch : records.batches()) {
                batches.add(
                    new BatchInfo(
                        position,
                        batch.baseOffset(),
                        batch.lastOffset(),
                        batch.maxTimestamp(),
                        batch.sizeInBytes()
                    )
                );
                position += batch.sizeInBytes();
            }
        }
        return batches;
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

    record DecodedRecord(long offset, ApiMessageAndVersion record) {
    }

    record BatchInfo(long position, long baseOffset, long lastOffset, long maxTimestamp, int sizeInBytes) {
    }
}
