package io.saxo.recovery.rewrite;

sealed interface MetadataRecordModel permits PartitionRecordModel, RegisterBrokerRecordModel, VotersRecordModel, TopicRecordModel {
    String recordType();
}
