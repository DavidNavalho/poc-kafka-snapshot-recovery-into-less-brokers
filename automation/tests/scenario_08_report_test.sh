#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-08"
run_id="test-s08-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-08-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/logdirs" \
  "${workdir}/artifacts/assert/meta" \
  "${workdir}/artifacts/assert/topics" \
  "${workdir}/artifacts/assert/samples" \
  "${workdir}/artifacts/prepare" \
  "${workdir}/artifacts/recovery"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v2
SNAPSHOT_SOURCE_ROOT=/tmp/shared-snapshots
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
  "scenario": "scenario-08",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v2",
  "status": "pass",
  "generated_at_utc": "2026-04-21T12:00:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "Recovered user partition directories match the source snapshot across both log dirs",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/logdirs"
    },
    {
      "id": "A4",
      "name": "Representative multi-disk partitions remain readable from the beginning",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/samples"
    }
  ]
}
EOF

printf 'recovery.default.6p-1\n' >"${workdir}/artifacts/assert/logdirs/broker-0.logdir-0.recovered-partitions.txt"
printf 'cluster.id=MkU3OEVBNTcwNTJENDM2Qk\n' >"${workdir}/artifacts/assert/meta/broker-0.logdir-0.recovered.normalized.properties"
printf 'Topic: recovery.default.6p\n' >"${workdir}/artifacts/assert/topics/recovery.default.6p.describe.txt"
printf '10000\n' >"${workdir}/artifacts/assert/samples/recovery.default.6p.p0.count.txt"
printf 'no stray directories detected\n' >"${workdir}/artifacts/assert/stray-scan.txt"
printf 'no startup failure patterns detected\n' >"${workdir}/artifacts/assert/startup-failure-scan.txt"
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
  "${repo_root}/automation/scenarios/scenario-08/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 08 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'recovery.default.6p' "${report_path}"
grep -q 'logdir-0' "${report_path}"
grep -q 'Proceed to Scenario 04' "${report_path}"

printf 'scenario_08_report_test: ok\n'
