#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_DIR="${ROOT_DIR}/scripts/bench"
BENCH_ENV_FILE="${BENCH_ENV_FILE:-${ROOT_DIR}/bench.env}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

load_env() {
  require_cmd curl
  require_cmd jq
  require_cmd ssh
  require_cmd scp

  [[ -f "${BENCH_ENV_FILE}" ]] || die "bench env file not found: ${BENCH_ENV_FILE}"
  # shellcheck disable=SC1090
  source "${BENCH_ENV_FILE}"

  export DO_TOKEN="${DO_TOKEN:-}"
  export DO_REGION="${DO_REGION:-sgp1}"
  export DO_SIZE="${DO_SIZE:-s-4vcpu-8gb}"
  export DO_IMAGE="${DO_IMAGE:-ubuntu-24-04-x64}"
  export DO_ENABLE_MONITORING="${DO_ENABLE_MONITORING:-true}"
  export DO_SSH_KEY_FINGERPRINT="${DO_SSH_KEY_FINGERPRINT:-}"
  export BENCH_SSH_PRIVATE_KEY="${BENCH_SSH_PRIVATE_KEY:-~/.ssh/id_rsa}"
  export BENCH_SSH_USER="${BENCH_SSH_USER:-root}"
  export BENCH_DRIVER_IP="${BENCH_DRIVER_IP:-}"
  export BENCH_DRIVER_LOCAL="${BENCH_DRIVER_LOCAL:-false}"
  export BENCH_RUN_ID="${BENCH_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
  export BENCH_WAF_IMAGE="${BENCH_WAF_IMAGE:-ghcr.io/ilyasaftr/coraza-envoy-waf:latest}"
  export BENCH_GOFILTER_INSTALL_CMD="${BENCH_GOFILTER_INSTALL_CMD:-bash /root/k3s-learn/scripts/bench/hooks/install_go_filter_variant.sh}"
  export BENCH_GOFILTER_RESOURCE_SELECTOR="${BENCH_GOFILTER_RESOURCE_SELECTOR:-app.kubernetes.io/name=envoy}"
  export BENCH_ALT_VARIANT_NAME="${BENCH_ALT_VARIANT_NAME:-go-filter}"
  export BENCH_ALT_VARIANT_KIND="${BENCH_ALT_VARIANT_KIND:-go-filter}"
  export BENCH_ALT_INSTALL_CMD="${BENCH_ALT_INSTALL_CMD:-${BENCH_GOFILTER_INSTALL_CMD}}"
  export BENCH_ALT_RESOURCE_SELECTOR="${BENCH_ALT_RESOURCE_SELECTOR:-${BENCH_GOFILTER_RESOURCE_SELECTOR}}"
  export BENCH_WASM_IMAGE="${BENCH_WASM_IMAGE:-ghcr.io/corazawaf/coraza-proxy-wasm:0.6.0}"
  export BENCH_WAF_MESSAGE_TIMEOUT="${BENCH_WAF_MESSAGE_TIMEOUT:-750ms}"
  export BENCH_WAF_NUM_STREAM_WORKERS="${BENCH_WAF_NUM_STREAM_WORKERS:-0}"
  export BENCH_WAF_REQUEST_BODY_MODE="${BENCH_WAF_REQUEST_BODY_MODE:-Buffered}"
  export BENCH_WAF_RESPONSE_BODY_MODE="${BENCH_WAF_RESPONSE_BODY_MODE:-None}"
  export BENCH_MODE="${BENCH_MODE:-fast-dev}"
  local default_scenarios default_repeats default_duration default_warmup default_cooldown
  case "${BENCH_MODE}" in
    fast-dev)
      default_scenarios="10"
      default_repeats="1"
      default_duration="20s"
      default_warmup="3"
      default_cooldown="2"
      ;;
    full)
      default_scenarios="1 10"
      default_repeats="3"
      default_duration="60s"
      default_warmup="8"
      default_cooldown="6"
      ;;
    *)
      die "BENCH_MODE must be one of: fast-dev, full"
      ;;
  esac
  export BENCH_SCENARIOS="${BENCH_SCENARIOS:-${default_scenarios}}"
  export BENCH_REPEATS="${BENCH_REPEATS:-${default_repeats}}"
  export BENCH_VUS="${BENCH_VUS:-100}"
  export BENCH_DURATION="${BENCH_DURATION:-${default_duration}}"
  export BENCH_WARMUP="${BENCH_WARMUP:-${default_warmup}}"
  export BENCH_COOLDOWN="${BENCH_COOLDOWN:-${default_cooldown}}"
  export BENCH_ATTACK_RATE="${BENCH_ATTACK_RATE:-0.02}"
  export BENCH_INFO_RATE="${BENCH_INFO_RATE:-0.08}"

  [[ -n "${DO_TOKEN}" ]] || die "DO_TOKEN is required in ${BENCH_ENV_FILE}"
  [[ -n "${DO_SSH_KEY_FINGERPRINT}" ]] || die "DO_SSH_KEY_FINGERPRINT is required in ${BENCH_ENV_FILE}"
  [[ -n "${BENCH_SSH_PRIVATE_KEY}" ]] || die "BENCH_SSH_PRIVATE_KEY is required in ${BENCH_ENV_FILE}"

  if [[ "${BENCH_SSH_PRIVATE_KEY}" == ~* ]]; then
    BENCH_SSH_PRIVATE_KEY="${HOME}${BENCH_SSH_PRIVATE_KEY#\~}"
    export BENCH_SSH_PRIVATE_KEY
  fi
  [[ -f "${BENCH_SSH_PRIVATE_KEY}" ]] || die "ssh private key not found: ${BENCH_SSH_PRIVATE_KEY}"
  [[ "${BENCH_DURATION}" =~ ^[0-9]+s$ ]] || die "BENCH_DURATION must be integer seconds, e.g. 40s"
  [[ "${DO_ENABLE_MONITORING}" == "true" || "${DO_ENABLE_MONITORING}" == "false" ]] || die "DO_ENABLE_MONITORING must be true or false"
  [[ "${BENCH_WAF_NUM_STREAM_WORKERS}" =~ ^[0-9]+$ ]] || die "BENCH_WAF_NUM_STREAM_WORKERS must be a non-negative integer"

  if [[ -z "${K3S_LEARN_REF:-}" ]]; then
    K3S_LEARN_REF="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  fi
  export K3S_LEARN_REF

  export BENCH_TAG="coraza-ab-${BENCH_RUN_ID}"
  export ARTIFACT_ROOT="${ROOT_DIR}/artifacts/${BENCH_RUN_ID}"
  export STATE_DIR="${ARTIFACT_ROOT}/state"
  export RAW_DIR="${ARTIFACT_ROOT}/raw"
  export LOG_DIR="${ARTIFACT_ROOT}/logs"
  mkdir -p "${STATE_DIR}" "${RAW_DIR}" "${LOG_DIR}"
}

api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  if [[ -n "${data}" ]]; then
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${DO_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${data}" \
      "https://api.digitalocean.com${path}"
  else
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${DO_TOKEN}" \
      "https://api.digitalocean.com${path}"
  fi
}

ssh_opts() {
  printf -- "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i %q" "${BENCH_SSH_PRIVATE_KEY}"
}

ssh_run() {
  local ip="$1"
  shift
  # shellcheck disable=SC2048,SC2086
  ssh $(ssh_opts) "${BENCH_SSH_USER}@${ip}" "$@"
}

scp_to() {
  local src="$1"
  local ip="$2"
  local dest="$3"
  # shellcheck disable=SC2048,SC2086
  scp $(ssh_opts) "${src}" "${BENCH_SSH_USER}@${ip}:${dest}"
}

wait_ssh() {
  local ip="$1"
  local tries=80
  local i
  for i in $(seq 1 "${tries}"); do
    if ssh_run "${ip}" "echo ok" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  die "ssh readiness timeout: ${ip}"
}
