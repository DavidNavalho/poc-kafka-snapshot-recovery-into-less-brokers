#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-11"
run_id="test-s11-cleanup-on-up-failure"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
stub_root="$(mktemp -d)"
stub_automation_root="${stub_root}/automation"
cleanup_log="${stub_root}/cleanup.log"

cleanup() {
  rm -rf "${workdir}" "${stub_root}"
  rm -rf "${repo_root}/fixtures/scenario-runs/scenario-01/${run_id}-s01"
}
trap cleanup EXIT

mkdir -p \
  "${stub_automation_root}/recovery" \
  "${stub_automation_root}/scenarios/scenario-01"

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
EOF

cat >"${stub_automation_root}/recovery/rewrite" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rewrite ok\n'
EOF

cat >"${stub_automation_root}/recovery/up" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'up failed after partial startup\n' >&2
exit 1
EOF

cat >"${stub_automation_root}/recovery/down" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${1:?}" "${2:?}" >>"${SCENARIO11_TEST_CLEANUP_LOG:?}"
EOF

cat >"${stub_automation_root}/scenarios/scenario-01/assert" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'assert should not run\n' >&2
exit 99
EOF

cat >"${stub_automation_root}/scenarios/scenario-01/report" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'report should not run\n' >&2
exit 99
EOF

chmod +x \
  "${stub_automation_root}/recovery/prepare" \
  "${stub_automation_root}/recovery/rewrite" \
  "${stub_automation_root}/recovery/up" \
  "${stub_automation_root}/recovery/down" \
  "${stub_automation_root}/scenarios/scenario-01/assert" \
  "${stub_automation_root}/scenarios/scenario-01/report"

set +e
SCENARIO11_AUTOMATION_ROOT="${stub_automation_root}" \
SCENARIO11_CORE_SCENARIOS="scenario-01" \
SCENARIO11_TEST_CLEANUP_LOG="${cleanup_log}" \
  "${repo_root}/automation/scenarios/scenario-11/run" baseline-clean-v3 "${run_id}"
status=$?
set -e

[[ "${status}" -ne 0 ]]
manifest_path="${workdir}/artifacts/suite-manifest.json"
summary_path="${workdir}/artifacts/assert/assert-summary.json"
[[ -f "${manifest_path}" ]]
[[ -f "${summary_path}" ]]
[[ "$(jq -r '.status' "${manifest_path}")" == "fail" ]]
[[ "$(jq -r '.core_scenarios[0].status' "${manifest_path}")" == "fail" ]]
[[ "$(jq -r '.core_scenarios[0].steps[-1].name' "${manifest_path}")" == "down" ]]
[[ "$(jq -r '.core_scenarios[0].steps[-1].status' "${manifest_path}")" == "success" ]]
grep -qx "scenario-01 ${run_id}-s01" "${cleanup_log}"

printf 'scenario_11_cleanup_test: ok\n'
