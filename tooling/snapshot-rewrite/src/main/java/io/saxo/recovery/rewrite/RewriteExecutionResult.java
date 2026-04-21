package io.saxo.recovery.rewrite;

record RewriteExecutionResult(
    CheckpointSnapshot snapshot,
    RewriteOutcome outcome
) {
}
