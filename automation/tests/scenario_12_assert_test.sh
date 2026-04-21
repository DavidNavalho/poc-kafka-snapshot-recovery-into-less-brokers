#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-12"
run_id_pass="test-s12-assert-pass"
run_id_fail="test-s12-assert-fail"
workdir_pass="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_pass}"
workdir_fail="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_fail}"

cleanup() {
  rm -rf "${workdir_pass}" "${workdir_fail}"
}
trap cleanup EXIT

prepare_run_dir() {
  local workdir="$1"
  local run_id="$2"
  local bundle_1="$3"
  local bundle_2="$4"
  local suite_status="$5"

  mkdir -p "${workdir}/artifacts/assert" "${workdir}/artifacts/normalized"

  cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v3
WORKDIR=${workdir}
REPEATABILITY_MANIFEST_PATH=${workdir}/artifacts/repeatability-manifest.json
EOF

  printf '%s\n' "${bundle_1}" >"${workdir}/artifacts/normalized/run1.bundle.json"
  printf '%s\n' "${bundle_2}" >"${workdir}/artifacts/normalized/run2.bundle.json"
  : >"${workdir}/artifacts/normalized/diff.txt"

  cat >"${workdir}/artifacts/repeatability-manifest.json" <<EOF
{
  "scenario": "scenario-12",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "run1": {
    "suite_run_id": "${run_id}-run1",
    "suite_manifest_path": "/tmp/run1-suite.json",
    "status": "${suite_status}",
    "bundle_path": "${workdir}/artifacts/normalized/run1.bundle.json"
  },
  "run2": {
    "suite_run_id": "${run_id}-run2",
    "suite_manifest_path": "/tmp/run2-suite.json",
    "status": "${suite_status}",
    "bundle_path": "${workdir}/artifacts/normalized/run2.bundle.json"
  }
}
EOF
}

prepare_run_dir "${workdir_pass}" "${run_id_pass}" '{"scenarios":{"scenario-01":{"topics":{"recovery.default.6p":6}}}}' '{"scenarios":{"scenario-01":{"topics":{"recovery.default.6p":6}}}}' "pass"
prepare_run_dir "${workdir_fail}" "${run_id_fail}" '{"scenarios":{"scenario-01":{"topics":{"recovery.default.6p":6}}}}' '{"scenarios":{"scenario-01":{"topics":{"recovery.default.6p":12}}}}' "pass"

"${repo_root}/automation/scenarios/scenario-12/assert" "${run_id_pass}"

pass_summary="${workdir_pass}/artifacts/assert/assert-summary.json"
[[ -f "${pass_summary}" ]]
[[ "$(jq -r '.status' "${pass_summary}")" == "pass" ]]

"${repo_root}/automation/scenarios/scenario-12/assert" "${run_id_fail}"

fail_summary="${workdir_fail}/artifacts/assert/assert-summary.json"
[[ -f "${fail_summary}" ]]
[[ "$(jq -r '.status' "${fail_summary}")" == "fail" ]]
[[ "$(jq -r '.assertions[] | select(.id == "A4") | .result' "${fail_summary}")" == "FAIL" ]]
[[ -s "${workdir_fail}/artifacts/normalized/diff.txt" ]]

printf 'scenario_12_assert_test: ok\n'
