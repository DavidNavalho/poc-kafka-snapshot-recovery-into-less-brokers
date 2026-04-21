#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-02"
run_id_pass="test-s02-assert-pass"
run_id_fail="test-s02-assert-fail"
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

extract_topic() {
  if [[ "${cmdline}" =~ --topic[[:space:]]([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]//\'}"
    return 0
  fi
  return 1
}

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
  *" --describe --topic "*"--unavailable-partitions"*)
    topic="$(extract_topic)"
    cat "${TEST_FIXTURE_ROOT}/topics/${topic}.unavailable.txt"
    ;;
  *" --describe --topic "*)
    topic="$(extract_topic)"
    cat "${TEST_FIXTURE_ROOT}/topics/${topic}.describe.txt"
    ;;
  *"GetOffsetShell"*)
    topic="$(extract_topic)"
    cat "${TEST_FIXTURE_ROOT}/offsets/${topic}.txt"
    ;;
  *"kafka-console-consumer"*)
    topic="$(extract_topic)"
    partition="$(extract_partition)"
    if [[ "${cmdline}" == *"| wc -l"* ]]; then
      cat "${TEST_FIXTURE_ROOT}/samples/${topic}.p${partition}.count.txt"
    else
      cat "${TEST_FIXTURE_ROOT}/samples/${topic}.p${partition}.preview.txt"
    fi
    ;;
  *)
    echo "unexpected docker invocation: ${cmdline}" >&2
    exit 97
    ;;
esac
EOF
  chmod +x "${output_path}"
}

write_topic_describe_fixture() {
  local fixture_root="$1"
  local topic="$2"
  local partitions="$3"
  local output_path="${fixture_root}/topics/${topic}.describe.txt"

  {
    printf 'Topic: %s\tTopicId: mock\tPartitionCount: %s\tReplicationFactor: 3\tConfigs:\n' "${topic}" "${partitions}"
    for partition in $(seq 0 $((partitions - 1))); do
      printf '\tTopic: %s\tPartition: %s\tLeader: %s\tReplicas: 0,1,2\tIsr: 0,1,2\n' \
        "${topic}" "${partition}" "$((partition % 3))"
    done
  } >"${output_path}"
}

write_topic_offsets_fixture() {
  local fixture_root="$1"
  local topic="$2"
  local partitions="$3"
  local latest_offset="$4"
  local output_path="${fixture_root}/offsets/${topic}.txt"
  : >"${output_path}"
  for partition in $(seq 0 $((partitions - 1))); do
    printf '%s:%s:%s\n' "${topic}" "${partition}" "${latest_offset}" >>"${output_path}"
  done
}

