package io.saxo.recovery.rewrite;

import java.util.List;

record RewriteOutcome(
    List<MetadataRecordModel> records,
    RewriteReport.QuorumReport quorum,
    RewriteReport.RecordsProcessed recordsProcessed,
    RewriteReport.PartitionSummary partitionSummary,
    List<RewriteReport.MissingPartition> missingPartitions,
    List<String> warnings
) {
    static RewriteOutcome placeholder(boolean rewriteVotersRequested) {
        return new RewriteOutcome(
            List.of(),
            new RewriteReport.QuorumReport(false, rewriteVotersRequested, false),
            new RewriteReport.RecordsProcessed(0, RewriteStats.emptyRecordCounts()),
            new RewriteReport.PartitionSummary(0, 0, 0, 0, 0),
            List.of(),
            List.of("phase-1 scaffold copied checkpoint bytes without record-level rewrites")
        );
    }
}
