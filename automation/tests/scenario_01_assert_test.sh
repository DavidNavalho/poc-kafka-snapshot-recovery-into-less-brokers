#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-01"
run_id_pass="test-assert-pass"
run_id_fail="test-assert-fail"
workdir_pass="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_pass}"
workdir_fail="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_fail}"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir_pass}" "${workdir_fail}" "${stub_bin_dir}"
}
trap cleanup EXIT

write_stub_docker() {
  local output_path="$1"
  cat >"${output_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmdline="$*"

case "${cmdline}" in
  *" logs --no-color")
    cat "${TEST_DOCKER_LOGS_FILE}"
    ;;
  *" ps")
    cat "${TEST_DOCKER_PS_FILE}"
    ;;
  *"kafka-metadata-quorum --bootstrap-server kafka-0:9092 describe --status"*)
    cat "${TEST_DOCKER_QUORUM_STATUS_FILE}"
    ;;
  *"kafka-topics --bootstrap-server kafka-0:9092 --describe --topic recovery.default.6p --unavailable-partitions"*)
    cat "${TEST_DOCKER_TOPIC_6P_UNAVAILABLE_FILE}"
    ;;
  *"kafka-topics --bootstrap-server kafka-0:9092 --describe --topic recovery.default.6p"*)
    cat "${TEST_DOCKER_TOPIC_6P_DESCRIBE_FILE}"
    ;;
  *)
    echo "unexpected docker invocation: ${cmdline}" >&2
    exit 97
    ;;
esac
EOF
  chmod +x "${output_path}"
}

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"

  mkdir -p \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/rewrite" \
    "${workdir}/artifacts/recovery" \
    "${workdir}/brokers/broker-0/metadata/__cluster_metadata-0" \
    "${workdir}/brokers/broker-1/metadata/__cluster_metadata-0" \
    "${workdir}/brokers/broker-2/metadata/__cluster_metadata-0"

  cat >"${workdir}/snapshot-manifest.json" <<EOF
{
  "snapshot_label": "baseline-clean-v1",
  "source_fixture_version": "baseline-clean-v1",
  "cluster": {
    "cluster_id": "MkU3OEVBNTcwNTJENDM2Qk"
  },
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  },
  "topics": [
    {
      "name": "recovery.default.6p",
      "partitions": 6,
      "replication_factor": 3
    },
    {
      "name": "ignore.rf1.topic",
      "partitions": 1,
      "replication_factor": 1
    }
  ],
  "metadata_snapshot": {
    "dynamic_quorum": false,
    "selected_checkpoint": {
      "basename": "00000000000000008030-0000000001.checkpoint"
    }
  }
}
EOF

  cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<EOF
{
  "basename": "00000000000000008030-0000000001.checkpoint"
}
EOF

  cat >"${workdir}/artifacts/prepare/quorum-state.json" <<EOF
{
  "dynamic_quorum": false
}
EOF

  cat >"${workdir}/artifacts/rewrite/rewrite-report.json" <<EOF
{
  "status": "success",
  "surviving_brokers": [0, 1, 2],
  "directory_mode": "UNASSIGNED",
  "quorum": {
    "voters_record_present": false,
    "rewrite_voters_requested": false,
    "voters_rewritten": false
  },
  "input_checkpoint": {
    "basename": "00000000000000008030-0000000001.checkpoint"
  },
  "output_checkpoint": {
    "basename": "00000000000000008030-0000000001.checkpoint"
  },
  "partitions": {
    "missing_survivors": 0
  },
  "missing_partitions": []
}
EOF

  printf 'rewritten metadata log artifact\n' >"${workdir}/artifacts/rewrite/00000000000000000000.log"
  printf 'rewritten metadata index artifact\n' >"${workdir}/artifacts/rewrite/00000000000000000000.index"
  printf 'rewritten metadata time index artifact\n' >"${workdir}/artifacts/rewrite/00000000000000000000.timeindex"

  for broker_id in 0 1 2; do
    metadata_dir="${workdir}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0"
    printf 'partition metadata\n' >"${metadata_dir}/partition.metadata"
    printf 'leader epoch checkpoint\n' >"${metadata_dir}/leader-epoch-checkpoint"
    printf '{"clusterId":"","leaderId":-1,"leaderEpoch":0,"votedId":-1,"appliedOffset":0,"currentVoters":[{"voterId":0},{"voterId":1},{"voterId":2}],"data_version":0}\n' >"${metadata_dir}/quorum-state"
    printf 'rewritten checkpoint\n' >"${metadata_dir}/00000000000000008030-0000000001.checkpoint"
    printf 'rewritten log\n' >"${metadata_dir}/00000000000000000000.log"
    printf 'rewritten index\n' >"${metadata_dir}/00000000000000000000.index"
    printf 'rewritten time index\n' >"${metadata_dir}/00000000000000000000.timeindex"
  done

  cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v1
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF
}

write_stub_docker "${stub_bin_dir}/docker"

prepare_run_dir "${workdir_pass}" "${run_id_pass}"

cat >"${workdir_pass}/quorum-status.fixture.txt" <<'EOF'
ClusterId:              MkU3OEVBNTcwNTJENDM2Qk
LeaderId:               1
LeaderEpoch:            3
HighWatermark:          8030
MaxFollowerLag:         0
MaxFollowerLagTimeMs:   0
CurrentVoters:          [{"id": 0, "endpoints": ["CONTROLLER://kafka-0:9093"]}, {"id": 1, "endpoints": ["CONTROLLER://kafka-1:9093"]}, {"id": 2, "endpoints": ["CONTROLLER://kafka-2:9093"]}]
CurrentObservers:       []
EOF

