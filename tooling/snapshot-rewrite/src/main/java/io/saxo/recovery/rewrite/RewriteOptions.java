package io.saxo.recovery.rewrite;

import java.nio.file.Path;
import java.util.List;
import java.util.Optional;

record RewriteOptions(
    Path input,
    Path output,
    List<Integer> survivingBrokers,
    DirectoryMode directoryMode,
    boolean rewriteVoters,
    Path report,
    Optional<Path> metadataLogInput,
    Optional<Path> metadataLogOutput,
    Optional<PartitionReplicaOverride> partitionReplicaOverride
) {
}
