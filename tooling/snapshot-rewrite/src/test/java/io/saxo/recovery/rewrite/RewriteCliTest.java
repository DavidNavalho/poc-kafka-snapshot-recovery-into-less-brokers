package io.saxo.recovery.rewrite;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Optional;
import org.apache.kafka.common.Uuid;
import org.apache.kafka.common.metadata.BrokerRegistrationChangeRecord;
import org.apache.kafka.common.metadata.NoOpRecord;
import org.apache.kafka.common.metadata.TopicRecord;
import org.apache.kafka.server.common.ApiMessageAndVersion;
import org.apache.kafka.server.common.KRaftVersion;
import org.apache.kafka.server.common.OffsetAndEpoch;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class RewriteCliTest {
    private final ObjectMapper objectMapper = new ObjectMapper();

    @TempDir
    Path tempDir;

    @Test
    void rejectsMissingRequiredArguments() {
        RewriteCli cli = new RewriteCli();
        ByteArrayOutputStream stdout = new ByteArrayOutputStream();
        ByteArrayOutputStream stderr = new ByteArrayOutputStream();

        int exitCode = cli.run(new String[0], new PrintStream(stdout), new PrintStream(stderr));

        assertEquals(2, exitCode);
        assertTrue(stderr.toString().contains("missing required arguments"));
        assertTrue(stderr.toString().contains("usage: snapshot-rewrite-tool"));
        assertEquals("", stdout.toString());
    }

    @Test
    void rejectsUnsupportedDirectoryMode() throws IOException {
        Path input = writeCheckpoint("00000000000000008030-0000000001.checkpoint", "sample-checkpoint");
        Path output = tempDir.resolve("out").resolve(input.getFileName().toString());
        Path report = tempDir.resolve("report.json");

        RewriteCli cli = new RewriteCli();
        ByteArrayOutputStream stderr = new ByteArrayOutputStream();

        int exitCode = cli.run(
            new String[] {
                "--input", input.toString(),
                "--output", output.toString(),
                "--surviving-brokers", "0,1,2",
                "--directory-mode", "KEEP",
                "--report", report.toString()
            },
            new PrintStream(new ByteArrayOutputStream()),
            new PrintStream(stderr)
        );

        assertEquals(2, exitCode);
        assertTrue(stderr.toString().contains("unsupported directory mode"));
        assertFalse(Files.exists(report));
    }

    @Test
    void copiesCheckpointAndWritesSuccessReport() throws IOException {
        Path input = writeRealCheckpoint("00000000000000008030-0000000001.checkpoint");
        Path output = tempDir.resolve("artifacts").resolve(input.getFileName().toString());
        Path report = tempDir.resolve("reports").resolve("rewrite-report.json");

        RewriteCli cli = new RewriteCli();
        ByteArrayOutputStream stdout = new ByteArrayOutputStream();
        ByteArrayOutputStream stderr = new ByteArrayOutputStream();

        int exitCode = cli.run(
            new String[] {
                "--input", input.toString(),
                "--output", output.toString(),
                "--surviving-brokers", "2,0,1",
                "--directory-mode", "UNASSIGNED",
                "--report", report.toString()
            },
            new PrintStream(stdout),
            new PrintStream(stderr)
        );

        assertEquals(0, exitCode);
        assertTrue(Files.exists(output));
        assertTrue(stdout.toString().contains("rewrote checkpoint to"));
        assertEquals("", stderr.toString());

        JsonNode json = objectMapper.readTree(report.toFile());
        assertEquals("success", json.get("status").asText());
        assertEquals(1, json.get("report_version").asInt());
        assertEquals("UNASSIGNED", json.get("directory_mode").asText());
        assertEquals(false, json.get("quorum").get("rewrite_voters_requested").asBoolean());
        assertEquals(1, json.get("records_processed").get("total").asInt());
        assertEquals(1, json.get("records_processed").get("by_type").get("TopicRecord").asInt());
        assertEquals(0, json.get("partitions").get("total").asInt());
        assertEquals(3, json.get("surviving_brokers").size());
        assertEquals(0, json.get("surviving_brokers").get(0).asInt());
        assertEquals(1, json.get("surviving_brokers").get(1).asInt());
        assertEquals(2, json.get("surviving_brokers").get(2).asInt());
        assertNotNull(json.get("input_checkpoint").get("sha256").asText());
        assertEquals(input.getFileName().toString(), json.get("output_checkpoint").get("basename").asText());
        assertEquals(0, json.get("warnings").size());
        assertTrue(json.get("errors").isArray());
        assertEquals(0, json.get("errors").size());
    }

    @Test
    void rewritesMetadataLogWhenRequested() throws Exception {
        Path input = writeRealCheckpoint("00000000000000008030-0000000001.checkpoint");
        Path output = tempDir.resolve("artifacts").resolve(input.getFileName().toString());
        Path report = tempDir.resolve("reports").resolve("rewrite-report.json");
        Path metadataInput = tempDir.resolve("metadata").resolve("00000000000000000000.log");
        Path metadataOutput = tempDir.resolve("artifacts").resolve("00000000000000000000.log");
        MetadataLogSegmentWriterTestSupport support = new MetadataLogSegmentWriterTestSupport();
        support.writeSingleRecordBatches(
            metadataInput,
            8030L,
            new ApiMessageAndVersion(new NoOpRecord(), (short) 0),
            new ApiMessageAndVersion(
                new BrokerRegistrationChangeRecord()
                    .setBrokerId(8)
                    .setBrokerEpoch(1L)
                    .setFenced((byte) 0)
                    .setInControlledShutdown((byte) 0)
                    .setLogDirs(List.of()),
                (short) 0
            )
        );

        RewriteCli cli = new RewriteCli();
        ByteArrayOutputStream stdout = new ByteArrayOutputStream();
        ByteArrayOutputStream stderr = new ByteArrayOutputStream();

        int exitCode = cli.run(
            new String[] {
                "--input", input.toString(),
                "--output", output.toString(),
                "--surviving-brokers", "2,0,1",
                "--directory-mode", "UNASSIGNED",
                "--report", report.toString(),
                "--metadata-log-input", metadataInput.toString(),
                "--metadata-log-output", metadataOutput.toString()
            },
            new PrintStream(stdout),
            new PrintStream(stderr)
        );

        assertEquals(0, exitCode);
        assertTrue(Files.exists(metadataOutput));
        assertTrue(Files.exists(metadataOutput.resolveSibling("00000000000000000000.index")));
        assertTrue(Files.exists(metadataOutput.resolveSibling("00000000000000000000.timeindex")));
        assertTrue(stdout.toString().contains("rewrote metadata log to"));
        assertEquals("", stderr.toString());
        List<MetadataLogSegmentWriterTestSupport.DecodedRecord> rewrittenRecords = support.records(metadataOutput);
        assertEquals(List.of(8030L, 8031L), rewrittenRecords.stream().map(MetadataLogSegmentWriterTestSupport.DecodedRecord::offset).toList());
        assertTrue(rewrittenRecords.get(0).record().message() instanceof NoOpRecord);
        assertTrue(rewrittenRecords.get(1).record().message() instanceof NoOpRecord);
    }

    private Path writeCheckpoint(String fileName, String content) throws IOException {
        Path input = tempDir.resolve(fileName);
        Files.writeString(input, content);
        return input;
    }

    private Path writeRealCheckpoint(String fileName) {
        Path input = tempDir.resolve(fileName);
        Uuid topicId = Uuid.randomUuid();
        CheckpointSnapshot snapshot = new CheckpointSnapshot(
            new OffsetAndEpoch(8030L, 1),
            123L,
            KRaftVersion.KRAFT_VERSION_0,
            Optional.empty(),
            List.of(new ApiMessageAndVersion(new TopicRecord().setName("orders").setTopicId(topicId), (short) 0))
        );
        new CheckpointSnapshotWriter().write(input, snapshot);
        return input;
    }
}