cat >"${workdir_pass}/topic-6p.describe.fixture.txt" <<'EOF'
Topic: recovery.default.6p	TopicId: mock	PartitionCount: 6	ReplicationFactor: 1	Configs:
	Topic: recovery.default.6p	Partition: 0	Leader: 0	Replicas: 0	Isr: 0
	Topic: recovery.default.6p	Partition: 1	Leader: 1	Replicas: 1	Isr: 1
	Topic: recovery.default.6p	Partition: 2	Leader: 2	Replicas: 2	Isr: 2
	Topic: recovery.default.6p	Partition: 3	Leader: 0	Replicas: 0	Isr: 0
	Topic: recovery.default.6p	Partition: 4	Leader: 1	Replicas: 1	Isr: 1
	Topic: recovery.default.6p	Partition: 5	Leader: 2	Replicas: 2	Isr: 2
EOF

: >"${workdir_pass}/topic-6p.unavailable.fixture.txt"

cat >"${workdir_pass}/logs.fixture.txt" <<'EOF'
[2026-04-20T10:00:00Z] INFO recovery cluster ready
java.net.UnknownHostException: kafka-5
EOF

cat >"${workdir_pass}/ps.fixture.txt" <<'EOF'
NAME              IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1         confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
kafka-1-1         confluentinc/cp-kafka:8.1  mock      kafka-1   now       running
kafka-2-1         confluentinc/cp-kafka:8.1  mock      kafka-2   now       running
EOF

PATH="${stub_bin_dir}:${PATH}" \
TEST_DOCKER_LOGS_FILE="${workdir_pass}/logs.fixture.txt" \
TEST_DOCKER_PS_FILE="${workdir_pass}/ps.fixture.txt" \
TEST_DOCKER_QUORUM_STATUS_FILE="${workdir_pass}/quorum-status.fixture.txt" \
TEST_DOCKER_TOPIC_6P_DESCRIBE_FILE="${workdir_pass}/topic-6p.describe.fixture.txt" \
TEST_DOCKER_TOPIC_6P_UNAVAILABLE_FILE="${workdir_pass}/topic-6p.unavailable.fixture.txt" \
  "${repo_root}/automation/scenarios/scenario-01/assert" "${run_id_pass}"

summary_path="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${summary_path}" ]]
[[ "$(jq -r '.status' "${summary_path}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A5") | .result' "${summary_path}")" == "PASS" ]]
grep -q 'UnknownHostException: kafka-5' "${workdir_pass}/artifacts/assert/secondary-anomalies.txt"
grep -q 'no startup failure patterns detected' "${workdir_pass}/artifacts/assert/startup-failure-scan.txt"
[[ -f "${workdir_pass}/artifacts/assert/topics/recovery.default.6p.describe.txt" ]]
[[ -f "${workdir_pass}/artifacts/assert/topics/recovery.default.6p.unavailable.txt" ]]

prepare_run_dir "${workdir_fail}" "${run_id_fail}"

cat >"${workdir_fail}/quorum-status.fixture.txt" <<'EOF'
ClusterId:              MkU3OEVBNTcwNTJENDM2Qk
LeaderId:               0
LeaderEpoch:            2
HighWatermark:          8030
MaxFollowerLag:         0
MaxFollowerLagTimeMs:   0
CurrentVoters:          [{"id": 0, "endpoints": ["CONTROLLER://kafka-0:9093"]}, {"id": 1, "endpoints": ["CONTROLLER://kafka-1:9093"]}, {"id": 2, "endpoints": ["CONTROLLER://kafka-2:9093"]}]
CurrentObservers:       []
EOF

cp "${workdir_pass}/topic-6p.describe.fixture.txt" "${workdir_fail}/topic-6p.describe.fixture.txt"
: >"${workdir_fail}/topic-6p.unavailable.fixture.txt"

cat >"${workdir_fail}/logs.fixture.txt" <<'EOF'
[2026-04-20T10:01:00Z] INFO recovery cluster starting
[2026-04-20T10:01:01Z] ERROR Encountered fatal fault: Unexpected error in raft IO thread
EOF

cp "${workdir_pass}/ps.fixture.txt" "${workdir_fail}/ps.fixture.txt"

set +e
PATH="${stub_bin_dir}:${PATH}" \
TEST_DOCKER_LOGS_FILE="${workdir_fail}/logs.fixture.txt" \
TEST_DOCKER_PS_FILE="${workdir_fail}/ps.fixture.txt" \
TEST_DOCKER_QUORUM_STATUS_FILE="${workdir_fail}/quorum-status.fixture.txt" \
TEST_DOCKER_TOPIC_6P_DESCRIBE_FILE="${workdir_fail}/topic-6p.describe.fixture.txt" \
TEST_DOCKER_TOPIC_6P_UNAVAILABLE_FILE="${workdir_fail}/topic-6p.unavailable.fixture.txt" \
  "${repo_root}/automation/scenarios/scenario-01/assert" "${run_id_fail}"
status=$?
set -e

[[ "${status}" -ne 0 ]]
summary_path_fail="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${summary_path_fail}" ]]
[[ "$(jq -r '.status' "${summary_path_fail}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A5") | .result' "${summary_path_fail}")" == "FAIL" ]]
grep -q 'Encountered fatal fault' "${workdir_fail}/artifacts/assert/startup-failure-scan.txt"

printf 'scenario_01_assert_test: ok\n'
