#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

if rg -n '^\s+name:\s+\$\{HARNESS_NETWORK' \
  "${repo_root}/compose/source-cluster.compose.yml" \
  "${repo_root}/compose/recovery-cluster.compose.yml" >/dev/null; then
  echo "compose files still pin source and recovery stacks to the shared HARNESS_NETWORK" >&2
  exit 1
fi

printf 'compose_network_isolation_test: ok\n'
