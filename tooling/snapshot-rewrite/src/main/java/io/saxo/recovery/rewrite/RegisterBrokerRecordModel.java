package io.saxo.recovery.rewrite;

record RegisterBrokerRecordModel(int brokerId) implements MetadataRecordModel {
    @Override
    public String recordType() {
        return "RegisterBrokerRecord";
    }
}
