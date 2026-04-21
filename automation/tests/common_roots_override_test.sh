#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
shared_snapshots="$(mktemp -d)"
custom_runs="$(mktemp -d)"
custom_reports="$(mktemp -d)"

cleanup() {
  rm -rf "${shared_snapshots}" "${custom_runs}" "${custom_reports}"
}
trap cleanup EXIT

SNAPSHOTS_ROOT="${shared_snapshots}" \
SCENARIO_RUNS_ROOT="${custom_runs}" \
REPORT_RUNS_ROOT="${custom_reports}" \
bash -lc "
  set -euo pipefail
  source '${repo_root}/automation/lib/common.sh'
  [[ \"\${SNAPSHOTS_ROOT}\" == '${shared_snapshots}' ]]
  [[ \"\${SCENARIO_RUNS_ROOT}\" == '${custom_runs}' ]]
  [[ \"\${REPORT_RUNS_ROOT}\" == '${custom_reports}' ]]
  [[ \"\${REPO_ROOT}\" == '${repo_root}' ]]
" >/dev/null

printf 'common_roots_override_test: ok\n'
