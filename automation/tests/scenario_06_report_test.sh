#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-06"
run_id="test-s06-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-06-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/configs" \
  "${workdir}/artifacts/assert/compacted" \
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
  },
  "topics": [
    {
      "name": "recovery.compacted.accounts",
      "partitions": 6
    },
    {
      "name": "recovery.compacted.orders",
      "partitions": 6
    }
  ]
}
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<EOF
{
  "scenario": "scenario-06",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "generated_at_utc": "2026-04-21T14:30:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "Compacted topics retain the required dynamic compaction configs",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/configs"
    },
    {
      "id": "A2",
      "name": "Reconstructed latest-value maps match the snapshot expectation files exactly",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/compacted"
    },
    {
      "id": "A3",
      "name": "Recovery logs show no narrow cleaner-failure patterns while compact topics are exercised",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/cleaner-scan.txt"
    }
  ]
}
EOF

cat >"${workdir}/artifacts/assert/compacted/recovery.compacted.accounts.expected.json" <<'EOF'
{"acct-0-000":"v09","acct-2-042":"v09","acct-5-099":"v09"}
EOF
cat >"${workdir}/artifacts/assert/compacted/recovery.compacted.orders.expected.json" <<'EOF'
{"order-0-000":"v09","order-2-042":"v09","order-5-099":"v09"}
EOF
cat >"${workdir}/artifacts/assert/compacted/recovery.compacted.accounts.actual.json" <<'EOF'
{"acct-0-000":"v09","acct-2-042":"v09","acct-5-099":"v09"}
EOF
cat >"${workdir}/artifacts/assert/compacted/recovery.compacted.orders.actual.json" <<'EOF'
{"order-0-000":"v09","order-2-042":"v09","order-5-099":"v09"}
EOF
printf 'no cleaner failure patterns detected\n' >"${workdir}/artifacts/assert/cleaner-scan.txt"
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
  "${repo_root}/automation/scenarios/scenario-06/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 06 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'recovery.compacted.accounts' "${report_path}"
grep -q 'recovery.compacted.orders' "${report_path}"
grep -q 'Proceed to Scenario 07' "${report_path}"

printf 'scenario_06_report_test: ok\n'