write_preview_fixture() {
  local fixture_root="$1"
  local topic="$2"
  local partition="$3"
  local output_path="${fixture_root}/samples/${topic}.p${partition}.preview.txt"
  : >"${output_path}"
  for message_index in 0 1 2 3 4; do
    printf '%s|p%s|m%06d|payload\n' "${topic}" "${partition}" "${message_index}" >>"${output_path}"
  done
}

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local fixture_root="${workdir}/docker-fixtures"

  mkdir -p \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/recovery" \
    "${workdir}/docker-fixtures/topics" \
    "${workdir}/docker-fixtures/offsets" \
    "${workdir}/docker-fixtures/samples"

  cat >"${workdir}/snapshot-manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v1",
  "source_fixture_version": "baseline-clean-v1",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  },
  "topics": [
    {
      "name": "recovery.default.6p",
      "partitions": 6,
      "replication_factor": 3,
      "expected_latest_offsets": {
        "0": 10000, "1": 10000, "2": 10000, "3": 10000, "4": 10000, "5": 10000
      }
    },
    {
      "name": "recovery.default.12p",
      "partitions": 12,
      "replication_factor": 3,
      "expected_latest_offsets": {
        "0": 10000, "1": 10000, "2": 10000, "3": 10000, "4": 10000, "5": 10000,
        "6": 10000, "7": 10000, "8": 10000, "9": 10000, "10": 10000, "11": 10000
      }
    },
    {
      "name": "recovery.default.24p",
      "partitions": 24,
      "replication_factor": 3,
      "expected_latest_offsets": {
        "0": 5000, "1": 5000, "2": 5000, "3": 5000, "4": 5000, "5": 5000,
        "6": 5000, "7": 5000, "8": 5000, "9": 5000, "10": 5000, "11": 5000,
        "12": 5000, "13": 5000, "14": 5000, "15": 5000, "16": 5000, "17": 5000,
        "18": 5000, "19": 5000, "20": 5000, "21": 5000, "22": 5000, "23": 5000
      }
    },
    {
      "name": "recovery.compressed.zstd",
      "partitions": 12,
      "replication_factor": 3,
      "expected_latest_offsets": {
        "0": 4000, "1": 4000, "2": 4000, "3": 4000, "4": 4000, "5": 4000,
        "6": 4000, "7": 4000, "8": 4000, "9": 4000, "10": 4000, "11": 4000
      }
    }
  ]
}
EOF

  cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<'EOF'
{"basename":"00000000000000008030-0000000001.checkpoint"}
EOF

  cat >"${workdir}/artifacts/prepare/quorum-state.json" <<'EOF'
{"dynamic_quorum":false}
EOF

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

  write_topic_describe_fixture "${fixture_root}" "recovery.default.6p" 6
  write_topic_describe_fixture "${fixture_root}" "recovery.default.12p" 12
  write_topic_describe_fixture "${fixture_root}" "recovery.default.24p" 24
  write_topic_describe_fixture "${fixture_root}" "recovery.compressed.zstd" 12

  : >"${fixture_root}/topics/recovery.default.6p.unavailable.txt"
  : >"${fixture_root}/topics/recovery.default.12p.unavailable.txt"
  : >"${fixture_root}/topics/recovery.default.24p.unavailable.txt"
  : >"${fixture_root}/topics/recovery.compressed.zstd.unavailable.txt"

  write_topic_offsets_fixture "${fixture_root}" "recovery.default.6p" 6 10000
  write_topic_offsets_fixture "${fixture_root}" "recovery.default.12p" 12 10000
  write_topic_offsets_fixture "${fixture_root}" "recovery.default.24p" 24 5000
  write_topic_offsets_fixture "${fixture_root}" "recovery.compressed.zstd" 12 4000

  printf '10000\n' >"${fixture_root}/samples/recovery.default.6p.p0.count.txt"
  printf '10000\n' >"${fixture_root}/samples/recovery.default.6p.p5.count.txt"
  printf '10000\n' >"${fixture_root}/samples/recovery.default.12p.p0.count.txt"
  printf '10000\n' >"${fixture_root}/samples/recovery.default.12p.p11.count.txt"
  printf '5000\n' >"${fixture_root}/samples/recovery.default.24p.p0.count.txt"
  printf '5000\n' >"${fixture_root}/samples/recovery.default.24p.p23.count.txt"
  printf '4000\n' >"${fixture_root}/samples/recovery.compressed.zstd.p0.count.txt"
  printf '4000\n' >"${fixture_root}/samples/recovery.compressed.zstd.p11.count.txt"

  write_preview_fixture "${fixture_root}" "recovery.default.6p" 0
  write_preview_fixture "${fixture_root}" "recovery.default.6p" 5
  write_preview_fixture "${fixture_root}" "recovery.default.12p" 0
  write_preview_fixture "${fixture_root}" "recovery.default.12p" 11
  write_preview_fixture "${fixture_root}" "recovery.default.24p" 0
  write_preview_fixture "${fixture_root}" "recovery.default.24p" 23
  write_preview_fixture "${fixture_root}" "recovery.compressed.zstd" 0
  write_preview_fixture "${fixture_root}" "recovery.compressed.zstd" 11

  cat >"${fixture_root}/logs.txt" <<'EOF'
[2026-04-21T09:00:00Z] INFO recovery cluster ready
EOF

  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME              IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1         confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
kafka-1-1         confluentinc/cp-kafka:8.1  mock      kafka-1   now       running
kafka-2-1         confluentinc/cp-kafka:8.1  mock      kafka-2   now       running
EOF
}

write_stub_docker "${stub_bin_dir}/docker"

prepare_run_dir "${workdir_pass}" "${run_id_pass}"

PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${workdir_pass}/docker-fixtures" \
TEST_DOCKER_LOGS_FILE="${workdir_pass}/docker-fixtures/logs.txt" \
TEST_DOCKER_PS_FILE="${workdir_pass}/docker-fixtures/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-02/assert" "${run_id_pass}"

summary_path="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${summary_path}" ]]
[[ "$(jq -r '.status' "${summary_path}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${summary_path}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A5") | .result' "${summary_path}")" == "PASS" ]]
grep -q 'no corruption patterns detected' "${workdir_pass}/artifacts/assert/corruption-scan.txt"
[[ -f "${workdir_pass}/artifacts/assert/offsets/recovery.default.24p.offsets.txt" ]]
[[ -f "${workdir_pass}/artifacts/assert/samples/recovery.compressed.zstd.p11.preview.txt" ]]
grep -q 'recovery.default.12p|p11|m000000|' "${workdir_pass}/artifacts/assert/samples/recovery.default.12p.p11.preview.txt"

prepare_run_dir "${workdir_fail}" "${run_id_fail}"
printf '9999\n' >"${workdir_fail}/docker-fixtures/samples/recovery.default.12p.p11.count.txt"
cat >"${workdir_fail}/docker-fixtures/logs.txt" <<'EOF'
[2026-04-21T09:01:00Z] ERROR CorruptRecordException while loading log segment
EOF

set +e
PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${workdir_fail}/docker-fixtures" \
TEST_DOCKER_LOGS_FILE="${workdir_fail}/docker-fixtures/logs.txt" \
TEST_DOCKER_PS_FILE="${workdir_fail}/docker-fixtures/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-02/assert" "${run_id_fail}"
status=$?
set -e

[[ "${status}" -ne 0 ]]
summary_path_fail="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${summary_path_fail}" ]]
[[ "$(jq -r '.status' "${summary_path_fail}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${summary_path_fail}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A5") | .result' "${summary_path_fail}")" == "FAIL" ]]
grep -q 'CorruptRecordException' "${workdir_fail}/artifacts/assert/corruption-scan.txt"

printf 'scenario_02_assert_test: ok\n'
