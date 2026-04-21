#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-02"
run_id="test-s02-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-02-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/topics" \
  "${workdir}/artifacts/assert/offsets" \
  "${workdir}/artifacts/assert/samples" \
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
  "scenario": "scenario-02",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v1",
  "status": "pass",
  "generated_at_utc": "2026-04-21T10:00:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "Representative topics exist and are fully available",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/topics"
    },
    {
      "id": "A2",
      "name": "Latest offsets match the manifest exactly",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/offsets"
    }
  ]
}
EOF

printf 'no corruption patterns detected\n' >"${workdir}/artifacts/assert/corruption-scan.txt"
printf 'topic describe ok\n' >"${workdir}/artifacts/assert/topics/recovery.default.6p.describe.txt"
printf 'topic offsets ok\n' >"${workdir}/artifacts/assert/offsets/recovery.default.6p.offsets.txt"
printf '10000\n' >"${workdir}/artifacts/assert/samples/recovery.default.6p.p0.count.txt"
printf 'recovery.default.6p|p0|m000000|payload\n' >"${workdir}/artifacts/assert/samples/recovery.default.6p.p0.preview.txt"
printf '{}\n' >"${workdir}/artifacts/prepare/quorum-state.json"
printf '{}\n' >"${workdir}/artifacts/prepare/selected-checkpoint.json"
printf '{}\n' >"${workdir}/artifacts/rewrite/rewrite-report.json"
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
  "${repo_root}/automation/scenarios/scenario-02/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 02 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'recovery.default.6p' "${report_path}"
grep -q 'recovery.compressed.zstd' "${report_path}"
grep -q 'Proceed to Scenario 05' "${report_path}"

printf 'scenario_02_report_test: ok\n'
