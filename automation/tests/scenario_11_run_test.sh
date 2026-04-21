#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-11"
run_id="test-s11-run-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
stub_root="$(mktemp -d)"
stub_automation_root="${stub_root}/automation"
report_date="$(date -u +%F)"

cleanup() {
  rm -rf "${workdir}" "${stub_root}"
  rm -f \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-01-${run_id}-s01.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-02-${run_id}-s02.md" \
    "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${run_id}.md"
}
trap cleanup EXIT

mkdir -p \
  "${stub_automation_root}/recovery" \
  "${stub_automation_root}/scenarios/scenario-01" \
  "${stub_automation_root}/scenarios/scenario-02"

cat >"${stub_automation_root}/recovery/prepare" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT:?}"
scenario_id="${1:?}"
snapshot_label="${2:?}"
run_id="${3:?}"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"

mkdir -p "${workdir}/artifacts/assert" "${workdir}/artifacts/prepare" "${workdir}/artifacts/recovery"
cat >"${workdir}/run.env" <<RUNENV
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=${snapshot_label}
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
RUNENV
printf '{}\n' >"${workdir}/artifacts/prepare/selected-checkpoint.json"
printf '{}\n' >"${workdir}/artifacts/prepare/quorum-state.json"
printf '{"source_fixture_version":"baseline-clean-v3","image":{"vendor":"confluentinc","product":"cp-kafka","tag":"8.1.0"}}\n' >"${workdir}/snapshot-manifest.json"
printf 'prepared %s %s\n' "${scenario_id}" "${run_id}"
EOF

for step in rewrite up down; do
  cat >"${stub_automation_root}/recovery/${step}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${step} %s %s\n' "\${1:?}" "\${2:?}"
EOF
done

for scenario in scenario-01 scenario-02; do
  cat >"${stub_automation_root}/scenarios/${scenario}/assert" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT:?}"
scenario_id="$(basename "$(dirname "$0")")"
run_id="${1:?}"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
mkdir -p "${workdir}/artifacts/assert"
cat >"${workdir}/artifacts/assert/assert-summary.json" <<SUMMARY
{
  "scenario": "${scenario_id}",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "generated_at_utc": "2026-04-21T16:30:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "stub assertion",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert"
    }
  ]
}
SUMMARY
printf 'assert %s %s\n' "${scenario_id}" "${run_id}"
EOF

  cat >"${stub_automation_root}/scenarios/${scenario}/report" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root="${REPO_ROOT:?}"
scenario_id="$(basename "$(dirname "$0")")"
run_id="${1:?}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-${scenario_id}-${run_id}.md"
mkdir -p "$(dirname "${report_path}")"
cat >"${report_path}" <<REPORT
# ${scenario_id} report

- Run ID: ${run_id}
REPORT
printf 'report %s %s\n' "${scenario_id}" "${run_id}"
EOF
done

chmod +x \
  "${stub_automation_root}/recovery/prepare" \
  "${stub_automation_root}/recovery/rewrite" \
  "${stub_automation_root}/recovery/up" \
  "${stub_automation_root}/recovery/down" \
  "${stub_automation_root}/scenarios/scenario-01/assert" \
  "${stub_automation_root}/scenarios/scenario-01/report" \
  "${stub_automation_root}/scenarios/scenario-02/assert" \
  "${stub_automation_root}/scenarios/scenario-02/report"

SCENARIO11_AUTOMATION_ROOT="${stub_automation_root}" \
SCENARIO11_CORE_SCENARIOS="scenario-01,scenario-02" \
  "${repo_root}/automation/scenarios/scenario-11/run" baseline-clean-v3 "${run_id}"

manifest_path="${workdir}/artifacts/suite-manifest.json"
summary_path="${workdir}/artifacts/assert/assert-summary.json"
[[ -f "${manifest_path}" ]]
[[ -f "${summary_path}" ]]
[[ "$(jq -r '.status' "${manifest_path}")" == "pass" ]]
[[ "$(jq -r '.core_scenarios | length' "${manifest_path}")" == "2" ]]
[[ "$(jq -r '.core_scenarios[0].scenario_id' "${manifest_path}")" == "scenario-01" ]]
[[ "$(jq -r '.core_scenarios[1].scenario_id' "${manifest_path}")" == "scenario-02" ]]
[[ "$(jq -r '.core_scenarios[0].run_id' "${manifest_path}")" == "${run_id}-s01" ]]
[[ "$(jq -r '.core_scenarios[1].run_id' "${manifest_path}")" == "${run_id}-s02" ]]
[[ -f "${workdir}/artifacts/steps/scenario-01/01-prepare.log" ]]
[[ -f "${workdir}/artifacts/steps/scenario-02/06-down.log" ]]
[[ "$(jq -r '.status' "${summary_path}")" == "pass" ]]
[[ -f "${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-11-${run_id}.md" ]]

printf 'scenario_11_run_test: ok\n'
