#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "${repo_root}/automation/lib/common.sh"

scenario_id="test-rewrite-cleanup"
run_id="run-$(date +%s)"
workdir="${repo_root}/fixtures/scenario-runs/${scenario_id}/${run_id}"
snapshot_label="${scenario_id}-${run_id}"
snapshot_root="${repo_root}/fixtures/snapshots/${snapshot_label}"

cleanup() {
  rm -rf "${repo_root}/fixtures/scenario-runs/${scenario_id}" "${snapshot_root}"
}
trap cleanup EXIT

mkdir -p "${workdir}/artifacts/prepare" "${workdir}/artifacts/rewrite"

metadata_cleanup_dir="${workdir}/cleanup-fixture/__cluster_metadata-0"
selected_checkpoint_path="${workdir}/artifacts/prepare/source.checkpoint"
selected_checkpoint_json="${workdir}/artifacts/prepare/selected-checkpoint.json"
quorum_state_json="${workdir}/artifacts/prepare/quorum-state.json"
stub_tool="${workdir}/stub-snapshot-rewrite-tool"

printf 'source-checkpoint\n' >"${selected_checkpoint_path}"
cat >"${selected_checkpoint_json}" <<EOF
{
  "path": "${selected_checkpoint_path}",
  "basename": "00000000000000008030-0000000001.checkpoint"
}
EOF
cat >"${quorum_state_json}" <<EOF
{
  "dynamic_quorum": false
}
EOF

cat >"${stub_tool}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_path=""
metadata_log_output_path=""
report_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output_path="$2"
      shift 2
      ;;
    --metadata-log-output)
      metadata_log_output_path="$2"
      shift 2
      ;;
    --report)
      report_path="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'rewritten-checkpoint\n' >"${output_path}"
printf 'rewritten-log\n' >"${metadata_log_output_path}"
printf 'rewritten-index\n' >"${metadata_log_output_path%.log}.index"
printf 'rewritten-timeindex\n' >"${metadata_log_output_path%.log}.timeindex"
printf '{"status":"success"}\n' >"${report_path}"
EOF
chmod +x "${stub_tool}"

mkdir -p "${metadata_cleanup_dir}"
printf 'keep-me\n' >"${metadata_cleanup_dir}/partition.metadata"
printf 'stale-epoch-cache\n' >"${metadata_cleanup_dir}/leader-epoch-checkpoint"
printf 'stale-quorum\n' >"${metadata_cleanup_dir}/quorum-state"
printf 'stale-index\n' >"${metadata_cleanup_dir}/00000000000000000000.index"

reset_metadata_snapshot_dir "${metadata_cleanup_dir}"

[[ -f "${metadata_cleanup_dir}/partition.metadata" ]]
[[ ! -e "${metadata_cleanup_dir}/leader-epoch-checkpoint" ]]
[[ ! -e "${metadata_cleanup_dir}/quorum-state" ]]
[[ ! -e "${metadata_cleanup_dir}/00000000000000000000.index" ]]

for broker_id in 0 1 2; do
  snapshot_metadata_dir="${snapshot_root}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0"
  recovery_metadata_dir="${workdir}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0"

  mkdir -p "${snapshot_metadata_dir}" "${recovery_metadata_dir}"
  printf 'shared-source-log\n' >"${snapshot_metadata_dir}/00000000000000000000.log"
  printf 'source-leader-epoch\n' >"${snapshot_metadata_dir}/leader-epoch-checkpoint"

  printf 'keep-me\n' >"${recovery_metadata_dir}/partition.metadata"
  printf 'stale-epoch-cache\n' >"${recovery_metadata_dir}/leader-epoch-checkpoint"
  printf 'stale-quorum\n' >"${recovery_metadata_dir}/quorum-state"
  printf 'stale-index\n' >"${recovery_metadata_dir}/00000000000000000000.index"
done

cat >"${workdir}/run.env" <<EOF
WORKDIR=${workdir}
SNAPSHOT_LABEL=${snapshot_label}
SELECTED_CHECKPOINT_JSON=${selected_checkpoint_json}
QUORUM_STATE_JSON=${quorum_state_json}
SURVIVING_BROKERS=0,1,2
EOF

output="$(
  SNAPSHOT_REWRITE_TOOL="${stub_tool}" \
    "${repo_root}/automation/recovery/rewrite" "${scenario_id}" "${run_id}" 2>&1
)"

for broker_id in 0 1 2; do
  recovery_metadata_dir="${workdir}/brokers/broker-${broker_id}/metadata/__cluster_metadata-0"

  [[ -f "${recovery_metadata_dir}/partition.metadata" ]]
  [[ "$(cat "${recovery_metadata_dir}/leader-epoch-checkpoint")" == "source-leader-epoch" ]]
  [[ -f "${recovery_metadata_dir}/quorum-state" ]]
  grep -q '"leaderId":-1' "${recovery_metadata_dir}/quorum-state"
  grep -q '"currentVoters":\[{"voterId":0},{"voterId":1},{"voterId":2}\]' "${recovery_metadata_dir}/quorum-state"
  [[ "$(cat "${recovery_metadata_dir}/00000000000000000000.index")" == "rewritten-index" ]]
  [[ "$(cat "${recovery_metadata_dir}/00000000000000000000.timeindex")" == "rewritten-timeindex" ]]
  [[ "$(cat "${recovery_metadata_dir}/00000000000000008030-0000000001.checkpoint")" == "rewritten-checkpoint" ]]
  [[ "$(cat "${recovery_metadata_dir}/00000000000000000000.log")" == "rewritten-log" ]]
done

grep -q "rewritten checkpoint, metadata log, sidecar indexes, leader epoch checkpoint, and quorum state installed" <<<"${output}"

printf 'rewrite_cleanup_test: ok\n'
