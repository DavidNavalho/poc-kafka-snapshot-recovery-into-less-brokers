#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-04"
run_id="test-s04-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-04-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/groups" \
  "${workdir}/artifacts/assert/probes" \
  "${workdir}/artifacts/prepare" \
  "${workdir}/artifacts/recovery"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v2
WORKDIR=${workdir}
RECOVERY_PROJECT=test-report
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

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
      "partitions": 12
    }
  ],
  "consumer_groups": [
    {
      "group_id": "recovery.group.25",
      "topic": "recovery.consumer.test",
      "expected_committed_offsets": {
        "0": 2000,
        "11": 2000
      }
    },
    {
      "group_id": "recovery.group.50",
      "topic": "recovery.consumer.test",
      "expected_committed_offsets": {
        "0": 4000,
        "11": 4000
      }
    },
    {
      "group_id": "recovery.group.75",
      "topic": "recovery.consumer.test",
      "expected_committed_offsets": {
        "0": 6000,
        "11": 6000
      }
    }
  ]
}
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<EOF
{
  "scenario": "scenario-04",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v2",
  "status": "pass",
  "generated_at_utc": "2026-04-21T14:00:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "Canonical consumer groups are present and fully described",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/groups"
    },
    {
      "id": "A2",
      "name": "Recovered committed offsets match the manifest exactly",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/groups"
    },
    {
      "id": "A3",
      "name": "Resumed consumers start exactly at the inherited offsets",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/probes"
    }
  ]
}
EOF

cat >"${workdir}/artifacts/assert/groups/recovery.group.25.expected.json" <<'EOF'
{"0":2000,"11":2000}
EOF
cat >"${workdir}/artifacts/assert/groups/recovery.group.50.expected.json" <<'EOF'
{"0":4000,"11":4000}
EOF
cat >"${workdir}/artifacts/assert/groups/recovery.group.75.expected.json" <<'EOF'
{"0":6000,"11":6000}
EOF
cat >"${workdir}/artifacts/assert/probes/recovery.group.25.resume.json" <<'EOF'
{"group_id":"recovery.group.25","first_seen_offsets":{"0":2000,"11":2000}}
EOF
printf '{}\n' >"${workdir}/artifacts/prepare/quorum-state.json"
printf '{}\n' >"${workdir}/artifacts/prepare/selected-checkpoint.json"
printf 'compose log\n' >"${workdir}/artifacts/recovery/docker-compose.log"

cat >"${stub_bin_dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "version --format {{.Server.Version}}")
    printf '26.1.0\n'
    ;;
  "compose version --short")
    printf '2.27.0\n'
    ;;
  *)
    echo "unexpected docker invocation: $*" >&2
    exit 97
    ;;
esac
EOF
chmod +x "${stub_bin_dir}/docker"

PATH="${stub_bin_dir}:${PATH}" \
  "${repo_root}/automation/scenarios/scenario-04/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 04 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'recovery.consumer.test' "${report_path}"
grep -q 'recovery.group.25' "${report_path}"
grep -q 'Proceed to Scenario 06' "${report_path}"

printf 'scenario_04_report_test: ok\n'
