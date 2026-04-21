#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-10"
run_id="test-s10-report-pass"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_date="$(date -u +%F)"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-10-${run_id}.md"
stub_bin_dir="$(mktemp -d)"

cleanup() {
  rm -rf "${workdir}" "${stub_bin_dir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/reassignment" \
  "${workdir}/artifacts/assert/samples" \
  "${workdir}/artifacts/assert/topics" \
  "${workdir}/artifacts/prepare" \
  "${workdir}/artifacts/recovery"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v3
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
  "scenario": "scenario-10",
  "run_id": "${run_id}",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "generated_at_utc": "2026-04-21T16:10:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "The recovered cluster settles cleanly into the intended RF=1 steady state",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/topics"
    },
    {
      "id": "A2",
      "name": "The deterministic reassignment payload is generated and accepted for execution",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/reassignment"
    },
    {
      "id": "A3",
      "name": "The expansion converges and does not leave persistent under-replication behind",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/reassignment"
    },
    {
      "id": "A4",
      "name": "Expanded partitions remain fully readable after reassignment",
      "result": "PASS",
      "evidence": "${workdir}/artifacts/assert/samples"
    }
  ]
}
EOF

cat >"${workdir}/artifacts/assert/reassignment/reassignment.json" <<'EOF'
{"version":1,"partitions":[{"topic":"recovery.default.6p","partition":0,"replicas":[0,1,2]}]}
EOF
printf 'Successfully started partition reassignment(s).\n' >"${workdir}/artifacts/assert/reassignment/execute.txt"
printf '10000\n' >"${workdir}/artifacts/assert/samples/recovery.default.6p.p0.count.txt"
printf '10000\n' >"${workdir}/artifacts/assert/samples/recovery.default.6p.p1.count.txt"
printf '10000\n' >"${workdir}/artifacts/assert/samples/recovery.default.6p.p2.count.txt"
printf '{}\n' >"${workdir}/artifacts/assert/topics/recovery.default.6p.pre.normalized.json"
printf '{}\n' >"${workdir}/artifacts/assert/topics/recovery.default.6p.post.normalized.json"
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
  "${repo_root}/automation/scenarios/scenario-10/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 10 Report$' "${report_path}"
grep -q "Run ID: ${run_id}" "${report_path}"
grep -q 'Result: PASS' "${report_path}"
grep -q 'recovery.default.6p' "${report_path}"
grep -q 'Proceed to Scenario 11' "${report_path}"

printf 'scenario_10_report_test: ok\n'
