#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-11"
run_id_pass="test-s11-assert-pass"
run_id_fail="test-s11-assert-fail"
workdir_pass="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_pass}"
workdir_fail="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_fail}"

cleanup() {
  rm -rf "${workdir_pass}" "${workdir_fail}"
}
trap cleanup EXIT

prepare_suite_dir() {
  local workdir="$1"
  local run_id="$2"
  local scenario_status="$3"
  local summary_status="$4"

  mkdir -p \
    "${workdir}/artifacts/assert" \
    "${workdir}/artifacts/steps/scenario-01" \
    "${workdir}/artifacts/steps/scenario-02" \
    "${repo_root}/fixtures/scenario-runs/scenario-01/${run_id}-s01/artifacts/assert" \
    "${repo_root}/fixtures/scenario-runs/scenario-02/${run_id}-s02/artifacts/assert" \
    "${repo_root}/docs/recovery/reports/runs"

  cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v3
WORKDIR=${workdir}
SUITE_MANIFEST_PATH=${workdir}/artifacts/suite-manifest.json
EOF

  printf 'prepare\n' >"${workdir}/artifacts/steps/scenario-01/01-prepare.log"
  printf 'down\n' >"${workdir}/artifacts/steps/scenario-01/06-down.log"
  printf 'prepare\n' >"${workdir}/artifacts/steps/scenario-02/01-prepare.log"
  printf 'down\n' >"${workdir}/artifacts/steps/scenario-02/06-down.log"

  cat >"${repo_root}/fixtures/scenario-runs/scenario-01/${run_id}-s01/artifacts/assert/assert-summary.json" <<EOF
{"status":"${summary_status}"}
EOF
  cat >"${repo_root}/fixtures/scenario-runs/scenario-02/${run_id}-s02/artifacts/assert/assert-summary.json" <<EOF
{"status":"${summary_status}"}
EOF

  cat >"${repo_root}/docs/recovery/reports/runs/$(date -u +%F)-scenario-01-${run_id}-s01.md" <<EOF
# report
EOF
  cat >"${repo_root}/docs/recovery/reports/runs/$(date -u +%F)-scenario-02-${run_id}-s02.md" <<EOF
# report
EOF

  cat >"${workdir}/artifacts/suite-manifest.json" <<EOF
{
  "scenario": "scenario-11",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "${scenario_status}",
  "requested_core_scenarios": ["scenario-01", "scenario-02"],
  "core_scenarios": [
    {
      "scenario_id": "scenario-01",
      "run_id": "${run_id}-s01",
      "status": "${scenario_status}",
      "summary_path": "${repo_root}/fixtures/scenario-runs/scenario-01/${run_id}-s01/artifacts/assert/assert-summary.json",
      "report_path": "${repo_root}/docs/recovery/reports/runs/$(date -u +%F)-scenario-01-${run_id}-s01.md",
      "steps": [
        {"name":"prepare","status":"success","log_path":"${workdir}/artifacts/steps/scenario-01/01-prepare.log"},
        {"name":"rewrite","status":"success","log_path":"${workdir}/artifacts/steps/scenario-01/02-rewrite.log"},
        {"name":"up","status":"success","log_path":"${workdir}/artifacts/steps/scenario-01/03-up.log"},
        {"name":"assert","status":"success","log_path":"${workdir}/artifacts/steps/scenario-01/04-assert.log"},
        {"name":"report","status":"success","log_path":"${workdir}/artifacts/steps/scenario-01/05-report.log"},
        {"name":"down","status":"success","log_path":"${workdir}/artifacts/steps/scenario-01/06-down.log"}
      ]
    },
    {
      "scenario_id": "scenario-02",
      "run_id": "${run_id}-s02",
      "status": "${scenario_status}",
      "summary_path": "${repo_root}/fixtures/scenario-runs/scenario-02/${run_id}-s02/artifacts/assert/assert-summary.json",
      "report_path": "${repo_root}/docs/recovery/reports/runs/$(date -u +%F)-scenario-02-${run_id}-s02.md",
      "steps": [
        {"name":"prepare","status":"success","log_path":"${workdir}/artifacts/steps/scenario-02/01-prepare.log"},
        {"name":"rewrite","status":"success","log_path":"${workdir}/artifacts/steps/scenario-02/02-rewrite.log"},
        {"name":"up","status":"success","log_path":"${workdir}/artifacts/steps/scenario-02/03-up.log"},
        {"name":"assert","status":"success","log_path":"${workdir}/artifacts/steps/scenario-02/04-assert.log"},
        {"name":"report","status":"success","log_path":"${workdir}/artifacts/steps/scenario-02/05-report.log"},
        {"name":"down","status":"success","log_path":"${workdir}/artifacts/steps/scenario-02/06-down.log"}
      ]
    }
  ]
}
EOF

  printf 'rewrite\n' >"${workdir}/artifacts/steps/scenario-01/02-rewrite.log"
  printf 'up\n' >"${workdir}/artifacts/steps/scenario-01/03-up.log"
  printf 'assert\n' >"${workdir}/artifacts/steps/scenario-01/04-assert.log"
  printf 'report\n' >"${workdir}/artifacts/steps/scenario-01/05-report.log"
  printf 'rewrite\n' >"${workdir}/artifacts/steps/scenario-02/02-rewrite.log"
  printf 'up\n' >"${workdir}/artifacts/steps/scenario-02/03-up.log"
  printf 'assert\n' >"${workdir}/artifacts/steps/scenario-02/04-assert.log"
  printf 'report\n' >"${workdir}/artifacts/steps/scenario-02/05-report.log"
}

prepare_suite_dir "${workdir_pass}" "${run_id_pass}" "pass" "pass"
prepare_suite_dir "${workdir_fail}" "${run_id_fail}" "fail" "fail"

"${repo_root}/automation/scenarios/scenario-11/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]

"${repo_root}/automation/scenarios/scenario-11/assert" "${run_id_fail}"

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A2") | .result' "${fail_summary}")" == "FAIL" ]]

printf 'scenario_11_assert_test: ok\n'
