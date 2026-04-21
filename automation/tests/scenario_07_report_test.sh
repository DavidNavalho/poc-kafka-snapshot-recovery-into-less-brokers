#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scenario_id="scenario-07"
run_id="test-s07-report-pass"
report_date="$(date -u +"%Y-%m-%d")"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
report_path="${repo_root}/docs/recovery/reports/runs/${report_date}-scenario-07-${run_id}.md"

cleanup() {
  rm -rf "${workdir}" "${report_path}"
}
trap cleanup EXIT

mkdir -p \
  "${workdir}/artifacts/assert/probes" \
  "${workdir}/artifacts/assert/transaction-state" \
  "${workdir}/artifacts/prepare"

cat >"${workdir}/run.env" <<EOF
SCENARIO_ID=${scenario_id}
RUN_ID=${run_id}
SNAPSHOT_LABEL=baseline-clean-v3
WORKDIR=${workdir}
RECOVERY_PROJECT=test-${run_id}
SELECTED_CHECKPOINT_JSON=${workdir}/artifacts/prepare/selected-checkpoint.json
QUORUM_STATE_JSON=${workdir}/artifacts/prepare/quorum-state.json
SURVIVING_BROKERS=0,1,2
EOF

cat >"${workdir}/snapshot-manifest.json" <<'EOF'
{
  "snapshot_label": "baseline-clean-v3",
  "source_fixture_version": "baseline-clean-v3",
  "transactions": {
    "committed_transactional_id": "recovery.txn.committed",
    "ongoing_transactional_id": "recovery.txn.ongoing",
    "expected_read_committed_total_messages": 600
  }
}
EOF

cat >"${workdir}/artifacts/prepare/selected-checkpoint.json" <<'EOF'
{"basename":"00000000000000001952-0000000001.checkpoint"}
EOF

cat >"${workdir}/artifacts/prepare/quorum-state.json" <<'EOF'
{"dynamic_quorum":false}
EOF

cat >"${workdir}/artifacts/assert/assert-summary.json" <<'EOF'
{
  "scenario": "scenario-07",
  "run_id": "test-s07-report-pass",
  "snapshot_label": "baseline-clean-v3",
  "status": "pass",
  "generated_at_utc": "2026-04-21T14:45:00Z",
  "assertions": [
    {
      "id": "A1",
      "name": "__transaction_state is online and canonical transactional IDs remain inspectable",
      "result": "PASS",
      "evidence": "/tmp/assert/transaction-state",
      "details": "__transaction_state is online and the canonical transactional IDs are inspectable"
    },
    {
      "id": "A2",
      "name": "Initial read_committed visibility matches the manifest and hides open-transaction records",
      "result": "PASS",
      "evidence": "/tmp/assert/probes/recovery.txn.test.read-committed.before.json",
      "details": "read_committed visibility matched the manifest exactly"
    },
    {
      "id": "A3",
      "name": "The canonical source-open transaction converges to CompleteAbort",
      "result": "PASS",
      "evidence": "/tmp/assert/transaction-state/recovery.txn.ongoing.describe.txt",
      "details": "recovery.txn.ongoing reached CompleteAbort"
    },
    {
      "id": "A4",
      "name": "A new transactional producer can initialize, commit, and become visible to read_committed",
      "result": "PASS",
      "evidence": "/tmp/assert/probes/transactional-probe.json",
      "details": "the post-recovery transactional probe committed successfully and became visible to read_committed"
    }
  ]
}
EOF

cat >"${workdir}/artifacts/assert/probes/recovery.txn.test.read-committed.before.json" <<'EOF'
{"total_messages":600,"marker_counts":{"committed":600,"open":0,"probe":0}}
EOF

cat >"${workdir}/artifacts/assert/probes/recovery.txn.test.read-committed.after.json" <<'EOF'
{"total_messages":606,"marker_counts":{"committed":600,"open":0,"probe":6}}
EOF

cat >"${workdir}/artifacts/assert/probes/transactional-probe.json" <<'EOF'
{"transactional_id":"recovery.txn.probe.scenario-07.run","commit_transaction_status":"ok","errors":[]}
EOF

cat >"${workdir}/artifacts/assert/transaction-state/recovery.txn.committed.describe.txt" <<'EOF'
CoordinatorId	TransactionalId	ProducerId	ProducerEpoch	TransactionState
2	recovery.txn.committed	0	0	CompleteCommit
EOF

cat >"${workdir}/artifacts/assert/transaction-state/recovery.txn.ongoing.describe.txt" <<'EOF'
CoordinatorId	TransactionalId	ProducerId	ProducerEpoch	TransactionState
2	recovery.txn.ongoing	1000	1	CompleteAbort
EOF

cat >"${workdir}/artifacts/assert/transaction-state/recovery.txn.probe.scenario-07.run.describe.txt" <<'EOF'
CoordinatorId	TransactionalId	ProducerId	ProducerEpoch	TransactionState
1	recovery.txn.probe.scenario-07.run	2000	0	CompleteCommit
EOF

"${repo_root}/automation/scenarios/scenario-07/report" "${run_id}"

[[ -f "${report_path}" ]]
grep -q '^# Scenario 07 Report$' "${report_path}"
grep -q 'baseline-clean-v3' "${report_path}"
grep -q 'CompleteAbort' "${report_path}"
grep -q '606' "${report_path}"
grep -q 'recovery.txn.probe.scenario-07.run' "${report_path}"
grep -q 'Initial `read_committed` total messages' "${report_path}"

printf 'scenario_07_report_test: ok\n'
