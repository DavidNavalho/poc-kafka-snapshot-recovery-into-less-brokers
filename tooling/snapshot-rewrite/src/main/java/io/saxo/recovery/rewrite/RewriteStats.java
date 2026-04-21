package io.saxo.recovery.rewrite;

import java.util.LinkedHashMap;

final class RewriteStats {
    private RewriteStats() {
    }

    static LinkedHashMap<String, Integer> emptyRecordCounts() {
        LinkedHashMap<String, Integer> byType = new LinkedHashMap<>();
        byType.put("PartitionRecord", 0);
        byType.put("RegisterBrokerRecord", 0);
        byType.put("RegisterControllerRecord", 0);
        byType.put("TopicRecord", 0);
        byType.put("ConfigRecord", 0);
        byType.put("VotersRecord", 0);
        return byType;
    }
}
