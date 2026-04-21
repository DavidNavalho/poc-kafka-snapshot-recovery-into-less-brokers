#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-03"
run_id="test-s03-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-03-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/positive" \
  "${workdir}/artifacts/assert/negative" \
  "${workdir}/artifacts/assert/restored/topics" \
  "${workdir}/artifacts/assert/restored/samples" \
  "${workdir}/artifacts/prepare" \
  "${workdir}/artifacts/recovery"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v3
SNAPSHOT_SOURCE_ROOT=/tmp/shared-snapshots
WORKDIR=${workdir}
RECOVERY_PROJECT=test-report
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

cat >"${workdir}/snapshot-manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v3",
  "source_fixture_version": "baseline-clean-v3",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  }
}
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<EOF
{
  "scenario": "scenario-03",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "generated_at_utc": "2026-04-21T15:10:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "Happy-path recovery produces no stray directories or explicit stray startup failures",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/positive"
    },
    {
      "id": "A2",
      "name": "The injected metadata fault creates the expected stray directory",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/negative"
    },
    {
      "id": "A4",
      "name": "Restoring the clean metadata and renaming the directory back allows a clean restart",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/restored"
    }
  ]
}
EOF

printf 'no stray directories detected\n' >"${workdir}/artifacts/assert/positive/stray-scan.txt"
printf 'recovery.default.6p-0-stray\n' >"${workdir}/artifacts/assert/negative/stray-dirs.txt"
printf 'partition.metadata\n00000000000000000000.log\n' >"${workdir}/artifacts/assert/negative/recovery.default.6p-0-stray.contents.txt"
printf 'ClusterId: MkU3OEVBNTcwNTJENDM2Qk\nLeaderId: 2\nCurrentVoters: [{\"id\":0},{\"id\":1},{\"id\":2}]\n' >"${workdir}/artifacts/assert/restored/quorum-status.txt"
printf 'Topic: recovery.default.6p\n' >"${workdir}/artifacts/assert/restored/topics/recovery.default.6p.describe.txt"
printf '10000\n' >"${workdir}/artifacts/assert/restored/samples/recovery.default.6p.p0.count.txt"
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
  "${repo_root}/automation/scenarios/scenario-03/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 03 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'Happy Path' "${report_path}"
grep -q 'Injected Fault' "${report_path}"
grep -q 'Restored Restart' "${report_path}"
grep -q 'Proceed to Scenario 10' "${report_path}"

printf 'scenario_03_report_test: ok\n'
