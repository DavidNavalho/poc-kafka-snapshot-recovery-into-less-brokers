#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly FIXTURES_ROOT="${FIXTURES_ROOT:-${REPO_ROOT}/fixtures}"
readonly DOCS_ROOT="${DOCS_ROOT:-${REPO_ROOT}/docs/recovery}"
readonly SOURCE_LIVE_ROOT="${SOURCE_LIVE_ROOT:-${FIXTURES_ROOT}/source-cluster/live}"
readonly SOURCE_ARTIFACTS_ROOT="${SOURCE_ARTIFACTS_ROOT:-${FIXTURES_ROOT}/source-cluster/artifacts}"
readonly SNAPSHOTS_ROOT="${SNAPSHOTS_ROOT:-${FIXTURES_ROOT}/snapshots}"
readonly SCENARIO_RUNS_ROOT="${SCENARIO_RUNS_ROOT:-${FIXTURES_ROOT}/scenario-runs}"
readonly REPORT_RUNS_ROOT="${REPORT_RUNS_ROOT:-${DOCS_ROOT}/reports/runs}"
readonly METADATA_SNAPSHOT_SUBDIR="__cluster_metadata-0"

readonly KAFKA_IMAGE="${KAFKA_IMAGE:-confluentinc/cp-kafka:8.1.0}"
readonly TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-recovery-harness-toolbox:latest}"
readonly TOOLBOX_DOCKERFILE="${TOOLBOX_DOCKERFILE:-${REPO_ROOT}/tooling/python-toolbox.Dockerfile}"
readonly KAFKA_CLUSTER_ID="${KAFKA_CLUSTER_ID:-MkU3OEVBNTcwNTJENDM2Qk}"
readonly HARNESS_NETWORK="${HARNESS_NETWORK:-recovery-harness}"
readonly SOURCE_PROJECT="${SOURCE_PROJECT:-source-cluster}"
readonly SOURCE_BOOTSTRAP_SERVER="${SOURCE_BOOTSTRAP_SERVER:-kafka-0:9092}"
readonly SOURCE_CONTROLLER_QUORUM_VOTERS="0@kafka-0:9093,1@kafka-1:9093,2@kafka-2:9093,3@kafka-3:9093,4@kafka-4:9093,5@kafka-5:9093,6@kafka-6:9093,7@kafka-7:9093,8@kafka-8:9093"
readonly RECOVERY_CONTROLLER_QUORUM_VOTERS="0@kafka-0:9093,1@kafka-1:9093,2@kafka-2:9093"


timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}


run_id_utc() {
  date -u +"%Y%m%dT%H%M%SZ"
}


log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*"
}


fail() {
  log "ERROR: $*"
  exit 1
}


require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}


ensure_dir() {
  mkdir -p "$1"
}


source_broker_dir() {
  local broker_id="$1"
  printf '%s/broker-%s' "${SOURCE_LIVE_ROOT}" "${broker_id}"
}


recovery_broker_dir() {
  local workdir="$1"
  local broker_id="$2"
  printf '%s/brokers/broker-%s' "${workdir}" "${broker_id}"
}


prepare_source_dirs() {
  local broker_id
  ensure_dir "${SOURCE_ARTIFACTS_ROOT}"
  for broker_id in {0..8}; do
    ensure_dir "$(source_broker_dir "${broker_id}")/metadata"
    ensure_dir "$(source_broker_dir "${broker_id}")/logdir-0"
    ensure_dir "$(source_broker_dir "${broker_id}")/logdir-1"
    ensure_dir "$(source_broker_dir "${broker_id}")/data-root"
    ensure_dir "$(source_broker_dir "${broker_id}")/rendered-config"
  done
}


export_compose_env() {
  export REPO_ROOT
  export KAFKA_IMAGE
  export KAFKA_CLUSTER_ID
  export HARNESS_NETWORK
}


