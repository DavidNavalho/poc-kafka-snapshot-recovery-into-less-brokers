#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-12"
run_id="test-s12-run-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
run_id_fail_fast="test-s12-run-fail-fast"
workdir_fail_fast="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id_fail_fast}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-12-${run_id}.md"
stub_root="$(mktemp -d)"
stub_suite_runner="${stub_root}/scenario-11-run"
stub_suite_runner_fail_fast="${stub_root}/scenario-11-run-fail-fast"
fail_fast_calls_log="${stub_root}/fail-fast-calls.log"

cleanup() {
  rm -rf "${workdir}" "${workdir_fail_fast}" "${stub_root}"
  rm -rf \
    "${repo_root}/fixtures/scenario-runs/scenario-11/${run_id}-run1" \
    "${repo_root}/fixtures/scenario-runs/scenario-11/${run_id}-run2" \
    "${repo_root}/fixtures/scenario-runs/scenario-11/${run_id_fail_fast}-run1" \
    "${repo_root}/fixtures/scenario-runs/scenario-11/${run_id_fail_fast}-run2" \
    "${repo_root}/fixtures/scenario-runs/scenario-01/${run_id}-run1-s01" \
    "${repo_root}/fixtures/scenario-runs/scenario-01/${run_id}-run2-s01" \
    "${repo_root}/fixtures/scenario-runs/scenario-02/${run_id}-run1-s02" \
    "${repo_root}/fixtures/scenario-runs/scenario-02/${run_id}-run2-s02"
  rm -f \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${run_id}-run1.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${run_id}-run2.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${run_id_fail_fast}-run1.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${run_id_fail_fast}-run2.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-01-${run_id}-run1-s01.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-01-${run_id}-run2-s01.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-02-${run_id}-run1-s02.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-02-${run_id}-run2-s02.md" \
    "${report_path}" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-12-${run_id_fail_fast}.md"
}
trap cleanup EXIT

cat >"${stub_suite_runner}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT:?}"
snapshot_label="${1:?}"
suite_run_id="${2:?}"
report_date="$(date -u +%F)"
suite_workdir="${repo_root}/fixtures/scenario-runs/scenario-11/${suite_run_id}"
scenario01_workdir="${repo_root}/fixtures/scenario-runs/scenario-01/${suite_run_id}-s01"
scenario02_workdir="${repo_root}/fixtures/scenario-runs/scenario-02/${suite_run_id}-s02"

mkdir -p \
  "${suite_workdir}/artifacts" \
  "${scenario01_workdir}/artifacts/assert/topics" \
  "${scenario02_workdir}/artifacts/assert/offsets" \
  "${scenario02_workdir}/artifacts/assert/samples" \
  "${repo_root}/docs/recovery/reports/runs"

cat >"${scenario01_workdir}/artifacts/assert/assert-summary.json" <<EOF2
{"status":"pass"}
EOF2
cat >"${scenario02_workdir}/artifacts/assert/assert-summary.json" <<EOF2
{"status":"pass"}
EOF2

cat >"${scenario01_workdir}/artifacts/assert/topics/recovery.default.6p.describe.txt" <<EOF2
Topic: recovery.default.6p	TopicId: test	PartitionCount: 6	ReplicationFactor: 1	Configs:
	Topic: recovery.default.6p	Partition: 0	Leader: 0	Replicas: 0	Isr: 0
	Topic: recovery.default.6p	Partition: 5	Leader: 2	Replicas: 2	Isr: 2
EOF2

cat >"${scenario02_workdir}/artifacts/assert/offsets/recovery.default.6p.offsets.txt" <<EOF2
recovery.default.6p:0:10000
recovery.default.6p:5:10000
EOF2
printf '10000\n' >"${scenario02_workdir}/artifacts/assert/samples/recovery.default.6p.p0.count.txt"
printf '10000\n' >"${scenario02_workdir}/artifacts/assert/samples/recovery.default.6p.p5.count.txt"

cat >"${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-01-${suite_run_id}-s01.md" <<EOF2
# scenario-01
EOF2
cat >"${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-02-${suite_run_id}-s02.md" <<EOF2
# scenario-02
EOF2
cat >"${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${suite_run_id}.md" <<EOF2
# scenario-11
EOF2

