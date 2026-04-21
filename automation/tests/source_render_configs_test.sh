#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
temp_root="$(mktemp -d)"

cleanup() {
  rm -rf "${temp_root}"
}
trap cleanup EXIT

FIXTURES_ROOT="${temp_root}/fixtures"
export FIXTURES_ROOT

source "${repo_root}/automation/lib/common.sh"

prepare_source_dirs
render_source_configs

broker_0_config="$(source_broker_dir 0)/rendered-config/server.properties"
broker_1_config="$(source_broker_dir 1)/rendered-config/server.properties"

[[ -f "${broker_0_config}" ]]
[[ -f "${broker_1_config}" ]]
grep -q '^metadata\.log\.max\.record\.bytes\.between\.snapshots=1024$' "${broker_0_config}"
grep -q '^metadata\.log\.max\.snapshot\.interval\.ms=1000$' "${broker_0_config}"
if grep -q '^log\.cleaner\.threads=2$' "${broker_0_config}"; then
  exit 1
fi
if grep -q '^log\.cleaner\.threads=2$' "${broker_1_config}"; then
  exit 1
fi
if grep -q '^log\.retention\.hours=48$' "${broker_0_config}"; then
  exit 1
fi
if grep -q '^log\.retention\.hours=48$' "${broker_1_config}"; then
  exit 1
fi

printf 'source_render_configs_test: ok\n'
