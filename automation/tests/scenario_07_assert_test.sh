#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-07"
snapshot_label="baseline-clean-v3"
run_id_pass="test-s07-assert-pass"
run_id_fail="test-s07-assert-fail"
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
probe_state_file="${TEST_FIXTURE_ROOT}/probe-ran"

extract_transactional_id() {
  if [[ "${cmdline}" =~ --transactional-id[[:space:]]([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]//\'}"
    return 0
  fi
  return 1
}

case "${cmdline}" in
  "image inspect "*)
    printf '[]\n'
    ;;
  "network inspect "*)
    printf '[]\n'
    ;;
  *" logs --no-color")
    cat "${TEST_DOCKER_LOGS_FILE}"
    ;;
  *" ps")
    cat "${TEST_DOCKER_PS_FILE}"
    ;;
  *"kafka-topics"*"--describe"*"__transaction_state"*)
    cat "${TEST_FIXTURE_ROOT}/transaction-state/__transaction_state.describe.txt"
    ;;
  *"kafka-transactions"*" list")
    if [[ -f "${probe_state_file}" ]]; then
      cat "${TEST_FIXTURE_ROOT}/transaction-state/transactions.list.after.txt"
    else
      cat "${TEST_FIXTURE_ROOT}/transaction-state/transactions.list.initial.txt"
    fi
    ;;
  *"kafka-transactions"*" describe "*)
    transactional_id="$(extract_transactional_id)"
    case "${transactional_id}" in
      recovery.txn.committed)
        cat "${TEST_FIXTURE_ROOT}/transaction-state/recovery.txn.committed.describe.txt"
        ;;
      recovery.txn.ongoing)
        cat "${TEST_FIXTURE_ROOT}/transaction-state/recovery.txn.ongoing.describe.txt"
        ;;
      recovery.txn.probe.scenario-07.*)
        cat "${TEST_FIXTURE_ROOT}/transaction-state/probe.describe.txt"
        ;;
      *)
        echo "unexpected transactional-id: ${transactional_id}" >&2
        exit 96
        ;;
    esac
    ;;
  *"python3"*"probe_transaction_state.py"*"read-committed"*)
    if [[ -f "${probe_state_file}" ]]; then
      cat "${TEST_FIXTURE_ROOT}/probes/recovery.txn.test.read-committed.after.json"
    else
      cat "${TEST_FIXTURE_ROOT}/probes/recovery.txn.test.read-committed.before.json"
    fi
    ;;
  *"python3"*"probe_transaction_state.py"*"transactional-commit"*)
    touch "${probe_state_file}"
    cat "${TEST_FIXTURE_ROOT}/probes/transactional-probe.json"
    ;;
  *)
    echo "unexpected docker invocation: ${cmdline}" >&2
    exit 97
    ;;
esac
EOF
  chmod +x "${output_path}"
}

write_transaction_state_describe() {
  local output_path="$1"
  {
    printf 'Topic: __transaction_state\tTopicId: txn-topic\tPartitionCount: 50\tReplicationFactor: 1\tConfigs: cleanup.policy=compact\n'
    for partition_id in $(seq 0 49); do
      leader=$((partition_id % 3))
      printf '\tTopic: __transaction_state\tPartition: %s\tLeader: %s\tReplicas: %s\tIsr: %s\tElr: \tLastKnownElr: \n' \
        "${partition_id}" "${leader}" "${leader}" "${leader}"
    done
  } >"${output_path}"
}

write_transaction_list() {
  local output_path="$1"
  shift
  {
    printf 'TransactionalId\tCoordinator\tProducerId\tTransactionState\t\n'
    for row in "$@"; do
      printf '%s\n' "${row}"
    done
  } >"${output_path}"
}

write_transaction_describe() {
  local output_path="$1"
  local transactional_id="$2"
  local coordinator="$3"
  local producer_id="$4"
  local producer_epoch="$5"
  local state="$6"
  cat >"${output_path}" <<EOF
CoordinatorId	TransactionalId	ProducerId	ProducerEpoch	TransactionState	TransactionTimeoutMs	CurrentTransactionStartTimeMs	TransactionDurationMs	TopicPartitions	
${coordinator}	${transactional_id}	${producer_id}	${producer_epoch}	${state}	60000	1776780191525	998800	
EOF
}

