package io.saxo.recovery.rewrite;

import java.util.List;

final class RewriteAbortException extends RuntimeException {
    private final RewriteReport.QuorumReport quorum;
    private final RewriteReport.RecordsProcessed recordsProcessed;
    private final RewriteReport.PartitionSummary partitionSummary;
    private final List<RewriteReport.MissingPartition> missingPartitions;
    private final List<String> warnings;

    RewriteAbortException(
        String message,
        RewriteReport.QuorumReport quorum,
        RewriteReport.RecordsProcessed recordsProcessed,
        RewriteReport.PartitionSummary partitionSummary,
        List<RewriteReport.MissingPartition> missingPartitions,
        List<String> warnings
    ) {
        super(message);
        this.quorum = quorum;
        this.recordsProcessed = recordsProcessed;
        this.partitionSummary = partitionSummary;
        this.missingPartitions = List.copyOf(missingPartitions);
        this.warnings = List.copyOf(warnings);
    }

    RewriteReport.QuorumReport quorum() {
        return quorum;
    }

    RewriteReport.RecordsProcessed recordsProcessed() {
        return recordsProcessed;
    }

    RewriteReport.PartitionSummary partitionSummary() {
        return partitionSummary;
    }

    List<RewriteReport.MissingPartition> missingPartitions() {
        return missingPartitions;
    }

    List<String> warnings() {
        return warnings;
    }
}
