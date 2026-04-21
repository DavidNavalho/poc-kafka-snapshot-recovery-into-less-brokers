package io.saxo.recovery.rewrite;

import java.util.List;

record PartitionReplicaOverride(
    String topicName,
    int partitionId,
    List<Integer> replicas,
    int leaderId
) {
    PartitionReplicaOverride {
        if (topicName == null || topicName.isBlank()) {
            throw new RewriteException("fault topic must not be blank");
        }
        if (partitionId < 0) {
            throw new RewriteException("fault partition id must not be negative: " + partitionId);
        }
        if (replicas == null || replicas.isEmpty()) {
            throw new RewriteException("fault replicas list must not be empty");
        }
        replicas = List.copyOf(replicas);
        if (!replicas.contains(leaderId)) {
            throw new RewriteException("fault leader must be one of the fault replicas: " + leaderId);
        }
    }

    boolean matches(String candidateTopicName, int candidatePartitionId) {
        return topicName.equals(candidateTopicName) && partitionId == candidatePartitionId;
    }
}
