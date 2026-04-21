#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-04"
run_id_pass="test-s04-assert-pass"
run_id_fail="test-s04-assert-fail"
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

extract_group_name() {
  local pattern="$1"
  if [[ "${cmdline}" =~ ${pattern}[[:space:]]([^[:space:]]+) ]]; then
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
  *"kafka-consumer-groups"*"--describe"*)
    group_id="$(extract_group_name --group)"
    cat "${TEST_FIXTURE_ROOT}/groups/${group_id}.describe.txt"
    ;;
  *"python3"*"probe_consumer_group_resume.py"*)
    group_id="$(extract_group_name --group-id)"
    cat "${TEST_FIXTURE_ROOT}/probes/${group_id}.resume.json"
    ;;
  *)
    echo "unexpected docker invocation: ${cmdline}" >&2
    exit 97
    ;;
esac
EOF
  chmod +x "${output_path}"
}

write_group_describe() {
  local output_path="$1"
  local group_id="$2"
  local committed_offset="$3"
  local partition_limit="${4:-12}"

  {
    printf 'GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG CONSUMER-ID HOST CLIENT-ID\n'
    for partition_id in $(seq 0 $((partition_limit - 1))); do
      printf '%s %s %s %s 8000 %s - - -\n' \
        "${group_id}" \
        "recovery.consumer.test" \
        "${partition_id}" \
        "${committed_offset}" \
        "$((8000 - committed_offset))"
    done
  } >"${output_path}"
}

write_resume_probe_json() {
  local output_path="$1"
  local group_id="$2"
  local first_offset="$3"

  jq -nc \
    --arg group_id "${group_id}" \
    --arg topic "recovery.consumer.test" \
    --argjson partition_count 12 \
    --argjson first_offset "${first_offset}" \
    '{
      group_id: $group_id,
      topic: $topic,
      partition_count: $partition_count,
      assigned_partitions: [range(0; $partition_count)],
      first_seen_offsets: (reduce range(0; $partition_count) as $idx ({}; . + {($idx | tostring): $first_offset})),
      missing_partitions: [],
      errors: []
    }' >"${output_path}"
}

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local fixture_root="${workdir}/docker-fixtures"

  mkdir -p \
    "${workdir}/artifacts/assert/groups" \
    "${workdir}/artifacts/assert/probes" \
    "${workdir}/artifacts/prepare" \
    "${workdir}/artifacts/recovery" \
    "${fixture_root}/groups" \
    "${fixture_root}/probes"

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
      "name": "recovery.consumer.test",
      "partitions": 12,
      "expected_latest_offsets": {
        "0": 8000,
        "1": 8000,
        "2": 8000,
        "3": 8000,
        "4": 8000,
        "5": 8000,
        "6": 8000,
        "7": 8000,
        "8": 8000,
        "9": 8000,
        "10": 8000,
        "11": 8000
      }
    }
  ],
  "consumer_groups": [
    {
      "group_id": "recovery.group.25",
      "topic": "recovery.consumer.test",
      "expected_committed_offsets": {
        "0": 2000,
        "1": 2000,
        "2": 2000,
        "3": 2000,
        "4": 2000,
        "5": 2000,
        "6": 2000,
        "7": 2000,
        "8": 2000,
        "9": 2000,
        "10": 2000,
        "11": 2000
      }
    },
    {
      "group_id": "recovery.group.50",
      "topic": "recovery.consumer.test",
      "expected_committed_offsets": {
        "0": 4000,
        "1": 4000,
        "2": 4000,
        "3": 4000,
        "4": 4000,
        "5": 4000,
        "6": 4000,
        "7": 4000,
        "8": 4000,
        "9": 4000,
        "10": 4000,
        "11": 4000
      }
    },
    {
      "group_id": "recovery.group.75",
      "topic": "recovery.consumer.test",
      "expected_committed_offsets": {
        "0": 6000,
        "1": 6000,
        "2": 6000,
        "3": 6000,
        "4": 6000,
        "5": 6000,
        "6": 6000,
        "7": 6000,
        "8": 6000,
        "9": 6000,
        "10": 6000,
        "11": 6000
      }
    }
  ]
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
SNAPSHOT_LABEL=baseline-clean-v2
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

  cat >"${fixture_root}/logs.txt" <<'EOF'
