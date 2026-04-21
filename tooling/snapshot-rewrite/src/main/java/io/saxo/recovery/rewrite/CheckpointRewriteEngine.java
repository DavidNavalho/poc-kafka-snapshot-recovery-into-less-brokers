package io.saxo.recovery.rewrite;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;
import org.apache.kafka.common.DirectoryId;
import org.apache.kafka.common.Uuid;
import org.apache.kafka.common.metadata.PartitionRecord;
import org.apache.kafka.common.metadata.RegisterBrokerRecord;
import org.apache.kafka.common.metadata.RegisterControllerRecord;
import org.apache.kafka.common.metadata.TopicRecord;
import org.apache.kafka.raft.VoterSet;
import org.apache.kafka.server.common.ApiMessageAndVersion;
import org.apache.kafka.server.common.KRaftVersion;

final class CheckpointRewriteEngine {
    RewriteExecutionResult rewrite(CheckpointSnapshot inputSnapshot, RewriteOptions options) {
        if (inputSnapshot.voterSet().isPresent() && !options.rewriteVoters()) {
            throw new RewriteAbortException(
                "VotersRecord present but --rewrite-voters was not provided",
                new RewriteReport.QuorumReport(true, false, false),
                recordsProcessed(1, true),
                new RewriteReport.PartitionSummary(0, 0, 0, 0, 0),
                List.of(),
                List.of()
            );
        }

        if (inputSnapshot.voterSet().isPresent() && !inputSnapshot.kraftVersion().isReconfigSupported()) {
            throw new RewriteAbortException(
                "checkpoint contains voters state but KRaft version does not support reconfiguration",
                new RewriteReport.QuorumReport(true, options.rewriteVoters(), false),
                recordsProcessed(1, true),
                new RewriteReport.PartitionSummary(0, 0, 0, 0, 0),
                List.of(),
                List.of()
            );
        }

        Set<Integer> survivingSet = new LinkedHashSet<>(options.survivingBrokers());
        Map<Uuid, String> topicNamesById = collectTopicNames(inputSnapshot.records());
        List<ApiMessageAndVersion> rewrittenRecords = new ArrayList<>();
        List<RewriteReport.MissingPartition> missingPartitions = new ArrayList<>();
        List<String> warnings = new ArrayList<>();
        LinkedHashMap<String, Integer> recordCounts = RewriteStats.emptyRecordCounts();

        int totalRecords = inputSnapshot.records().size();
        if (inputSnapshot.voterSet().isPresent()) {
            incrementCount(recordCounts, "VotersRecord");
            totalRecords++;
        }

        int partitionTotal = 0;
        int partitionRewritten = 0;
        int leaderPreserved = 0;
        int leaderReassigned = 0;
        int missingSurvivors = 0;
        boolean partitionReplicaOverrideApplied = false;

        for (ApiMessageAndVersion record : inputSnapshot.records()) {
            incrementCount(recordCounts, record.message().getClass().getSimpleName());

            if (record.message() instanceof TopicRecord topicRecord) {
                rewrittenRecords.add(record);
                topicNamesById.put(topicRecord.topicId(), topicRecord.name());
                continue;
            }

            if (record.message() instanceof RegisterBrokerRecord) {
                continue;
            }

            if (record.message() instanceof RegisterControllerRecord) {
                continue;
            }

            if (record.message() instanceof PartitionRecord partitionRecord) {
                partitionTotal++;
                String topicName = topicNamesById.getOrDefault(partitionRecord.topicId(), partitionRecord.topicId().toString());
                Optional<PartitionReplicaOverride> partitionReplicaOverride = matchingPartitionReplicaOverride(
                    options.partitionReplicaOverride(),
                    topicName,
                    partitionRecord.partitionId()
                );
                List<Integer> survivingReplicas = partitionRecord.replicas()
                    .stream()
                    .filter(survivingSet::contains)
                    .toList();

                if (survivingReplicas.isEmpty() && partitionReplicaOverride.isEmpty()) {
                    missingSurvivors++;
                    missingPartitions.add(
                        new RewriteReport.MissingPartition(
                            topicName,
                            partitionRecord.partitionId(),
                            partitionRecord.replicas(),
                            List.of()
                        )
                    );
                    continue;
                }

                boolean preserveLeader = partitionReplicaOverride
                    .map(override -> override.leaderId() == partitionRecord.leader())
                    .orElseGet(() -> survivingSet.contains(partitionRecord.leader()));
                int rewrittenLeader = partitionReplicaOverride
                    .map(PartitionReplicaOverride::leaderId)
                    .orElseGet(() -> preserveLeader ? partitionRecord.leader() : survivingReplicas.getFirst());
                PartitionRecord rewrittenPartition = partitionRecord.duplicate()
                    .setReplicas(survivingReplicas)
                    .setIsr(survivingReplicas)
                    .setRemovingReplicas(filterSurviving(partitionRecord.removingReplicas(), survivingSet))
                    .setAddingReplicas(filterSurviving(partitionRecord.addingReplicas(), survivingSet))
                    .setLeader(rewrittenLeader)
                    .setLeaderEpoch(partitionRecord.leaderEpoch() + 1)
                    .setPartitionEpoch(partitionRecord.partitionEpoch() + 1)
                    .setDirectories(List.of(DirectoryId.unassignedArray(survivingReplicas.size())))
                    .setEligibleLeaderReplicas(List.of())
                    .setLastKnownElr(List.of());
                if (partitionReplicaOverride.isPresent()) {
                    rewrittenPartition = applyPartitionReplicaOverride(rewrittenPartition, partitionReplicaOverride.orElseThrow());
                    partitionReplicaOverrideApplied = true;
                }
                rewrittenRecords.add(new ApiMessageAndVersion(rewrittenPartition, record.version()));
                partitionRewritten++;
                if (preserveLeader) {
                    leaderPreserved++;
                } else {
                    leaderReassigned++;
                }
                continue;
            }

            rewrittenRecords.add(record);
        }

        Optional<VoterSet> outputVoterSet = inputSnapshot.voterSet();
        boolean votersRewritten = false;
        if (inputSnapshot.voterSet().isPresent()) {
            outputVoterSet = Optional.of(filterVoterSet(inputSnapshot.voterSet().get(), survivingSet));
            votersRewritten = true;
        } else if (options.rewriteVoters()) {
            warnings.add("--rewrite-voters was requested but no VotersRecord was present in the input");
        }

        RewriteReport.PartitionSummary partitionSummary = new RewriteReport.PartitionSummary(
            partitionTotal,
            partitionRewritten,
            leaderPreserved,
            leaderReassigned,
            missingSurvivors
        );
        RewriteReport.QuorumReport quorumReport = new RewriteReport.QuorumReport(
            inputSnapshot.voterSet().isPresent(),
            options.rewriteVoters(),
            votersRewritten
        );

        if (options.partitionReplicaOverride().isPresent() && !partitionReplicaOverrideApplied) {
            PartitionReplicaOverride partitionReplicaOverride = options.partitionReplicaOverride().orElseThrow();
            throw new RewriteAbortException(
                "fault override target not found in checkpoint: " +
                    partitionReplicaOverride.topicName() + "-" + partitionReplicaOverride.partitionId(),
                quorumReport,
                new RewriteReport.RecordsProcessed(totalRecords, recordCounts),
                partitionSummary,
                List.of(),
                List.copyOf(warnings)
            );
        }

        if (!missingPartitions.isEmpty()) {
            throw new RewriteAbortException(
                "one or more partitions have zero surviving replicas",
                quorumReport,
                new RewriteReport.RecordsProcessed(totalRecords, recordCounts),
                partitionSummary,
                List.copyOf(missingPartitions),
                List.copyOf(warnings)
            );
        }

        return new RewriteExecutionResult(
            new CheckpointSnapshot(
                inputSnapshot.snapshotId(),
                inputSnapshot.lastContainedLogTimestamp(),
                effectiveKRaftVersion(inputSnapshot.kraftVersion(), outputVoterSet),
                outputVoterSet,
                List.copyOf(rewrittenRecords)
            ),
            new RewriteOutcome(
                List.of(),
                quorumReport,
                new RewriteReport.RecordsProcessed(totalRecords, recordCounts),
                partitionSummary,
                List.of(),
                List.copyOf(warnings)
            )
        );
    }

