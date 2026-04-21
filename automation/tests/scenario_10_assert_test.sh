#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-10"
snapshot_label="baseline-clean-v3"
run_id_pass="test-s10-assert-pass"
run_id_fail="test-s10-assert-fail"
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
fixture_root="${TEST_FIXTURE_ROOT}"
execute_state_file="${fixture_root}/reassignment-executed"
underrep_seen_file="${fixture_root}/underrep-seen"

case "${cmdline}" in
  *" logs --no-color")
    cat "${fixture_root}/logs.txt"
    ;;
  *" ps")
    cat "${fixture_root}/ps.txt"
    ;;
  *"kafka-topics"*"recovery.default.6p"*"--under-replicated-partitions"*)
    if [[ ! -f "${execute_state_file}" ]]; then
      : >"${fixture_root}/under-replicated.empty.txt"
      cat "${fixture_root}/under-replicated.empty.txt"
    elif [[ "${TEST_FAIL_MODE:-}" == "persistent-urp" ]]; then
      cat "${fixture_root}/under-replicated.after.txt"
    elif [[ ! -f "${underrep_seen_file}" ]]; then
      touch "${underrep_seen_file}"
      cat "${fixture_root}/under-replicated.after.txt"
    else
      cat "${fixture_root}/under-replicated.empty.txt"
    fi
    ;;
  *"kafka-topics"*"recovery.default.6p"*)
    if [[ ! -f "${execute_state_file}" ]]; then
      cat "${fixture_root}/topics/recovery.default.6p.pre.describe.txt"
    elif [[ "${TEST_FAIL_MODE:-}" == "stuck-post" ]]; then
      cat "${fixture_root}/topics/recovery.default.6p.post-stuck.describe.txt"
    else
      cat "${fixture_root}/topics/recovery.default.6p.post.describe.txt"
    fi
    ;;
  *"cat >"*"/tmp/"*"scenario-10-reassignment.json"*)
    cat >"${fixture_root}/uploaded-reassignment.json"
    ;;
  *"kafka-reassign-partitions"*"--execute"*)
    touch "${execute_state_file}"
    cat "${fixture_root}/reassignment.execute.txt"
    ;;
  *"kafka-console-consumer"*"--topic 'recovery.default.6p'"*"--partition 0"*"wc -l"*)
    printf '10000\n'
    ;;
  *"kafka-console-consumer"*"--topic 'recovery.default.6p'"*"--partition 1"*"wc -l"*)
    printf '10000\n'
    ;;
  *"kafka-console-consumer"*"--topic 'recovery.default.6p'"*"--partition 2"*"wc -l"*)
    printf '10000\n'
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
  local fixture_root="${workdir}/docker-fixtures"

  mkdir -p \
    "${workdir}/artifacts/assert" \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/recovery" \
    "${fixture_root}/topics"

  cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=${snapshot_label}
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

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
        "0": 10000,
        "1": 10000,
        "2": 10000
      }
    }
  ]
}
EOF

  cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<'EOF'
{"basename":"00000000000000001952-0000000001.checkpoint"}
EOF

  cat >"${workdir}/artifacts/prepare/quorum-state.json" <<'EOF'
{"dynamic_quorum":false}
EOF

  cat >"${fixture_root}/logs.txt" <<'EOF'
[2026-04-21T16:00:00Z] INFO recovery cluster ready
EOF

  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME       IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1  confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
EOF

  : >"${fixture_root}/under-replicated.empty.txt"
  cat >"${fixture_root}/under-replicated.after.txt" <<'EOF'
Topic: recovery.default.6p	Partition: 0	Leader: 0	Replicas: 0,1,2	Isr: 0
EOF

  cat >"${fixture_root}/reassignment.execute.txt" <<'EOF'
Successfully started partition reassignment(s).
EOF

  cat >"${fixture_root}/topics/recovery.default.6p.pre.describe.txt" <<'EOF'
Topic: recovery.default.6p	TopicId: pre	PartitionCount: 6	ReplicationFactor: 1	Configs:
	Topic: recovery.default.6p	Partition: 0	Leader: 0	Replicas: 0	Isr: 0
	Topic: recovery.default.6p	Partition: 1	Leader: 1	Replicas: 1	Isr: 1
	Topic: recovery.default.6p	Partition: 2	Leader: 2	Replicas: 2	Isr: 2
EOF

  cat >"${fixture_root}/topics/recovery.default.6p.post.describe.txt" <<'EOF'
Topic: recovery.default.6p	TopicId: post	PartitionCount: 6	ReplicationFactor: 3	Configs:
	Topic: recovery.default.6p	Partition: 0	Leader: 0	Replicas: 0,1,2	Isr: 0,1,2
	Topic: recovery.default.6p	Partition: 1	Leader: 1	Replicas: 0,1,2	Isr: 0,1,2
	Topic: recovery.default.6p	Partition: 2	Leader: 2	Replicas: 0,1,2	Isr: 0,1,2
EOF

  cat >"${fixture_root}/topics/recovery.default.6p.post-stuck.describe.txt" <<'EOF'
Topic: recovery.default.6p	TopicId: stuck	PartitionCount: 6	ReplicationFactor: 1	Configs:
	Topic: recovery.default.6p	Partition: 0	Leader: 0	Replicas: 0	Isr: 0
	Topic: recovery.default.6p	Partition: 1	Leader: 1	Replicas: 1	Isr: 1
	Topic: recovery.default.6p	Partition: 2	Leader: 2	Replicas: 2	Isr: 2
EOF
}

prepare_run_dir "${workdir_pass}" "${run_id_pass}"
prepare_run_dir "${workdir_fail}" "${run_id_fail}"
write_stub_docker "${stub_bin_dir}/docker"

PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${workdir_pass}/docker-fixtures" \
SCENARIO10_REASSIGN_WAIT_ATTEMPTS=2 \
SCENARIO10_REASSIGN_WAIT_SECONDS=0 \
  "${repo_root}/automation/scenarios/scenario-10/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -cS . "${workdir_pass}/docker-fixtures/uploaded-reassignment.json")" == '{"partitions":[{"partition":0,"replicas":[0,1,2],"topic":"recovery.default.6p"},{"partition":1,"replicas":[0,1,2],"topic":"recovery.default.6p"},{"partition":2,"replicas":[0,1,2],"topic":"recovery.default.6p"}],"version":1}' ]]

PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${workdir_fail}/docker-fixtures" \
TEST_FAIL_MODE="stuck-post" \
SCENARIO10_REASSIGN_WAIT_ATTEMPTS=2 \
SCENARIO10_REASSIGN_WAIT_SECONDS=0 \
  "${repo_root}/automation/scenarios/scenario-10/assert" "${run_id_fail}"

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${fail_summary}")" == "FAIL" ]]

printf 'scenario_10_assert_test: ok\n'
