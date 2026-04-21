package io.saxo.recovery.rewrite;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

final class RecordRewriter {
    RewriteOutcome rewrite(List<? extends MetadataRecordModel> records, RewritePlan plan) {
        List<MetadataRecordModel> rewritten = new ArrayList<>();
        List<String> warnings = new ArrayList<>();
        var counts = RewriteStats.emptyRecordCounts();
        int totalRecords = 0;
        int partitionTotal = 0;
        int partitionRewritten = 0;
        int leaderPreserved = 0;
        int leaderReassigned = 0;
        int missingSurvivors = 0;
        boolean votersRecordPresent = false;
        boolean votersRewritten = false;
        Set<Integer> survivingSet = new LinkedHashSet<>(plan.survivingBrokers());

        for (MetadataRecordModel record : records) {
            totalRecords++;
            counts.compute(record.recordType(), (key, value) -> value == null ? 1 : value + 1);

            if (record instanceof PartitionRecordModel partition) {
                partitionTotal++;
                List<Integer> survivingReplicas = partition.replicas().stream()
                    .filter(survivingSet::contains)
                    .toList();
                if (survivingReplicas.isEmpty()) {
                    missingSurvivors++;
                    List<RewriteReport.MissingPartition> missingPartitions = List.of(
                        new RewriteReport.MissingPartition(
                            partition.topicName(),
                            partition.partitionId(),
                            partition.replicas(),
                            survivingReplicas
                        )
                    );
                    throw new RewriteAbortException(
                        "missing surviving replicas for " + partition.topicName() + "-" + partition.partitionId(),
                        new RewriteReport.QuorumReport(votersRecordPresent, plan.rewriteVoters(), votersRewritten),
                        new RewriteReport.RecordsProcessed(totalRecords, counts),
                        new RewriteReport.PartitionSummary(
                            partitionTotal,
                            partitionRewritten,
                            leaderPreserved,
                            leaderReassigned,
                            missingSurvivors
                        ),
                        missingPartitions,
                        warnings
                    );
                }

                boolean preserved = survivingSet.contains(partition.leaderId());
                int leaderId = preserved ? partition.leaderId() : survivingReplicas.getFirst();
                List<String> directories = survivingReplicas.stream()
                    .map(replica -> plan.directoryMode().name())
                    .toList();
                rewritten.add(
                    new PartitionRecordModel(
                        partition.topicName(),
                        partition.partitionId(),
                        survivingReplicas,
                        survivingReplicas,
                        leaderId,
                        partition.leaderEpoch() + 1,
                        partition.partitionEpoch() + 1,
                        directories
                    )
                );
                partitionRewritten++;
                if (preserved) {
                    leaderPreserved++;
                } else {
                    leaderReassigned++;
                }
                continue;
            }

            if (record instanceof RegisterBrokerRecordModel) {
                continue;
            }

            if (record instanceof VotersRecordModel) {
                votersRecordPresent = true;
                if (!plan.rewriteVoters()) {
                    throw new RewriteAbortException(
                        "VotersRecord present but --rewrite-voters was not provided",
                        new RewriteReport.QuorumReport(true, false, false),
                        new RewriteReport.RecordsProcessed(totalRecords, counts),
                        new RewriteReport.PartitionSummary(
                            partitionTotal,
                            partitionRewritten,
                            leaderPreserved,
                            leaderReassigned,
                            missingSurvivors
                        ),
                        List.of(),
                        warnings
                    );
                }
                rewritten.add(new VotersRecordModel(plan.survivingBrokers()));
                votersRewritten = true;
                continue;
            }

            rewritten.add(record);
        }

        if (plan.rewriteVoters() && !votersRecordPresent) {
            warnings.add("--rewrite-voters was requested but no VotersRecord was present in the input");
        }

        return new RewriteOutcome(
            List.copyOf(rewritten),
            new RewriteReport.QuorumReport(votersRecordPresent, plan.rewriteVoters(), votersRewritten),
            new RewriteReport.RecordsProcessed(totalRecords, counts),
            new RewriteReport.PartitionSummary(
                partitionTotal,
                partitionRewritten,
                leaderPreserved,
                leaderReassigned,
                missingSurvivors
            ),
            List.of(),
            List.copyOf(warnings)
        );
    }
}