source_compose() {
  export_compose_env
  docker compose \
    --project-name "${SOURCE_PROJECT}" \
    -f "${REPO_ROOT}/compose/source-cluster.compose.yml" \
    "$@"
}


recovery_compose() {
  local project_name="$1"
  shift
  export_compose_env
  docker compose \
    --project-name "${project_name}" \
    -f "${REPO_ROOT}/compose/recovery-cluster.compose.yml" \
    "$@"
}


wait_for_source_cluster() {
  local attempts="${1:-90}"
  local sleep_seconds="${2:-2}"
  local attempt
  for attempt in $(seq 1 "${attempts}"); do
    if source_compose exec -T kafka-0 kafka-topics --bootstrap-server "${SOURCE_BOOTSTRAP_SERVER}" --list </dev/null >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done
  fail "source cluster did not become ready"
}


wait_for_recovery_cluster() {
  local project_name="$1"
  local attempts="${2:-90}"
  local sleep_seconds="${3:-2}"
  local attempt
  for attempt in $(seq 1 "${attempts}"); do
    if recovery_compose "${project_name}" exec -T kafka-0 kafka-topics --bootstrap-server kafka-0:9092 --list </dev/null >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done
  fail "recovery cluster ${project_name} did not become ready"
}


source_topic_offsets() {
  local topic_name="$1"
  source_compose exec -T kafka-0 bash -lc "
    if command -v kafka-get-offsets >/dev/null 2>&1; then
      kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP_SERVER} --topic '${topic_name}'
    elif command -v kafka-get-offsets.sh >/dev/null 2>&1; then
      kafka-get-offsets.sh --bootstrap-server ${SOURCE_BOOTSTRAP_SERVER} --topic '${topic_name}'
    else
      kafka-run-class kafka.tools.GetOffsetShell --bootstrap-server ${SOURCE_BOOTSTRAP_SERVER} --topic '${topic_name}'
    fi
  " </dev/null
}


rack_for_broker() {
  local broker_id="$1"
  case "${broker_id}" in
    0|1|2) printf 'rack-a' ;;
    3|4|5) printf 'rack-b' ;;
    6|7|8) printf 'rack-c' ;;
    *) fail "unsupported broker id for rack mapping: ${broker_id}" ;;
  esac
}


render_server_properties() {
  local mode="$1"
  local broker_id="$2"
  local output_path="$3"
  local rack="$4"
  local external_port="$5"
  local voters="$6"
  local default_rf="$7"
  local min_isr="$8"
  local offsets_rf="$9"
  local txn_rf="${10}"
  local txn_min_isr="${11}"
  local metadata_dir="${12}"
  local log_dir_0="${13}"
  local log_dir_1="${14}"
  local topic_auto_create="${15}"
  local file_delete_delay_ms="${16:-}"
  ensure_dir "$(dirname "${output_path}")"
  cat >"${output_path}" <<EOF
# Rendered ${mode} broker config for recovery harness visibility.
broker.id=${broker_id}
node.id=${broker_id}
process.roles=broker,controller
controller.quorum.voters=${voters}
controller.listener.names=CONTROLLER
listeners=INTERNAL://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093,EXTERNAL://0.0.0.0:9094
advertised.listeners=INTERNAL://kafka-${broker_id}:9092,EXTERNAL://localhost:${external_port}
listener.security.protocol.map=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT
inter.broker.listener.name=INTERNAL
metadata.log.dir=${metadata_dir}
log.dirs=${log_dir_0},${log_dir_1}
broker.rack=${rack}
auto.create.topics.enable=${topic_auto_create}
default.replication.factor=${default_rf}
min.insync.replicas=${min_isr}
offsets.topic.replication.factor=${offsets_rf}
transaction.state.log.replication.factor=${txn_rf}
transaction.state.log.min.isr=${txn_min_isr}
group.initial.rebalance.delay.ms=0
delete.topic.enable=true
EOF
  if [[ -n "${file_delete_delay_ms}" ]]; then
    printf 'file.delete.delay.ms=%s\n' "${file_delete_delay_ms}" >>"${output_path}"
  fi
}