    private Map<Uuid, String> collectTopicNames(List<ApiMessageAndVersion> records) {
        Map<Uuid, String> topicNames = new HashMap<>();
        for (ApiMessageAndVersion record : records) {
            if (record.message() instanceof TopicRecord topicRecord) {
                topicNames.put(topicRecord.topicId(), topicRecord.name());
            }
        }
        return topicNames;
    }

    private List<Integer> filterSurviving(List<Integer> brokerIds, Set<Integer> survivingSet) {
        if (brokerIds == null || brokerIds.isEmpty()) {
            return List.of();
        }
        return brokerIds.stream()
            .filter(survivingSet::contains)
            .toList();
    }

    private VoterSet filterVoterSet(VoterSet inputVoterSet, Set<Integer> survivingSet) {
        Map<Integer, VoterSet.VoterNode> filteredVoters = inputVoterSet.voterNodes()
            .stream()
            .filter(voterNode -> survivingSet.contains(voterNode.voterKey().id()))
            .collect(Collectors.toMap(voterNode -> voterNode.voterKey().id(), voterNode -> voterNode));

        if (filteredVoters.isEmpty()) {
            throw new RewriteAbortException(
                "filtered voter set is empty after applying surviving brokers",
                new RewriteReport.QuorumReport(true, true, false),
                recordsProcessed(1, true),
                new RewriteReport.PartitionSummary(0, 0, 0, 0, 0),
                List.of(),
                List.of()
            );
        }

        if (!filteredVoters.keySet().equals(survivingSet)) {
            throw new RewriteAbortException(
                "surviving brokers do not match the voter ids present in the checkpoint",
                new RewriteReport.QuorumReport(true, true, false),
                recordsProcessed(1, true),
                new RewriteReport.PartitionSummary(0, 0, 0, 0, 0),
                List.of(),
                List.of()
            );
        }

        return VoterSet.fromMap(filteredVoters);
    }

