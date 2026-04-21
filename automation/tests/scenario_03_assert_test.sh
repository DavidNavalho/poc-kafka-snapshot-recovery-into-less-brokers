#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-03"
snapshot_label="baseline-clean-v3"
run_id_pass="test-s03-assert-pass"
run_id_fail="test-s03-assert-fail"
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
project_name=""
phase="positive"
target_dir="${RECOVERY_WORKDIR}/brokers/broker-0/logdir-0/recovery.default.6p-0"
target_stray="${target_dir}-stray"

if [[ "${cmdline}" =~ --project-name[[:space:]]([^[:space:]]+) ]]; then
  project_name="${BASH_REMATCH[1]}"
fi

phase_for_logs() {
  if [[ "${project_name}" == *"-negative" ]]; then
    if [[ -f "${RECOVERY_WORKDIR}/.scenario03-restored-phase" ]]; then
      printf 'restored\n'
    elif [[ -d "${target_stray}" ]]; then
      printf 'negative\n'
    else
      printf 'negative-preboot\n'
    fi
    return 0
  fi

  printf 'positive\n'
}

phase="$(phase_for_logs)"

case "${cmdline}" in
  *" up -d")
    if [[ "${project_name}" == *"-negative" ]] && [[ -f "${RECOVERY_WORKDIR}/.scenario03-fault-injected" ]] && [[ "${TEST_FAIL_MODE:-}" != "no-stray" ]]; then
      if [[ -d "${target_dir}" ]] && [[ ! -d "${target_stray}" ]]; then
        mv "${target_dir}" "${target_stray}"
      fi
    fi
    ;;
  *" down --remove-orphans")
    ;;
  *" logs --no-color")
    cat "${TEST_FIXTURE_ROOT}/logs/${phase}.log"
    ;;
  *" ps")
    cat "${TEST_FIXTURE_ROOT}/ps.txt"
    ;;
  *"kafka-topics"*"--list"*)
    printf 'recovery.default.6p\n'
    ;;
  *"kafka-metadata-quorum"*"describe --status"*)
    cat "${TEST_FIXTURE_ROOT}/quorum-status.txt"
    ;;
  *"kafka-topics"*"--describe"*"--topic recovery.default.6p"*"--unavailable-partitions"*)
    cat "${TEST_FIXTURE_ROOT}/topics/recovery.default.6p.unavailable.txt"
    ;;
  *"kafka-topics"*"--describe"*"--topic recovery.default.6p"*)
    cat "${TEST_FIXTURE_ROOT}/topics/recovery.default.6p.describe.txt"
    ;;
  *"kafka-console-consumer"*"--topic 'recovery.default.6p'"*"--partition 0"*"wc -l"*)
    cat "${TEST_FIXTURE_ROOT}/samples/recovery.default.6p.p0.count.txt"
    ;;
  *)
    echo "unexpected docker invocation: ${cmdline}" >&2
    exit 97
    ;;
esac
EOF
  chmod +x "${output_path}"
}

write_stub_rewrite_tool() {
  local output_path="$1"
  cat >"${output_path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_path=""
metadata_log_output_path=""
report_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output_path="$2"
      shift 2
      ;;
    --metadata-log-output)
      metadata_log_output_path="$2"
      shift 2
      ;;
    --report)
      report_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'mutated-checkpoint\n' >"${output_path}"
printf 'mutated-log\n' >"${metadata_log_output_path}"
printf 'mutated-index\n' >"${metadata_log_output_path%.log}.index"
printf 'mutated-timeindex\n' >"${metadata_log_output_path%.log}.timeindex"
printf '{"status":"success"}\n' >"${report_path}"
EOF
  chmod +x "${output_path}"
}

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local fixture_root="${workdir}/docker-fixtures"
  local broker_id

  mkdir -p \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/rewrite" \
    "${workdir}/artifacts/recovery" \
    "${workdir}/brokers" \
    "${fixture_root}/logs" \
    "${fixture_root}/topics" \
    "${fixture_root}/samples"

  cat >"${workdir}/snapshot-manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v3",
  "source_fixture_version": "baseline-clean-v3",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  },
  "topics": [
    {
      "name": "recovery.default.6p",
      "partitions": 6,
      "expected_latest_offsets": {
        "0": 10000
      }
    }
  ]
}
EOF

  for broker_id in 0 1 2; do
    mkdir -p \
      "${workdir}/brokers/broker-${broker_id}/data-root" \
      "${workdir}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0" \
      "${workdir}/brokers/broker-${broker_id}/logdir-0" \
      "${workdir}/brokers/broker-${broker_id}/logdir-1" \
      "${workdir}/brokers/broker-${broker_id}/rendered-config"
    printf 'partition-metadata\n' >"${workdir}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0/partition.metadata"
    printf 'leader-epoch\n' >"${workdir}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0/leader-epoch-checkpoint"
    printf 'quorum-state\n' >"${workdir}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0/quorum-state"
  done

  mkdir -p "${workdir}/brokers/broker-0/logdir-0/recovery.default.6p-0"
  printf 'partition-metadata\n' >"${workdir}/brokers/broker-0/logdir-0/recovery.default.6p-0/partition.metadata"
  printf 'segment\n' >"${workdir}/brokers/broker-0/logdir-0/recovery.default.6p-0/00000000000000000000.log"

  cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=${snapshot_label}
