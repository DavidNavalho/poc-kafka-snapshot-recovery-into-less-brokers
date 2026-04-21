package io.saxo.recovery.rewrite;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;

class RewriteReportWriterTest {
    @Test
    void buildsSuccessReportFromRewriteOutcome() {
        RewriteOptions options = new RewriteOptions(
            Path.of("/tmp/input.checkpoint"),
            Path.of("/tmp/output.checkpoint"),
            List.of(0, 1, 2),
            DirectoryMode.UNASSIGNED,
            true,
            Path.of("/tmp/report.json"),
            Optional.empty(),
            Optional.empty()
        );
        CheckpointMetadata input = new CheckpointMetadata(
            "/tmp/input.checkpoint",
            "00000000000000008030-0000000001.checkpoint",
            8030,
            1,
            "input-sha"
        );
        CheckpointMetadata output = new CheckpointMetadata(
            "/tmp/output.checkpoint",
            "00000000000000008030-0000000001.checkpoint",
            8030,
            1,
            "output-sha"
        );
        LinkedHashMap<String, Integer> byType = new LinkedHashMap<>();
        byType.put("PartitionRecord", 2);
        byType.put("RegisterBrokerRecord", 3);
        byType.put("TopicRecord", 1);
        byType.put("ConfigRecord", 4);
        byType.put("VotersRecord", 1);
        RewriteOutcome outcome = new RewriteOutcome(
            List.of(new TopicRecordModel("orders")),
            new RewriteReport.QuorumReport(true, true, true),
            new RewriteReport.RecordsProcessed(11, byType),
            new RewriteReport.PartitionSummary(2, 2, 1, 1, 0),
            List.of(),
            List.of("note")
        );

        RewriteReport report = new RewriteReportWriter().success(options, input, output, outcome);

        assertEquals("success", report.status());
        assertEquals(input, report.inputCheckpoint());
        assertEquals(output, report.outputCheckpoint());
        assertEquals(true, report.quorum().votersRewritten());
        assertEquals(11, report.recordsProcessed().total());
        assertEquals(2, report.partitions().total());
        assertEquals(List.of("note"), report.warnings());
        assertEquals(List.of(), report.errors());
    }

    @Test
    void buildsFailureReportWithMissingPartitions() {
        RewriteOptions options = new RewriteOptions(
            Path.of("/tmp/input.checkpoint"),
            Path.of("/tmp/output.checkpoint"),
            List.of(0, 1, 2),
            DirectoryMode.UNASSIGNED,
            false,
            Path.of("/tmp/report.json"),
            Optional.empty(),
            Optional.empty()
        );
        RewriteAbortException failure = new RewriteAbortException(
            "missing surviving replicas",
            new RewriteReport.QuorumReport(false, false, false),
            new RewriteReport.RecordsProcessed(1, RewriteStats.emptyRecordCounts()),
            new RewriteReport.PartitionSummary(1, 0, 0, 0, 1),
            List.of(new RewriteReport.MissingPartition("orders", 3, List.of(4, 5, 6), List.of())),
            List.of()
        );

        RewriteReport report = new RewriteReportWriter().failure(options, failure);

        assertEquals("failure", report.status());
        assertNull(report.inputCheckpoint());
        assertNull(report.outputCheckpoint());
        assertEquals(1, report.missingPartitions().size());
        assertEquals("orders", report.missingPartitions().getFirst().topicName());
        assertTrue(report.errors().contains("missing surviving replicas"));
        assertEquals(1, report.partitions().missingSurvivors());
    }
}
