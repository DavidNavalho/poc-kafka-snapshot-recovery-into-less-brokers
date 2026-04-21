#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-12"
run_id="test-s12-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-12-${run_id}.md"
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
REPEATABILITY_MANIFEST_PATH=${workdir}/artifacts/repeatability-manifest.json
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<EOF
{
  "scenario": "scenario-12",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "generated_at_utc": "2026-04-21T16:45:00Z",
  "assertions": [
    {"id":"A1","name":"run1 completed successfully","result":"PASS","evidence":"${workdir}/artifacts/repeatability-manifest.json"},
    {"id":"A2","name":"run2 completed successfully","result":"PASS","evidence":"${workdir}/artifacts/repeatability-manifest.json"},
    {"id":"A3","name":"normalized bundles were generated from the expected stable artifact surface","result":"PASS","evidence":"${workdir}/artifacts/normalized"},
    {"id":"A4","name":"normalized bundles match exactly","result":"PASS","evidence":"${workdir}/artifacts/normalized/diff.txt"}
  ]
}
EOF

cat >"${workdir}/artifacts/repeatability-manifest.json" <<EOF
{
  "scenario": "scenario-12",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "run1": {
    "suite_run_id": "${run_id}-run1",
    "status": "pass",
    "suite_manifest_path": "/tmp/run1-suite.json",
    "bundle_path": "${workdir}/artifacts/normalized/run1.bundle.json"
  },
  "run2": {
    "suite_run_id": "${run_id}-run2",
    "status": "pass",
    "suite_manifest_path": "/tmp/run2-suite.json",
    "bundle_path": "${workdir}/artifacts/normalized/run2.bundle.json"
  }
}
EOF

mkdir -p "${workdir}/artifacts/normalized"
printf '{}\n' >"${workdir}/artifacts/normalized/run1.bundle.json"
printf '{}\n' >"${workdir}/artifacts/normalized/run2.bundle.json"
: >"${workdir}/artifacts/normalized/diff.txt"

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
  "${repo_root}/automation/scenarios/scenario-12/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 12 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q "${run_id}-run1" "${report_path}"
grep -q 'clean-stop suite is now repeatable' "${report_path}"

printf 'scenario_12_report_test: ok\n'