write_read_committed_probe() {
  local output_path="$1"
  local total_messages="$2"
  local per_partition="$3"
  local committed_count="$4"
  local open_count="$5"
  local probe_count="$6"
  jq -nc \
    --arg topic "recovery.txn.test" \
    --argjson total_messages "${total_messages}" \
    --argjson per_partition "${per_partition}" \
    --argjson committed_count "${committed_count}" \
    --argjson open_count "${open_count}" \
    --argjson probe_count "${probe_count}" \
    '{
      topic: $topic,
      partition_count: 6,
      eof_partitions: [0,1,2,3,4,5],
      per_partition_counts: {
        "0": $per_partition,
        "1": $per_partition,
        "2": $per_partition,
        "3": $per_partition,
        "4": $per_partition,
        "5": $per_partition
      },
      total_messages: $total_messages,
      marker_counts: {
        committed: $committed_count,
        open: $open_count,
        probe: $probe_count,
        other: 0
      },
      errors: []
    }' >"${output_path}"
}

write_transaction_probe() {
  local output_path="$1"
  local status="$2"
  local error_json="$3"
  local delivery_count="$4"
  jq -nc \
    --arg transactional_id "recovery.txn.probe.scenario-07.run" \
    --arg probe_id "run" \
    --arg status "${status}" \
    --argjson delivery_count "${delivery_count}" \
    --argjson errors "${error_json}" \
    '{
      transactional_id: $transactional_id,
      probe_id: $probe_id,
      init_transactions_status: (if ($status == "ok") then "ok" else "failed" end),
      commit_transaction_status: (if ($status == "ok") then "ok" else "failed" end),
      delivered_partitions: [range(0; $delivery_count)],
      errors: $errors
    }' >"${output_path}"
}

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local fixture_root="${workdir}/docker-fixtures"

  mkdir -p \
    "${workdir}/artifacts/assert/probes" \
    "${workdir}/artifacts/assert/transaction-state" \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/recovery" \
    "${fixture_root}/probes" \
    "${fixture_root}/transaction-state"

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
      "name": "recovery.txn.test",
      "partitions": 6,
      "payload_bytes": 256,
      "expected_read_committed_offsets": {
        "0": 100,
        "1": 100,
        "2": 100,
        "3": 100,
        "4": 100,
        "5": 100
      }
    }
  ],
  "transactions": {
    "committed_transactional_id": "recovery.txn.committed",
    "ongoing_transactional_id": "recovery.txn.ongoing",
    "committed_transaction_count": 100,
    "messages_per_committed_transaction": 6,
    "ongoing_transaction_count": 1,
    "messages_in_ongoing_transaction": 6,
    "expected_read_committed_total_messages": 600
  }
}
EOF

  cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<'EOF'
{"basename":"00000000000000001952-0000000001.checkpoint"}
EOF

  cat >"${workdir}/artifacts/prepare/quorum-state.json" <<'EOF'
{"dynamic_quorum":false}
EOF

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

  cat >"${fixture_root}/logs.txt" <<'EOF'
[2026-04-21T14:30:00Z] INFO recovery cluster ready
EOF

  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME              IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1         confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
