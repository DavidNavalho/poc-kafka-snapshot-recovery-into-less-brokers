package io.saxo.recovery.rewrite;

import java.util.List;

record VotersRecordModel(List<Integer> voterIds) implements MetadataRecordModel {
    @Override
    public String recordType() {
        return "VotersRecord";
    }
}
