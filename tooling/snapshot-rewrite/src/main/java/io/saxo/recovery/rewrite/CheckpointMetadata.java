package io.saxo.recovery.rewrite;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

@JsonInclude(JsonInclude.Include.NON_NULL)
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
record CheckpointMetadata(
    String path,
    String basename,
    long offset,
    int epoch,
    String sha256
) {
}
