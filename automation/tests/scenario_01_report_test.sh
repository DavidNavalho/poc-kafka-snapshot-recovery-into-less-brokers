#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-01"
run_id="test-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-01-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/topics" \
  "${workdir}/artifacts/prepare" \
  "${workdir}/artifacts/rewrite" \
  "${workdir}/artifacts/recovery"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v1
WORKDIR=${workdir}
RECOVERY_PROJECT=test-report
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

cat >"${workdir}/snapshot-manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v1",
  "source_fixture_version": "baseline-clean-v1",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  }
}
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<EOF
{
  "scenario": "scenario-01",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v1",
  "status": "pass",
  "generated_at_utc": "2026-04-20T10:30:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "Rewrite report succeeded",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/rewrite/rewrite-report.json"
    },
    {
      "id": "A5",
      "name": "No explicit metadata-identity or stray-detection startup failure",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/startup-failure-scan.txt"
    }
  ]
}
EOF

printf 'no startup failure patterns detected\n' >"${workdir}/artifacts/assert/startup-failure-scan.txt"
printf 'UnknownHostException: kafka-5\n' >"${workdir}/artifacts/assert/secondary-anomalies.txt"
printf 'quorum ok\n' >"${workdir}/artifacts/assert/quorum-status.txt"
printf 'describe ok\n' >"${workdir}/artifacts/assert/topics/recovery.default.6p.describe.txt"
printf '\n' >"${workdir}/artifacts/assert/topics/recovery.default.6p.unavailable.txt"
printf '{}\n' >"${workdir}/artifacts/prepare/quorum-state.json"
printf '{}\n' >"${workdir}/artifacts/prepare/selected-checkpoint.json"
printf '{}\n' >"${workdir}/artifacts/rewrite/rewrite-report.json"
printf 'metadata log\n' >"${workdir}/artifacts/rewrite/00000000000000000000.log"
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
  "${repo_root}/automation/scenarios/scenario-01/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 01 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'confluentinc/cp-kafka:8.1.0' "${report_path}"
grep -q 'UnknownHostException: kafka-5' "${report_path}"
grep -q 'Proceed to Scenario 02' "${report_path}"

printf 'scenario_01_report_test: ok\n'
