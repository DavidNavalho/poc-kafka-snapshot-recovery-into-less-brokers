#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-08"
run_id_pass="test-s08-assert-pass"
run_id_fail="test-s08-assert-fail"
workdir_pass="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_pass}"
workdir_fail="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_fail}"
snapshot_root="${repo_root}/fixtures/test-snapshots-s08"
snapshot_label="baseline-clean-v2"
source_snapshot_dir="${snapshot_root}/${snapshot_label}"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir_pass}" "${workdir_fail}" "${snapshot_root}" "${stub_bin_dir}"
}
trap cleanup EXIT

write_stub_docker() {
  local output_path="$1"
  cat >"${output_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmdline="$*"

extract_partition() {
  if [[ "${cmdline}" =~ --partition[[:space:]]([0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

case "${cmdline}" in
  *" logs --no-color")
    cat "${TEST_DOCKER_LOGS_FILE}"
    ;;
  *" ps")
    cat "${TEST_DOCKER_PS_FILE}"
    ;;
  *"kafka-topics"*"--describe"*"--topic recovery.default.6p"*"--unavailable-partitions"*)
    cat "${TEST_FIXTURE_ROOT}/topics/recovery.default.6p.unavailable.txt"
    ;;
  *"kafka-topics"*"--describe"*"--topic recovery.default.6p"*)
    cat "${TEST_FIXTURE_ROOT}/topics/recovery.default.6p.describe.txt"
    ;;
  *"kafka-console-consumer"*"--topic 'recovery.default.6p'"*"--max-messages 5"*)
    partition_id="$(extract_partition)"
    cat "${TEST_FIXTURE_ROOT}/samples/recovery.default.6p.p${partition_id}.preview.txt"
    ;;
  *"kafka-console-consumer"*"--topic 'recovery.default.6p'"*"wc -l"*)
    partition_id="$(extract_partition)"
    cat "${TEST_FIXTURE_ROOT}/samples/recovery.default.6p.p${partition_id}.count.txt"
    ;;
  *)
    echo "unexpected docker invocation: ${cmdline}" >&2
    exit 97
    ;;
esac
EOF
  chmod +x "${output_path}"
}

write_meta_properties() {
  local output_path="$1"
  local cluster_id="$2"
  local directory_id="$3"
  local node_id="$4"
  cat >"${output_path}" <<EOF
#
#Tue Apr 21 11:25:05 GMT 2026
cluster.id=${cluster_id}
directory.id=${directory_id}
node.id=${node_id}
version=1
EOF
}

prepare_snapshot_tree() {
  local broker_id
  mkdir -p "${source_snapshot_dir}/brokers"

  cat >"${source_snapshot_dir}/manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v2",
  "source_fixture_version": "baseline-clean-v2",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  },
  "cluster": {
    "cluster_id": "MkU3OEVBNTcwNTJENDM2Qk",
    "log_dirs_per_broker": 2
  },
  "topics": [
    {
      "name": "recovery.default.6p",
      "partitions": 6,
      "replication_factor": 3,
      "expected_latest_offsets": {
        "0": 10000,
        "1": 10000,
        "2": 10000,
        "3": 10000,
        "4": 10000,
        "5": 10000
      }
    }
  ]
}
EOF

  for broker_id in 0 1 2; do
    mkdir -p \
      "${source_snapshot_dir}/brokers/broker-${broker_id}/logdir-0" \
      "${source_snapshot_dir}/brokers/broker-${broker_id}/logdir-1" \
      "${source_snapshot_dir}/brokers/broker-${broker_id}/metadata"
  done

  mkdir -p \
    "${source_snapshot_dir}/brokers/broker-0/logdir-0/recovery.default.6p-1" \
    "${source_snapshot_dir}/brokers/broker-0/logdir-1/recovery.default.6p-4" \
    "${source_snapshot_dir}/brokers/broker-1/logdir-0/recovery.default.6p-5" \
    "${source_snapshot_dir}/brokers/broker-1/logdir-1/recovery.default.6p-2" \
    "${source_snapshot_dir}/brokers/broker-2/logdir-0/recovery.default.6p-0" \
    "${source_snapshot_dir}/brokers/broker-2/logdir-1/recovery.default.6p-3"

  write_meta_properties "${source_snapshot_dir}/brokers/broker-0/logdir-0/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b0-l0" "0"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-0/logdir-1/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b0-l1" "0"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-0/metadata/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b0-meta" "0"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-1/logdir-0/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b1-l0" "1"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-1/logdir-1/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b1-l1" "1"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-1/metadata/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b1-meta" "1"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-2/logdir-0/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b2-l0" "2"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-2/logdir-1/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b2-l1" "2"
  write_meta_properties "${source_snapshot_dir}/brokers/broker-2/metadata/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b2-meta" "2"
}

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local fixture_root="${workdir}/docker-fixtures"

  mkdir -p \
    "${workdir}/artifacts/assert/logdirs" \
    "${workdir}/artifacts/assert/meta" \
    "${workdir}/artifacts/assert/topics" \
    "${workdir}/artifacts/assert/samples" \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/recovery" \
    "${workdir}/brokers" \
    "${fixture_root}/topics" \
    "${fixture_root}/samples"

  cp -R "${source_snapshot_dir}/brokers/." "${workdir}/brokers/"
  cp "${source_snapshot_dir}/manifest.json" "${workdir}/snapshot-manifest.json"

  cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=${snapshot_label}