[2026-04-21T13:00:00Z] INFO recovery cluster ready
EOF

  cat >"${fixture_root}/ps.txt" <<'EOF'
NAME              IMAGE                       COMMAND   SERVICE   CREATED   STATUS
kafka-0-1         confluentinc/cp-kafka:8.1  mock      kafka-0   now       running
kafka-1-1         confluentinc/cp-kafka:8.1  mock      kafka-1   now       running
kafka-2-1         confluentinc/cp-kafka:8.1  mock      kafka-2   now       running
EOF

  write_group_describe "${fixture_root}/groups/recovery.group.25.describe.txt" "recovery.group.25" 2000
  write_group_describe "${fixture_root}/groups/recovery.group.50.describe.txt" "recovery.group.50" 4000
  write_group_describe "${fixture_root}/groups/recovery.group.75.describe.txt" "recovery.group.75" 6000

  write_resume_probe_json "${fixture_root}/probes/recovery.group.25.resume.json" "recovery.group.25" 2000
  write_resume_probe_json "${fixture_root}/probes/recovery.group.50.resume.json" "recovery.group.50" 4000
  write_resume_probe_json "${fixture_root}/probes/recovery.group.75.resume.json" "recovery.group.75" 6000
}

prepare_run_dir "${workdir_pass}" "${run_id_pass}"
prepare_run_dir "${workdir_fail}" "${run_id_fail}"
write_stub_docker "${stub_bin_dir}/docker"

fixture_root_pass="${workdir_pass}/docker-fixtures"
fixture_root_fail="${workdir_fail}/docker-fixtures"

write_group_describe "${fixture_root_fail}/groups/recovery.group.25.describe.txt" "recovery.group.25" 2000 11
python3 - <<PY
from pathlib import Path
path = Path("${fixture_root_fail}/groups/recovery.group.50.describe.txt")
text = path.read_text()
path.write_text(text.replace("recovery.group.50 recovery.consumer.test 3 4000", "recovery.group.50 recovery.consumer.test 3 3999", 1))
PY
jq '.first_seen_offsets["7"] = 0 | .missing_partitions = [11] | .errors = ["partition 11 not observed"]' \
  "${fixture_root_fail}/probes/recovery.group.75.resume.json" >"${fixture_root_fail}/probes/recovery.group.75.resume.tmp"
mv "${fixture_root_fail}/probes/recovery.group.75.resume.tmp" "${fixture_root_fail}/probes/recovery.group.75.resume.json"

PATH="${stub_bin_dir}:${PATH}" \
GROUP_STABILIZE_ATTEMPTS=2 \
GROUP_STABILIZE_SLEEP_SECONDS=0 \
TEST_FIXTURE_ROOT="${fixture_root_pass}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_pass}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_pass}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-04/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${pass_summary}")" == "PASS" ]]
[[ "$(jq -r '."11"' "${workdir_pass}/artifacts/assert/groups/recovery.group.50.committed.json")" == "4000" ]]
[[ "$(jq -r '.first_seen_offsets["11"]' "${workdir_pass}/artifacts/assert/probes/recovery.group.75.resume.json")" == "6000" ]]

set +e
PATH="${stub_bin_dir}:${PATH}" \
GROUP_STABILIZE_ATTEMPTS=2 \
GROUP_STABILIZE_SLEEP_SECONDS=0 \
TEST_FIXTURE_ROOT="${fixture_root_fail}" \
TEST_DOCKER_LOGS_FILE="${fixture_root_fail}/logs.txt" \
TEST_DOCKER_PS_FILE="${fixture_root_fail}/ps.txt" \
  "${repo_root}/automation/scenarios/scenario-04/assert" "${run_id_fail}"
status=$?
set -e
[[ "${status}" -ne 0 ]]

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A1") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${fail_summary}")" == "FAIL" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A3") | .result' "${fail_summary}")" == "FAIL" ]]
grep -q 'partition 11 not observed' "${workdir_fail}/artifacts/assert/probes/recovery.group.75.resume.json"

printf 'scenario_04_assert_test: ok\n'
