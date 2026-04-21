package io.saxo.recovery.rewrite;

import java.util.List;

record PartitionRecordModel(
    String topicName,
    int partitionId,
    List<Integer> replicas,
    List<Integer> isr,
    int leaderId,
    int leaderEpoch,
    int partitionEpoch,
    List<String> directories
) implements MetadataRecordModel {
    @Override
    public String recordType() {
        return "PartitionRecord";
    }
}
