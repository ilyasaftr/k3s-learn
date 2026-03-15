#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <apply|delete|verify>" >&2
  exit 1
fi

MODE="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="observability"
KUBECTL_BIN="${KUBECTL:-kubectl}"

declare -a DASHBOARDS=(
  "grafana-dashboard-envoy-gateway-global:dashboards/global/envoy-gateway-global.json:envoy-gateway"
  "grafana-dashboard-envoy-proxy-global:dashboards/global/envoy-proxy-global.json:envoy-gateway"
  "grafana-dashboard-envoy-clusters:dashboards/global/envoy-clusters.json:envoy-gateway"
  "grafana-dashboard-resources-monitor:dashboards/global/resources-monitor.gen.json:envoy-gateway"
  "grafana-dashboard-app-observability-template:dashboards/apps/app-observability-template.json:apps"
)

apply_dashboard() {
  local name="$1"
  local relative_path="$2"
  local folder="$3"
  local absolute_path="${ROOT_DIR}/${relative_path}"
  local filename
  filename="$(basename "${relative_path}")"

  "${KUBECTL_BIN}" create configmap "${name}" \
    --namespace "${NAMESPACE}" \
    --from-file="${filename}=${absolute_path}" \
    --dry-run=client -o yaml \
    | "${KUBECTL_BIN}" label --local -f - grafana_dashboard=1 -o yaml \
    | "${KUBECTL_BIN}" annotate --local -f - grafana_folder="${folder}" -o yaml \
    | "${KUBECTL_BIN}" apply -f -
}

case "${MODE}" in
  apply)
    for dashboard in "${DASHBOARDS[@]}"; do
      IFS=":" read -r name path folder <<<"${dashboard}"
      apply_dashboard "${name}" "${path}" "${folder}"
    done
    ;;
  delete)
    for dashboard in "${DASHBOARDS[@]}"; do
      IFS=":" read -r name _ <<<"${dashboard}"
      "${KUBECTL_BIN}" delete configmap "${name}" --namespace "${NAMESPACE}" --ignore-not-found
    done
    ;;
  verify)
    for dashboard in "${DASHBOARDS[@]}"; do
      IFS=":" read -r name _ <<<"${dashboard}"
      "${KUBECTL_BIN}" get configmap "${name}" --namespace "${NAMESPACE}"
    done
    ;;
  *)
    echo "unknown mode: ${MODE}" >&2
    exit 1
    ;;
esac
