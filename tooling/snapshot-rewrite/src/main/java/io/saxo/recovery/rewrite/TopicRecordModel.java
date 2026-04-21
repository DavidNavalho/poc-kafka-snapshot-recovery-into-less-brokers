package io.saxo.recovery.rewrite;

record TopicRecordModel(String topicName) implements MetadataRecordModel {
    @Override
    public String recordType() {
        return "TopicRecord";
    }
}
