package io.saxo.recovery.rewrite;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;
import java.util.Map;

@JsonInclude(JsonInclude.Include.NON_NULL)
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
record RewriteReport(
    int reportVersion,
    String status,
    CheckpointMetadata inputCheckpoint,
    CheckpointMetadata outputCheckpoint,
    List<Integer> survivingBrokers,
    String directoryMode,
    QuorumReport quorum,
    RecordsProcessed recordsProcessed,
    PartitionSummary partitions,
    List<MissingPartition> missingPartitions,
    List<String> warnings,
    List<String> errors
) {
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    record QuorumReport(
        boolean votersRecordPresent,
        boolean rewriteVotersRequested,
        boolean votersRewritten
    ) {
    }

    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    record RecordsProcessed(
        int total,
        Map<String, Integer> byType
    ) {
    }

    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    record PartitionSummary(
        int total,
        int rewritten,
        int leaderPreserved,
        int leaderReassigned,
        int missingSurvivors
    ) {
    }

    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    record MissingPartition(
        String topicName,
        int partition,
        List<Integer> originalReplicas,
        List<Integer> survivingReplicas
    ) {
    }
}
