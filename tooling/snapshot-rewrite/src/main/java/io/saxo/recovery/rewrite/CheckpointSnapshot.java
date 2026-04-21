package io.saxo.recovery.rewrite;

import java.util.List;
import java.util.Optional;
import org.apache.kafka.raft.VoterSet;
import org.apache.kafka.server.common.ApiMessageAndVersion;
import org.apache.kafka.server.common.KRaftVersion;
import org.apache.kafka.server.common.OffsetAndEpoch;

record CheckpointSnapshot(
    OffsetAndEpoch snapshotId,
    long lastContainedLogTimestamp,
    KRaftVersion kraftVersion,
    Optional<VoterSet> voterSet,
    List<ApiMessageAndVersion> records
) {
}