cat >"${suite_workdir}/artifacts/suite-manifest.json" <<EOF2
{
  "scenario": "scenario-11",
  "run_id": "${suite_run_id}",
  "snapshot_label": "${snapshot_label}",
  "status": "pass",
  "requested_core_scenarios": ["scenario-01", "scenario-02"],
  "core_scenarios": [
    {
      "scenario_id": "scenario-01",
      "run_id": "${suite_run_id}-s01",
      "status": "pass",
      "summary_path": "${scenario01_workdir}/artifacts/assert/assert-summary.json",
      "report_path": "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-01-${suite_run_id}-s01.md",
      "workdir": "${scenario01_workdir}"
    },
    {
      "scenario_id": "scenario-02",
      "run_id": "${suite_run_id}-s02",
      "status": "pass",
      "summary_path": "${scenario02_workdir}/artifacts/assert/assert-summary.json",
      "report_path": "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-02-${suite_run_id}-s02.md",
      "workdir": "${scenario02_workdir}"
    }
  ]
}
EOF2
EOF
chmod +x "${stub_suite_runner}"

cat >"${stub_suite_runner_fail_fast}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT:?}"
snapshot_label="${1:?}"
suite_run_id="${2:?}"
calls_log="${SCENARIO12_TEST_CALLS_LOG:?}"
suite_workdir="${repo_root}/fixtures/scenario-runs/scenario-11/${suite_run_id}"

printf '%s\n' "${suite_run_id}" >>"${calls_log}"

if [[ "${suite_run_id}" == *"-run1" ]]; then
  mkdir -p "${suite_workdir}/artifacts"
  cat >"${suite_workdir}/artifacts/suite-manifest.json" <<EOF2
{
  "scenario": "scenario-11",
  "run_id": "${suite_run_id}",
  "snapshot_label": "${snapshot_label}",
  "status": "fail",
  "requested_core_scenarios": ["scenario-01"],
  "core_scenarios": []
}
EOF2
  exit 1
fi

printf 'run2 should have been skipped\n' >&2
exit 99
EOF
chmod +x "${stub_suite_runner_fail_fast}"

SCENARIO12_SUITE_RUNNER="${stub_suite_runner}" \
  "${repo_root}/automation/scenarios/scenario-12/run" baseline-clean-v3 "${run_id}"

manifest_path="${workdir}/artifacts/repeatability-manifest.json"
summary_path="${workdir}/artifacts/assert/assert-summary.json"
bundle_1_path="${workdir}/artifacts/normalized/run1.bundle.json"
bundle_2_path="${workdir}/artifacts/normalized/run2.bundle.json"
diff_path="${workdir}/artifacts/normalized/diff.txt"

[[ -f "${manifest_path}" ]]
[[ -f "${summary_path}" ]]
[[ -f "${bundle_1_path}" ]]
[[ -f "${bundle_2_path}" ]]
[[ -f "${diff_path}" ]]
[[ "$(jq -r '.status' "${summary_path}")" == "pass" ]]
cmp -s "${bundle_1_path}" "${bundle_2_path}"
[[ ! -s "${diff_path}" ]]
[[ -f "${report_path}" ]]

set +e
SCENARIO12_SUITE_RUNNER="${stub_suite_runner_fail_fast}" \
SCENARIO12_TEST_CALLS_LOG="${fail_fast_calls_log}" \
  "${repo_root}/automation/scenarios/scenario-12/run" baseline-clean-v3 "${run_id_fail_fast}"
status=$?
set -e

[[ "${status}" -ne 0 ]]
manifest_path_fail_fast="${workdir_fail_fast}/artifacts/repeatability-manifest.json"
summary_path_fail_fast="${workdir_fail_fast}/artifacts/assert/assert-summary.json"
report_path_fail_fast="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-12-${run_id_fail_fast}.md"

[[ -f "${manifest_path_fail_fast}" ]]
[[ -f "${summary_path_fail_fast}" ]]
[[ "$(jq -r '.run1.status' "${manifest_path_fail_fast}")" == "fail" ]]
[[ "$(jq -r '.run2.status' "${manifest_path_fail_fast}")" == "skipped" ]]
[[ "$(jq -r '.run2.bundle_status' "${manifest_path_fail_fast}")" == "skipped" ]]
[[ "$(wc -l <"${fail_fast_calls_log}" | tr -d '[:space:]')" == "1" ]]
grep -qx "${run_id_fail_fast}-run1" "${fail_fast_calls_log}"
[[ "$(jq -r '.status' "${summary_path_fail_fast}")" == "fail" ]]
[[ -f "${report_path_fail_fast}" ]]

printf 'scenario_12_run_test: ok\n'
