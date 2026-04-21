#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-06"
snapshot_label="baseline-clean-v3"
run_id_pass="test-s06-assert-pass"
run_id_fail="test-s06-assert-fail"
workdir_pass="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_pass}"
workdir_fail="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_fail}"
snapshot_root="${repo_root}/fixtures/test-snapshots-s06"
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

extract_topic_name() {
  if [[ "${cmdline}" =~ --topic[[:space:]]([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]//\'}"
    return 0
  fi
  return 1
}

extract_entity_name() {
  if [[ "${cmdline}" =~ --entity-name[[:space:]]([^[:space:]]+) ]]; then
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
  *"kafka-configs"*"--entity-type topics"*"--describe"*)
    topic_name="$(extract_entity_name)"
    cat "${TEST_FIXTURE_ROOT}/configs/${topic_name}.config.txt"
    ;;
  *"python3"*"probe_compacted_topic_state.py"*"latest-values"*)
    topic_name="$(extract_topic_name)"
    cat "${TEST_FIXTURE_ROOT}/probes/${topic_name}.replay.json"
    ;;
  *)
    echo "unexpected docker invocation: ${cmdline}" >&2
    exit 97
    ;;
esac
EOF
  chmod +x "${output_path}"
}

write_config_fixture() {
  local output_path="$1"
  shift
  {
    printf '%s\n' "$1"
    shift
    for line in "$@"; do
      printf '  %s\n' "${line}"
    done
  } >"${output_path}"
}

write_expectation_json() {
  local output_path="$1"
  local key_prefix="$2"
  jq -nc --arg prefix "${key_prefix}" '
    {
      topic: $prefix,
      expected_latest_values: {
        (($prefix | split(".")[-1] | if . == "accounts" then "acct-0-000" else "order-0-000" end)): "v09",
        (($prefix | split(".")[-1] | if . == "accounts" then "acct-2-042" else "order-2-042" end)): "v09",
        (($prefix | split(".")[-1] | if . == "accounts" then "acct-5-099" else "order-5-099" end)): "v09"
      }
    }' >"${output_path}"
}

write_replay_json() {
  local output_path="$1"
  local topic_name="$2"
  local key_a="$3"
  local key_b="$4"
  local key_c="$5"
  local value_a="${6:-v09}"
  local value_b="${7:-v09}"
  local value_c="${8:-v09}"

  jq -nc \
    --arg topic "${topic_name}" \
    --arg key_a "${key_a}" \
    --arg key_b "${key_b}" \
    --arg key_c "${key_c}" \
    --arg value_a "${value_a}" \
    --arg value_b "${value_b}" \
    --arg value_c "${value_c}" \
    '{
      topic: $topic,
      partition_count: 6,
      eof_partitions: [0,1,2,3,4,5],
      per_partition_counts: {"0":1000,"1":1000,"2":1000,"3":1000,"4":1000,"5":1000},
      total_messages: 6000,
      latest_values: {
        ($key_a): $value_a,
        ($key_b): $value_b,
        ($key_c): $value_c
      },
      deleted_keys: [],
      errors: []
    }' >"${output_path}"
}

prepare_snapshot_tree() {
  mkdir -p "${source_snapshot_dir}/expectations/compacted"
  write_expectation_json "${source_snapshot_dir}/expectations/compacted/recovery.compacted.accounts.json" "recovery.compacted.accounts"
  write_expectation_json "${source_snapshot_dir}/expectations/compacted/recovery.compacted.orders.json" "recovery.compacted.orders"
}

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local fixture_root="${workdir}/docker-fixtures"

  mkdir -p \
    "${workdir}/artifacts/assert/configs" \
    "${workdir}/artifacts/assert/compacted" \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/recovery" \
    "${fixture_root}/configs" \
    "${fixture_root}/probes"

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
      "name": "recovery.compacted.accounts",
      "partitions": 6,
      "configs": {
        "cleanup.policy": "compact",
        "min.cleanable.dirty.ratio": "0.1"
      }
    },
    {
      "name": "recovery.compacted.orders",
      "partitions": 6,
      "configs": {
        "cleanup.policy": "compact",
        "min.cleanable.dirty.ratio": "0.1"
      }
    }
  ],
  "expectation_files": {
    "compacted_latest_values": {
      "recovery.compacted.accounts": "expectations/compacted/recovery.compacted.accounts.json",
      "recovery.compacted.orders": "expectations/compacted/recovery.compacted.orders.json"
    }
  }
}
EOF

  cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<'EOF'
{"basename":"00000000000000001850-0000000001.checkpoint"}
EOF

  cat >"${workdir}/artifacts/prepare/quorum-state.json" <<'EOF'
{"dynamic_quorum":false}
EOF

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

  cat >"${fixture_root}/logs.txt" <<'EOF'
