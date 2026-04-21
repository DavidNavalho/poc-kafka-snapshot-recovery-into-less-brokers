#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-05"
run_id_pass="test-s05-assert-pass"
run_id_fail="test-s05-assert-fail"
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

extract_entity_type() {
  if [[ "${cmdline}" =~ --entity-type[[:space:]]([^[:space:]]+) ]]; then
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
  *" logs --no-color")
    cat "${TEST_DOCKER_LOGS_FILE}"
    ;;
  *" ps")
    cat "${TEST_DOCKER_PS_FILE}"
    ;;
  *"kafka-configs"*"--describe"*)
    entity_type="$(extract_entity_type)"
    entity_name="$(extract_entity_name)"
    case "${entity_type}" in
      topics)
        cat "${TEST_FIXTURE_ROOT}/topics/${entity_name}.config.txt"
        ;;
      brokers)
        cat "${TEST_FIXTURE_ROOT}/brokers/broker-${entity_name}.config.txt"
        ;;
      *)
        echo "unexpected entity type: ${entity_type}" >&2
        exit 98
        ;;
    esac
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

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local fixture_root="${workdir}/docker-fixtures"

  mkdir -p \
    "${workdir}/artifacts/assert/topics" \
    "${workdir}/artifacts/assert/brokers" \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/recovery" \
    "${fixture_root}/topics" \
    "${fixture_root}/brokers"

  cat >"${workdir}/snapshot-manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v2",
  "source_fixture_version": "baseline-clean-v2",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  },
  "topics": [
    {
      "name": "recovery.default.6p",
      "configs": {}
    },
    {
      "name": "recovery.default.12p",
      "configs": {}
    },
    {
      "name": "recovery.default.24p",
      "configs": {}
    },
    {
      "name": "recovery.retention.short",
      "configs": {
        "retention.bytes": "268435456",
        "retention.ms": "3600000"
      }
    },
    {
      "name": "recovery.retention.long",
      "configs": {
        "retention.bytes": "1073741824",
        "retention.ms": "604800000"
      }
    },
    {
      "name": "recovery.compacted.accounts",
      "configs": {
        "cleanup.policy": "compact",
        "min.cleanable.dirty.ratio": "0.1"
      }
    },
    {
      "name": "recovery.compacted.orders",
      "configs": {
        "cleanup.policy": "compact",
        "min.cleanable.dirty.ratio": "0.1"
      }
    },
    {
      "name": "recovery.compressed.zstd",
      "configs": {
        "compression.type": "zstd",
        "max.message.bytes": "10485760"
      }
    },
    {
      "name": "recovery.txn.test",
      "configs": {}
    },
    {
      "name": "recovery.consumer.test",
      "configs": {}
    }
  ],
  "broker_dynamic_configs": [
    {
      "broker_id": 0,
      "configs": {
        "log.cleaner.threads": "2"
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
SNAPSHOT_LABEL=baseline-clean-v2
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

  cat >"${fixture_root}/logs.txt" <<'EOF'
[2026-04-21T10:00:00Z] INFO recovery cluster ready
EOF

  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME              IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1         confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
kafka-1-1         confluentinc/cp-kafka:8.1  mock      kafka-1   now       running
kafka-2-1         confluentinc/cp-kafka:8.1  mock      kafka-2   now       running
EOF
}

prepare_run_dir "${workdir_pass}" "${run_id_pass}"
prepare_run_dir "${workdir_fail}" "${run_id_fail}"

write_stub_docker "${stub_bin_dir}/docker"

fixture_root_pass="${workdir_pass}/docker-fixtures"
fixture_root_fail="${workdir_fail}/docker-fixtures"

write_config_fixture \
  "${fixture_root_pass}/topics/recovery.retention.short.config.txt" \
  "Dynamic configs for topic recovery.retention.short are:" \
  "retention.bytes=268435456 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:retention.bytes=268435456, DEFAULT_CONFIG:log.retention.bytes=-1}" \
  "retention.ms=3600000 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:retention.ms=3600000}"
write_config_fixture \
  "${fixture_root_pass}/topics/recovery.retention.long.config.txt" \
  "Dynamic configs for topic recovery.retention.long are:" \
  "retention.bytes=1073741824 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:retention.bytes=1073741824, DEFAULT_CONFIG:log.retention.bytes=-1}" \
  "retention.ms=604800000 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:retention.ms=604800000}"
write_config_fixture \
  "${fixture_root_pass}/topics/recovery.compacted.accounts.config.txt" \
  "Dynamic configs for topic recovery.compacted.accounts are:" \
  "cleanup.policy=compact sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:cleanup.policy=compact, DEFAULT_CONFIG:log.cleanup.policy=delete}" \
  "min.cleanable.dirty.ratio=0.1 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:min.cleanable.dirty.ratio=0.1, DEFAULT_CONFIG:log.cleaner.min.cleanable.ratio=0.5}"
write_config_fixture \
  "${fixture_root_pass}/topics/recovery.compacted.orders.config.txt" \
  "Dynamic configs for topic recovery.compacted.orders are:" \
  "cleanup.policy=compact sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:cleanup.policy=compact, DEFAULT_CONFIG:log.cleanup.policy=delete}" \
  "min.cleanable.dirty.ratio=0.1 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:min.cleanable.dirty.ratio=0.1, DEFAULT_CONFIG:log.cleaner.min.cleanable.ratio=0.5}"
write_config_fixture \
  "${fixture_root_pass}/topics/recovery.compressed.zstd.config.txt" \
  "Dynamic configs for topic recovery.compressed.zstd are:" \
  "compression.type=zstd sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:compression.type=zstd, DEFAULT_CONFIG:compression.type=producer}" \
  "max.message.bytes=10485760 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:max.message.bytes=10485760, DEFAULT_CONFIG:message.max.bytes=1048588}"

for topic_name in recovery.default.6p recovery.default.12p recovery.default.24p recovery.txn.test recovery.consumer.test; do
  write_config_fixture "${fixture_root_pass}/topics/${topic_name}.config.txt" "Dynamic configs for topic ${topic_name} are:"
done

write_config_fixture \
  "${fixture_root_pass}/brokers/broker-0.config.txt" \
  "All configs for broker 0 are:" \
  "advertised.listeners=INTERNAL://kafka-0:9092 sensitive=false synonyms={STATIC_BROKER_CONFIG:advertised.listeners=INTERNAL://kafka-0:9092}" \
  "log.cleaner.threads=2 sensitive=false synonyms={DYNAMIC_BROKER_CONFIG:log.cleaner.threads=2, DEFAULT_CONFIG:log.cleaner.threads=1}"
write_config_fixture \
  "${fixture_root_pass}/brokers/broker-1.config.txt" \
  "All configs for broker 1 are:" \
  "advertised.listeners=INTERNAL://kafka-1:9092 sensitive=false synonyms={STATIC_BROKER_CONFIG:advertised.listeners=INTERNAL://kafka-1:9092}"
write_config_fixture \
  "${fixture_root_pass}/brokers/broker-2.config.txt" \
  "Dynamic configs for broker 2 are:"

cp -R "${fixture_root_pass}/." "${fixture_root_fail}/"

write_config_fixture \
  "${fixture_root_fail}/topics/recovery.retention.short.config.txt" \
  "Dynamic configs for topic recovery.retention.short are:" \
  "retention.bytes=268435456 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:retention.bytes=268435456, DEFAULT_CONFIG:log.retention.bytes=-1}" \
  "retention.ms=7200000 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:retention.ms=7200000}"
write_config_fixture \
  "${fixture_root_fail}/topics/recovery.default.6p.config.txt" \
  "Dynamic configs for topic recovery.default.6p are:" \
  "compression.type=zstd sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:compression.type=zstd, DEFAULT_CONFIG:compression.type=producer}"
write_config_fixture \
  "${fixture_root_fail}/brokers/broker-2.config.txt" \
  "Dynamic configs for broker 2 are:" \
  "log.cleaner.threads=4 sensitive=false synonyms={DYNAMIC_BROKER_CONFIG:log.cleaner.threads=4, DEFAULT_CONFIG:log.cleaner.threads=1}"

PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${fixture_root_pass}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_pass}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_pass}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-05/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -cS . "${workdir_pass}/artifacts/assert/topics/recovery.retention.short.normalized.json")" == '{"retention.bytes":"268435456","retention.ms":"3600000"}' ]]
[[ "$(jq -cS . "${workdir_pass}/artifacts/assert/brokers/broker-0.normalized.json")" == '{"log.cleaner.threads":"2"}' ]]
[[ "$(jq -cS . "${workdir_pass}/artifacts/assert/brokers/broker-1.normalized.json")" == '{}' ]]

set +e
PATH="${stub_bin_dir}:${PATH}" \
TEST_FIXTURE_ROOT="${fixture_root_fail}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_fail}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_fail}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-05/assert" "${run_id_fail}"
status=$?
set -e
[[ "${status}" -ne 0 ]]

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${fail_summary}")" == "FAIL" ]]
grep -q 'recovery.retention.short' "${workdir_fail}/artifacts/assert/assert-summary.json"
grep -q 'recovery.default.6p' "${workdir_fail}/artifacts/assert/assert-summary.json"
grep -q 'broker-2' "${workdir_fail}/artifacts/assert/assert-summary.json"

printf 'scenario_05_assert_test: ok\n'