kafka-1-1         confluentinc/cp-kafka:8.1  mock      kafka-1   now       running
kafka-2-1         confluentinc/cp-kafka:8.1  mock      kafka-2   now       running
EOF

  write_transaction_state_describe "${fixture_root}/transaction-state/__transaction_state.describe.txt"
  write_transaction_list \
    "${fixture_root}/transaction-state/transactions.list.initial.txt" \
    $'recovery.txn.committed\t2\t0\tCompleteCommit\t' \
    $'recovery.txn.ongoing\t2\t1000\tCompleteAbort\t'
  write_transaction_list \
    "${fixture_root}/transaction-state/transactions.list.after.txt" \
    $'recovery.txn.committed\t2\t0\tCompleteCommit\t' \
    $'recovery.txn.ongoing\t2\t1000\tCompleteAbort\t' \
    $'recovery.txn.probe.scenario-07.run\t1\t2000\tCompleteCommit\t'
  write_transaction_describe "${fixture_root}/transaction-state/recovery.txn.committed.describe.txt" "recovery.txn.committed" "2" "0" "0" "CompleteCommit"
  write_transaction_describe "${fixture_root}/transaction-state/recovery.txn.ongoing.describe.txt" "recovery.txn.ongoing" "2" "1000" "1" "CompleteAbort"
  write_transaction_describe "${fixture_root}/transaction-state/probe.describe.txt" "recovery.txn.probe.scenario-07.run" "1" "2000" "0" "CompleteCommit"
  write_read_committed_probe "${fixture_root}/probes/recovery.txn.test.read-committed.before.json" 600 100 600 0 0
  write_read_committed_probe "${fixture_root}/probes/recovery.txn.test.read-committed.after.json" 606 101 600 0 6
  write_transaction_probe "${fixture_root}/probes/transactional-probe.json" "ok" "[]" 6
}

prepare_run_dir "${workdir_pass}" "${run_id_pass}"
prepare_run_dir "${workdir_fail}" "${run_id_fail}"
write_stub_docker "${stub_bin_dir}/docker"

fixture_root_pass="${workdir_pass}/docker-fixtures"
fixture_root_fail="${workdir_fail}/docker-fixtures"

cp -R "${fixture_root_pass}/." "${fixture_root_fail}/"
cat >"${fixture_root_fail}/transaction-state/__transaction_state.describe.txt" <<'EOF'
Topic: __transaction_state	TopicId: txn-topic	PartitionCount: 50	ReplicationFactor: 1	Configs: cleanup.policy=compact
	Topic: __transaction_state	Partition: 0	Leader: -1	Replicas: 0	Isr: 0	Elr: 	LastKnownElr: 
EOF
write_transaction_list \
  "${fixture_root_fail}/transaction-state/transactions.list.initial.txt" \
  $'recovery.txn.committed\t2\t0\tCompleteCommit\t'
write_transaction_describe "${fixture_root_fail}/transaction-state/recovery.txn.ongoing.describe.txt" "recovery.txn.ongoing" "2" "1000" "1" "Ongoing"
write_transaction_describe "${fixture_root_fail}/transaction-state/probe.describe.txt" "recovery.txn.probe.scenario-07.run" "1" "2000" "0" "Ongoing"
write_read_committed_probe "${fixture_root_fail}/probes/recovery.txn.test.read-committed.before.json" 601 100 600 1 0
write_read_committed_probe "${fixture_root_fail}/probes/recovery.txn.test.read-committed.after.json" 602 100 600 1 2
write_transaction_probe "${fixture_root_fail}/probes/transactional-probe.json" "failed" '["initTransactions failed"]' 2

PATH="${stub_bin_dir}:${PATH}" \
TRANSACTION_STATE_TIMEOUT_SECONDS=2 \
TEST_FIXTURE_ROOT="${fixture_root_pass}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_pass}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_pass}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-07/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.total_messages' "${workdir_pass}/artifacts/assert/probes/recovery.txn.test.read-committed.before.json")" == "600" ]]
[[ "$(jq -r '.marker_counts.probe' "${workdir_pass}/artifacts/assert/probes/recovery.txn.test.read-committed.after.json")" == "6" ]]
[[ "$(jq -r '.commit_transaction_status' "${workdir_pass}/artifacts/assert/probes/transactional-probe.json")" == "ok" ]]

set +e
PATH="${stub_bin_dir}:${PATH}" \
TRANSACTION_STATE_TIMEOUT_SECONDS=2 \
TEST_FIXTURE_ROOT="${fixture_root_fail}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_fail}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_fail}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-07/assert" "${run_id_fail}"
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
grep -q 'missing-from-list' "${fail_summary}"
grep -q 'CompleteAbort' "${fail_summary}"

printf 'scenario_07_assert_test: ok\n'