SNAPSHOT_SOURCE_ROOT=${snapshot_root}
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

  cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<'EOF'
{"basename":"00000000000000001850-0000000001.checkpoint"}
EOF

  cat >"${workdir}/artifacts/prepare/quorum-state.json" <<'EOF'
{"dynamic_quorum":false}
EOF

  cat >"${fixture_root}/logs.txt" <<'EOF'
[2026-04-21T11:40:00Z] INFO recovery cluster ready
EOF

  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME              IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1         confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
kafka-1-1         confluentinc/cp-kafka:8.1  mock      kafka-1   now       running
kafka-2-1         confluentinc/cp-kafka:8.1  mock      kafka-2   now       running
EOF

  cat >"${fixture_root}/topics/recovery.default.6p.describe.txt" <<'EOF'
Topic: recovery.default.6p	TopicId: mock	PartitionCount: 6	ReplicationFactor: 1	Configs:
	Topic: recovery.default.6p	Partition: 0	Leader: 0	Replicas: 0	Isr: 0
	Topic: recovery.default.6p	Partition: 1	Leader: 1	Replicas: 1	Isr: 1
	Topic: recovery.default.6p	Partition: 2	Leader: 2	Replicas: 2	Isr: 2
	Topic: recovery.default.6p	Partition: 3	Leader: 0	Replicas: 0	Isr: 0
	Topic: recovery.default.6p	Partition: 4	Leader: 1	Replicas: 1	Isr: 1
	Topic: recovery.default.6p	Partition: 5	Leader: 2	Replicas: 2	Isr: 2
EOF

  : >"${fixture_root}/topics/recovery.default.6p.unavailable.txt"

  for partition_id in 0 1 2 3 4 5; do
    printf '10000\n' >"${fixture_root}/samples/recovery.default.6p.p${partition_id}.count.txt"
    printf 'message-%s-a\nmessage-%s-b\n' "${partition_id}" "${partition_id}" >"${fixture_root}/samples/recovery.default.6p.p${partition_id}.preview.txt"
  done
}

prepare_snapshot_tree
prepare_run_dir "${workdir_pass}" "${run_id_pass}"
prepare_run_dir "${workdir_fail}" "${run_id_fail}"
write_stub_docker "${stub_bin_dir}/docker"

fixture_root_pass="${workdir_pass}/docker-fixtures"
fixture_root_fail="${workdir_fail}/docker-fixtures"

mv "${workdir_fail}/brokers/broker-1/logdir-1/recovery.default.6p-2" "${workdir_fail}/brokers/broker-1/logdir-1/recovery.default.6p-99"
write_meta_properties "${workdir_fail}/brokers/broker-2/logdir-0/meta.properties" "MkU3OEVBNTcwNTJENDM2Qk" "dir-b2-l0" "9"
mkdir -p "${workdir_fail}/brokers/broker-0/logdir-1/recovery.default.6p-4-stray"
cat >"${fixture_root_fail}/logs.txt" <<'EOF'
[2026-04-21T11:40:00Z] ERROR stray directory detected during startup
[2026-04-21T11:40:01Z] ERROR meta.properties mismatch on recovered logdir
EOF
printf '9999\n' >"${fixture_root_fail}/samples/recovery.default.6p.p4.count.txt"

PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${fixture_root_pass}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_pass}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_pass}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-08/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(cat "${workdir_pass}/artifacts/assert/logdirs/broker-0.logdir-0.recovered-partitions.txt")" == "recovery.default.6p-1" ]]
[[ "$(cat "${workdir_pass}/artifacts/assert/samples/recovery.default.6p.p4.count.txt")" == "10000" ]]
grep -q 'no stray directories detected' "${workdir_pass}/artifacts/assert/stray-scan.txt"

set +e
PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${fixture_root_fail}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_fail}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_fail}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-08/assert" "${run_id_fail}"
status=$?
set -e
[[ "${status}" -ne 0 ]]

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${fail_summary}")" == "FAIL" ]]
grep -q 'recovery.default.6p-99' "${fail_summary}"
grep -q 'node.id' "${fail_summary}"
grep -q 'stray' "${fail_summary}"
grep -q 'p4=9999' "${fail_summary}"

printf 'scenario_08_assert_test: ok\n'
