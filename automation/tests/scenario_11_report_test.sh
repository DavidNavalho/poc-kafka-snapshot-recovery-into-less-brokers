#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-11"
run_id="test-s11-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p "${workdir}/artifacts/assert"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v3
WORKDIR=${workdir}
SUITE_MANIFEST_PATH=${workdir}/artifacts/suite-manifest.json
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<EOF
{
  "scenario": "scenario-11",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "generated_at_utc": "2026-04-21T16:40:00Z",
  "assertions": [
    {"id":"A1","name":"suite manifest covers the full core scenario set","result":"PASS","evidence":"${workdir}/artifacts/suite-manifest.json"},
    {"id":"A2","name":"all orchestrated scenario steps completed successfully","result":"PASS","evidence":"${workdir}/artifacts/steps"},
    {"id":"A3","name":"all orchestrated core scenarios ended in a passing assert summary","result":"PASS","evidence":"${workdir}/artifacts/suite-manifest.json"},
    {"id":"A4","name":"the suite produced a complete report bundle automatically","result":"PASS","evidence":"${workdir}/artifacts/steps"}
  ]
}
EOF

cat >"${workdir}/artifacts/suite-manifest.json" <<EOF
{
  "scenario": "scenario-11",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "requested_core_scenarios": ["scenario-01", "scenario-02"],
  "core_scenarios": [
    {
      "scenario_id": "scenario-01",
      "run_id": "${run_id}-s01",
      "status": "pass",
      "summary_path": "/tmp/scenario-01-summary.json",
      "report_path": "/tmp/scenario-01-report.md"
    },
    {
      "scenario_id": "scenario-02",
      "run_id": "${run_id}-s02",
      "status": "pass",
      "summary_path": "/tmp/scenario-02-summary.json",
      "report_path": "/tmp/scenario-02-report.md"
    }
  ]
}
EOF

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
  "${repo_root}/automation/scenarios/scenario-11/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 11 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'scenario-01' "${report_path}"
grep -q 'Proceed to Scenario 12' "${report_path}"

printf 'scenario_11_report_test: ok\n'
