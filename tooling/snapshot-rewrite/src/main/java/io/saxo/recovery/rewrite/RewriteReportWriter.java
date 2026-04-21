package io.saxo.recovery.rewrite;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;

final class RewriteReportWriter {
    private final ObjectMapper objectMapper = new ObjectMapper()
        .enable(SerializationFeature.INDENT_OUTPUT);

    RewriteReport success(RewriteOptions options, CheckpointMetadata input, CheckpointMetadata output) {
        return success(options, input, output, RewriteOutcome.placeholder(options.rewriteVoters()));
    }

    RewriteReport success(RewriteOptions options, CheckpointMetadata input, CheckpointMetadata output, RewriteOutcome outcome) {
        return new RewriteReport(
            1,
            "success",
            input,
            output,
            options.survivingBrokers(),
            options.directoryMode().name(),
            outcome.quorum(),
            outcome.recordsProcessed(),
            outcome.partitionSummary(),
            outcome.missingPartitions(),
            outcome.warnings(),
            List.of()
        );
    }

    RewriteReport failure(RewriteOptions options, String errorMessage) {
        return failure(
            options,
            new RewriteAbortException(
                errorMessage,
                new RewriteReport.QuorumReport(false, options.rewriteVoters(), false),
                new RewriteReport.RecordsProcessed(0, RewriteStats.emptyRecordCounts()),
                new RewriteReport.PartitionSummary(0, 0, 0, 0, 0),
                List.of(),
                List.of()
            )
        );
    }

    RewriteReport failure(RewriteOptions options, RewriteAbortException failure) {
        return new RewriteReport(
            1,
            "failure",
            null,
            null,
            options.survivingBrokers(),
            options.directoryMode().name(),
            failure.quorum(),
            failure.recordsProcessed(),
            failure.partitionSummary(),
            failure.missingPartitions(),
            failure.warnings(),
            List.of(failure.getMessage())
        );
    }

    void write(Path reportPath, RewriteReport report) {
        try {
            Path parent = reportPath.toAbsolutePath().normalize().getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            objectMapper.writeValue(reportPath.toFile(), report);
        } catch (IOException exception) {
            throw new RewriteException("failed to write report: " + reportPath);
        }
    }
}
