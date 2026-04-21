#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

fixture_json="$(python3 "${repo_root}/automation/lib/source_fixture.py" fixture-json)"

accounts_key_prefix="$(jq -r '.topics[] | select(.name == "recovery.compacted.accounts") | .key_prefix' <<<"${fixture_json}")"
orders_key_prefix="$(jq -r '.topics[] | select(.name == "recovery.compacted.orders") | .key_prefix' <<<"${fixture_json}")"

[[ "${accounts_key_prefix}" == "acct" ]]
[[ "${orders_key_prefix}" == "order" ]]

printf 'source_fixture_compacted_contract_test: ok\n'