render_source_configs() {
  local broker_id
  for broker_id in {0..8}; do
    render_server_properties \
      "source" \
      "${broker_id}" \
      "$(source_broker_dir "${broker_id}")/rendered-config/server.properties" \
      "$(rack_for_broker "${broker_id}")" \
      "$((19092 + broker_id))" \
      "${SOURCE_CONTROLLER_QUORUM_VOTERS}" \
      "3" \
      "2" \
      "3" \
      "3" \
      "2" \
      "/var/lib/kafka/metadata" \
      "/var/lib/kafka/data-0" \
      "/var/lib/kafka/data-1" \
      "false" \
      ""
    if [[ "${broker_id}" == "0" ]]; then
      printf 'log.retention.hours=48\n' >>"$(source_broker_dir "${broker_id}")/rendered-config/server.properties"
    fi
  done
}


render_recovery_configs() {
  local workdir="$1"
  local broker_id
  for broker_id in 0 1 2; do
    render_server_properties \
      "recovery" \
      "${broker_id}" \
      "$(recovery_broker_dir "${workdir}" "${broker_id}")/rendered-config/server.properties" \
      "$(rack_for_broker "${broker_id}")" \
      "$((29092 + broker_id))" \
      "${RECOVERY_CONTROLLER_QUORUM_VOTERS}" \
      "1" \
      "1" \
      "1" \
      "1" \
      "1" \
      "/var/lib/kafka/metadata" \
      "/var/lib/kafka/data-0" \
      "/var/lib/kafka/data-1" \
      "false" \
      "86400000"
  done
}


checkpoint_json_for_root() {
  local search_root="$1"
  toolbox_python "${REPO_ROOT}/automation/lib/checkpoint_tool.py" select --search-root "${search_root}"
}


quorum_state_json() {
  local quorum_state_path="$1"
  toolbox_python "${REPO_ROOT}/automation/lib/checkpoint_tool.py" quorum-state --path "${quorum_state_path}"
}


metadata_snapshot_dir() {
  local metadata_root="$1"
  printf '%s/%s' "${metadata_root}" "${METADATA_SNAPSHOT_SUBDIR}"
}


reset_metadata_snapshot_dir() {
  local metadata_dir="$1"
  [[ -d "${metadata_dir}" ]] || fail "metadata snapshot directory does not exist: ${metadata_dir}"
  find "${metadata_dir}" -maxdepth 1 -type f ! -name 'partition.metadata' -delete
}


ensure_toolbox_image() {
  if docker image inspect "${TOOLBOX_IMAGE}" >/dev/null 2>&1; then
    return 0
  fi
  printf '[%s] %s\n' "$(timestamp_utc)" "building toolbox image ${TOOLBOX_IMAGE}" >&2
  docker build -t "${TOOLBOX_IMAGE}" -f "${TOOLBOX_DOCKERFILE}" "${REPO_ROOT}" >&2
}


toolbox_python() {
  local -a docker_args
  ensure_toolbox_image
  docker_args=(
    run
    --rm
    --user "$(id -u):$(id -g)"
    -v "${REPO_ROOT}:${REPO_ROOT}"
    -w "${REPO_ROOT}"
  )
  if docker network inspect "${HARNESS_NETWORK}" >/dev/null 2>&1; then
    docker_args+=(--network "${HARNESS_NETWORK}")
  fi
  docker "${docker_args[@]}" "${TOOLBOX_IMAGE}" python3 "$@"
}


copy_tree() {
  local source_path="$1"
  local target_path="$2"
  ensure_dir "$(dirname "${target_path}")"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${source_path}/" "${target_path}/"
  else
    cp -a "${source_path}" "${target_path}"
  fi
}


load_run_env() {
  local run_env_path="$1"
  [[ -f "${run_env_path}" ]] || fail "run env file not found: ${run_env_path}"
  # shellcheck disable=SC1090
  source "${run_env_path}"
}


sanitize_project_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}
