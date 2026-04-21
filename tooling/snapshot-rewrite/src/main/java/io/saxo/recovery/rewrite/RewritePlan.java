package io.saxo.recovery.rewrite;

import java.util.List;

record RewritePlan(
    List<Integer> survivingBrokers,
    DirectoryMode directoryMode,
    boolean rewriteVoters
) {
    RewritePlan {
        if (survivingBrokers == null || survivingBrokers.isEmpty()) {
            throw new RewriteException("surviving brokers list must not be empty");
        }
    }
}
