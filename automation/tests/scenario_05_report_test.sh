#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-05"
run_id="test-s05-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-05-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/topics" \
  "${workdir}/artifacts/assert/brokers" \
  "${workdir}/artifacts/prepare" \
  "${workdir}/artifacts/rewrite" \
  "${workdir}/artifacts/recovery"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v2
WORKDIR=${workdir}
RECOVERY_PROJECT=test-report
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

cat >"${workdir}/snapshot-manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v2",
  "source_fixture_version": "baseline-clean-v2",
  "image": {
    "vendor": "confluentinc",
    "product": "cp-kafka",
    "tag": "8.1.0"
  }
}
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<EOF
{
  "scenario": "scenario-05",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v2",
  "status": "pass",
  "generated_at_utc": "2026-04-21T10:30:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "Configured topics retain exact dynamic overrides",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/topics"
    },
    {
      "id": "A3",
      "name": "Broker 0 retains the exact dynamic broker override",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/brokers"
    }
  ]
}
EOF

printf 'topic raw dump\n' >"${workdir}/artifacts/assert/topics/recovery.retention.short.config.txt"
printf '{"retention.ms":"3600000"}\n' >"${workdir}/artifacts/assert/topics/recovery.retention.short.normalized.json"
printf 'broker raw dump\n' >"${workdir}/artifacts/assert/brokers/broker-0.config.txt"
printf '{"log.cleaner.threads":"2"}\n' >"${workdir}/artifacts/assert/brokers/broker-0.normalized.json"
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
  "${repo_root}/automation/scenarios/scenario-05/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 05 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'recovery.retention.short' "${report_path}"
grep -q 'recovery.default.6p' "${report_path}"
grep -q 'Proceed to Scenario 08' "${report_path}"

printf 'scenario_05_report_test: ok\n'