[2026-04-21T14:20:00Z] INFO recovery cluster ready
[2026-04-21T14:20:03Z] INFO Log cleaner thread 0 cleaned compacted segment
EOF

  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME              IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1         confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
kafka-1-1         confluentinc/cp-kafka:8.1  mock      kafka-1   now       running
kafka-2-1         confluentinc/cp-kafka:8.1  mock      kafka-2   now       running
EOF

  write_config_fixture \
    "${fixture_root}/configs/recovery.compacted.accounts.config.txt" \
    "Dynamic configs for topic recovery.compacted.accounts are:" \
    "cleanup.policy=compact sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:cleanup.policy=compact, DEFAULT_CONFIG:log.cleanup.policy=delete}" \
    "min.cleanable.dirty.ratio=0.1 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:min.cleanable.dirty.ratio=0.1, DEFAULT_CONFIG:log.cleaner.min.cleanable.ratio=0.5}"
  write_config_fixture \
    "${fixture_root}/configs/recovery.compacted.orders.config.txt" \
    "Dynamic configs for topic recovery.compacted.orders are:" \
    "cleanup.policy=compact sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:cleanup.policy=compact, DEFAULT_CONFIG:log.cleanup.policy=delete}" \
    "min.cleanable.dirty.ratio=0.1 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:min.cleanable.dirty.ratio=0.1, DEFAULT_CONFIG:log.cleaner.min.cleanable.ratio=0.5}"

  write_replay_json \
    "${fixture_root}/probes/recovery.compacted.accounts.replay.json" \
    "recovery.compacted.accounts" \
    "acct-0-000" "acct-2-042" "acct-5-099"
  write_replay_json \
    "${fixture_root}/probes/recovery.compacted.orders.replay.json" \
    "recovery.compacted.orders" \
    "order-0-000" "order-2-042" "order-5-099"
}

prepare_snapshot_tree
prepare_run_dir "${workdir_pass}" "${run_id_pass}"
prepare_run_dir "${workdir_fail}" "${run_id_fail}"
write_stub_docker "${stub_bin_dir}/docker"

fixture_root_pass="${workdir_pass}/docker-fixtures"
fixture_root_fail="${workdir_fail}/docker-fixtures"

cp -R "${fixture_root_pass}/." "${fixture_root_fail}/"
write_config_fixture \
  "${fixture_root_fail}/configs/recovery.compacted.orders.config.txt" \
  "Dynamic configs for topic recovery.compacted.orders are:" \
  "cleanup.policy=delete sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:cleanup.policy=delete, DEFAULT_CONFIG:log.cleanup.policy=delete}" \
  "min.cleanable.dirty.ratio=0.1 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:min.cleanable.dirty.ratio=0.1, DEFAULT_CONFIG:log.cleaner.min.cleanable.ratio=0.5}"
write_replay_json \
  "${fixture_root_fail}/probes/recovery.compacted.accounts.replay.json" \
  "recovery.compacted.accounts" \
  "acct-0-000" "acct-2-042" "acct-5-099" \
  "v09" "v08" "v09"
cat >"${fixture_root_fail}/logs.txt" <<'EOF'
[2026-04-21T14:20:00Z] INFO recovery cluster ready
[2026-04-21T14:20:03Z] ERROR Log cleaner thread 0 exited with exception
EOF

PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${fixture_root_pass}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_pass}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_pass}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-06/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '."acct-2-042"' "${workdir_pass}/artifacts/assert/compacted/recovery.compacted.accounts.actual.json")" == "v09" ]]
[[ "$(jq -r '."cleanup.policy"' "${workdir_pass}/artifacts/assert/configs/recovery.compacted.orders.normalized.json")" == "compact" ]]
grep -q 'no cleaner failure patterns detected' "${workdir_pass}/artifacts/assert/cleaner-scan.txt"

set +e
PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${fixture_root_fail}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_fail}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_fail}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-06/assert" "${run_id_fail}"
status=$?
set -e
[[ "${status}" -ne 0 ]]

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${fail_summary}")" == "FAIL" ]]
grep -q 'Log cleaner thread 0 exited with exception' "${workdir_fail}/artifacts/assert/cleaner-scan.txt"

printf 'scenario_06_assert_test: ok\n'