SNAPSHOT_SOURCE_ROOT=/tmp/shared-snapshots
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

  cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<'EOF'
{"basename":"00000000000000001952-0000000001.checkpoint"}
EOF

  cat >"${workdir}/artifacts/prepare/quorum-state.json" <<'EOF'
{"dynamic_quorum":false}
EOF

  printf 'clean-checkpoint\n' >"${workdir}/artifacts/rewrite/00000000000000001952-0000000001.checkpoint"
  printf 'clean-log\n' >"${workdir}/artifacts/rewrite/00000000000000000000.log"
  printf 'clean-index\n' >"${workdir}/artifacts/rewrite/00000000000000000000.index"
  printf 'clean-timeindex\n' >"${workdir}/artifacts/rewrite/00000000000000000000.timeindex"
  printf '{"status":"success"}\n' >"${workdir}/artifacts/rewrite/rewrite-report.json"

  cat >"${fixture_root}/logs/positive.log" <<'EOF'
[2026-04-21T14:50:00Z] INFO recovery cluster ready
EOF
  cat >"${fixture_root}/logs/negative.log" <<'EOF'
[2026-04-21T14:51:00Z] WARN renamed partition directory recovery.default.6p-0-stray
EOF
  cat >"${fixture_root}/logs/negative-preboot.log" <<'EOF'
[2026-04-21T14:51:00Z] INFO negative recovery project starting
EOF
  cat >"${fixture_root}/logs/restored.log" <<'EOF'
[2026-04-21T14:52:00Z] INFO restored recovery cluster ready
EOF
  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME       IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1  confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
EOF
  cat >"${fixture_root}/quorum-status.txt" <<'EOF'
ClusterId: MkU3OEVBNTcwNTJENDM2Qk
LeaderId: 2
LeaderEpoch: 7
HighWatermark: 99
MaxFollowerLag: 0
CurrentVoters: [{"id":0},{"id":1},{"id":2}]
EOF
  cat >"${fixture_root}/topics/recovery.default.6p.describe.txt" <<'EOF'
Topic: recovery.default.6p	TopicId: mock	PartitionCount: 6	ReplicationFactor: 1	Configs:
	Topic: recovery.default.6p	Partition: 0	Leader: 2	Replicas: 2	Isr: 2
EOF
  : >"${fixture_root}/topics/recovery.default.6p.unavailable.txt"
  printf '10000\n' >"${fixture_root}/samples/recovery.default.6p.p0.count.txt"
}

prepare_run_dir "${workdir_pass}" "${run_id_pass}"
prepare_run_dir "${workdir_fail}" "${run_id_fail}"
write_stub_docker "${stub_bin_dir}/docker"
write_stub_rewrite_tool "${stub_bin_dir}/snapshot-rewrite-tool"

fixture_root_pass="${workdir_pass}/docker-fixtures"
fixture_root_fail="${workdir_fail}/docker-fixtures"

PATH="${stub_bin_dir}:${PATH}" \
SNAPSHOT_REWRITE_TOOL="${stub_bin_dir}/snapshot-rewrite-tool" \
TEST_FIXTURE_ROOT="${fixture_root_pass}" \
SCENARIO03_STRAY_WAIT_ATTEMPTS=2 \
SCENARIO03_STRAY_WAIT_SECONDS=0 \
  "${repo_root}/automation/scenarios/scenario-03/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${pass_summary}")" == "PASS" ]]
grep -q -- '--fault-topic recovery.default.6p' "${workdir_pass}/artifacts/assert/negative/fault-override-command.txt"
grep -q 'recovery.default.6p-0-stray' "${workdir_pass}/artifacts/assert/negative/stray-dirs.txt"
grep -q 'no stray directories detected' "${workdir_pass}/artifacts/assert/restored/stray-scan.txt"
[[ -d "${workdir_pass}/artifacts/negative/workdir/brokers/broker-0/logdir-0/recovery.default.6p-0" ]]

set +e
PATH="${stub_bin_dir}:${PATH}" \
SNAPSHOT_REWRITE_TOOL="${stub_bin_dir}/snapshot-rewrite-tool" \
TEST_FIXTURE_ROOT="${fixture_root_fail}" \
TEST_FAIL_MODE="no-stray" \
SCENARIO03_STRAY_WAIT_ATTEMPTS=2 \
SCENARIO03_STRAY_WAIT_SECONDS=0 \
  "${repo_root}/automation/scenarios/scenario-03/assert" "${run_id_fail}"
status=$?
set -e
[[ "${status}" -ne 0 ]]

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${fail_summary}")" == "FAIL" ]]

printf 'scenario_03_assert_test: ok\n'