    private Optional<PartitionReplicaOverride> matchingPartitionReplicaOverride(
        Optional<PartitionReplicaOverride> partitionReplicaOverride,
        String topicName,
        int partitionId
    ) {
        return partitionReplicaOverride.filter(override -> override.matches(topicName, partitionId));
    }

    private PartitionRecord applyPartitionReplicaOverride(PartitionRecord rewrittenPartition, PartitionReplicaOverride partitionReplicaOverride) {
        return rewrittenPartition
            .setReplicas(partitionReplicaOverride.replicas())
            .setIsr(partitionReplicaOverride.replicas())
            .setRemovingReplicas(List.of())
            .setAddingReplicas(List.of())
            .setLeader(partitionReplicaOverride.leaderId())
            .setDirectories(List.of(DirectoryId.unassignedArray(partitionReplicaOverride.replicas().size())))
            .setEligibleLeaderReplicas(List.of())
            .setLastKnownElr(List.of());
    }

    private KRaftVersion effectiveKRaftVersion(KRaftVersion inputVersion, Optional<VoterSet> outputVoterSet) {
        if (outputVoterSet.isPresent()) {
            return KRaftVersion.KRAFT_VERSION_1;
        }
        return inputVersion;
    }

    private RewriteReport.RecordsProcessed recordsProcessed(int totalRecords, boolean votersRecordPresent) {
        LinkedHashMap<String, Integer> counts = RewriteStats.emptyRecordCounts();
        if (votersRecordPresent) {
            counts.put("VotersRecord", 1);
        }
        return new RewriteReport.RecordsProcessed(totalRecords, counts);
    }

    private void incrementCount(LinkedHashMap<String, Integer> counts, String recordType) {
        counts.compute(recordType, (key, value) -> value == null ? 1 : value + 1);
    }
}
