#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" || "${1:-}" == "help" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage:
  scripts/waf_checkpoint.sh list
  scripts/waf_checkpoint.sh <checkpoint>

Checkpoints:
  mode-detect
  mode-block
  exclude-949110
  inbound-threshold-high
  inbound-threshold-low
  outbound-threshold-observe
  request-body-limit-low
  request-body-limit-default
  response-body-limit-low
  response-body-limit-default
  query-no-body
  scope-podinfo2-unaffected

Notes:
  - This script updates ConfigMap/coraza-ext-proc-profiles in gateway-system.
  - It runs one checkpoint only (no all-in-one matrix).
USAGE
  exit 0
fi

if [[ "${1:-}" == "list" ]]; then
  cat <<'LIST'
mode-detect
mode-block
exclude-949110
inbound-threshold-high
inbound-threshold-low
outbound-threshold-observe
request-body-limit-low
request-body-limit-default
response-body-limit-low
response-body-limit-default
query-no-body
scope-podinfo2-unaffected
LIST
  exit 0
fi

checkpoint="$1"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require kubectl
require curl

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CM_NAME="coraza-ext-proc-profiles"
NS="gateway-system"
DEPLOY="coraza-ext-proc-block"

strict_mode="block"
strict_excluded="[]"
strict_inbound="5"
strict_outbound="4"
strict_request_limit="1048576"
strict_response_limit="1048576"
strict_on_error="deny"
strict_mimes="      - text/plain
      - text/html
      - text/xml
      - application/json"

run_mode="status"
host="podinfo.klawu.com"
path="/"
method="GET"
payload=""
expected_code="200"

case "$checkpoint" in
  mode-detect)
    strict_mode="detect"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  mode-block)
    strict_mode="block"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="403"
    ;;
  exclude-949110)
    strict_mode="block"
    strict_excluded="[949110]"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  inbound-threshold-high)
    strict_mode="block"
    strict_inbound="100"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  inbound-threshold-low)
    strict_mode="block"
    strict_inbound="1"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="403"
    ;;
  outbound-threshold-observe)
    strict_mode="detect"
    strict_outbound="1"
    run_mode="observe"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  request-body-limit-low)
    strict_mode="block"
    strict_inbound="100"
    strict_outbound="100"
    strict_request_limit="16"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    expected_code="403"
    ;;
  request-body-limit-default)
    strict_mode="block"
    strict_inbound="100"
    strict_outbound="100"
    strict_request_limit="1048576"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    expected_code="202"
    ;;
  response-body-limit-low)
    strict_mode="block"
    strict_inbound="100"
    strict_outbound="100"
    strict_response_limit="16"
    run_mode="status"
    path="/"
    method="GET"
    expected_code="403"
    ;;
  response-body-limit-default)
    strict_mode="block"
    strict_inbound="100"
    strict_outbound="100"
    strict_response_limit="1048576"
    run_mode="status"
    path="/"
    method="GET"
    expected_code="200"
    ;;
  query-no-body)
    strict_mode="block"
    run_mode="status"
    path='/?q=<script>alert(1)</script>'
    method="GET"
    expected_code="403"
    ;;
  scope-podinfo2-unaffected)
    strict_mode="block"
    run_mode="status"
    host="podinfo-2.klawu.com"
    path='/?q=<script>alert(1)</script>'
    method="GET"
    expected_code="200"
    ;;
  *)
    echo "unknown checkpoint: $checkpoint" >&2
    exit 1
    ;;
esac

tmp_profiles="$(mktemp)"
cat > "$tmp_profiles" <<EOF
default_profile: default
profiles:
  default:
    mode: detect
    excluded_rule_ids:
      - 941130
    inbound_anomaly_score_threshold: 10
    outbound_anomaly_score_threshold: 8
    request_body_limit_bytes: 1048576
    response_body_limit_bytes: 1048576
    on_error:
      default: deny
  strict:
    mode: ${strict_mode}
    excluded_rule_ids: ${strict_excluded}
    inbound_anomaly_score_threshold: ${strict_inbound}
    outbound_anomaly_score_threshold: ${strict_outbound}
    request_body_limit_bytes: ${strict_request_limit}
    response_body_limit_bytes: ${strict_response_limit}
    response_body_mime_types:
${strict_mimes}
    on_error:
      default: ${strict_on_error}
EOF

kubectl create configmap "$CM_NAME" -n "$NS" \
  --from-file=profiles.yaml="$tmp_profiles" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deploy/"$DEPLOY" -n "$NS" >/dev/null
kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null

kubectl -n "$NS" port-forward deploy/shared-gateway 18443:10443 >/tmp/waf-checkpoint-pf.log 2>&1 &
pf_pid=$!
trap 'kill $pf_pid >/dev/null 2>&1 || true; rm -f "$tmp_profiles"' EXIT
sleep 2

curl_args=(
  -sk
  --resolve podinfo.klawu.com:18443:127.0.0.1
  --resolve podinfo-2.klawu.com:18443:127.0.0.1
  -X "$method"
)
if [[ -n "$payload" ]]; then
  curl_args+=(-H "Content-Type: text/plain" --data "$payload")
fi

url="https://${host}:18443${path}"
status_code="$(curl "${curl_args[@]}" -o /tmp/waf-checkpoint.out -w '%{http_code}' "$url")"

if [[ "$run_mode" == "observe" ]]; then
  echo "CHECKPOINT=$checkpoint STATUS=$status_code EXPECTED=$expected_code"
  kubectl logs -n "$NS" deploy/"$DEPLOY" --since=2m | grep 'path=/echo' | tail -n 3 || true
  if [[ "$status_code" != "$expected_code" ]]; then
    echo "RESULT=FAIL"
    exit 1
  fi
  echo "RESULT=PASS (observe)"
  exit 0
fi

echo "CHECKPOINT=$checkpoint STATUS=$status_code EXPECTED=$expected_code URL=$url"
if [[ "$status_code" != "$expected_code" ]]; then
  echo "RESULT=FAIL"
  echo "--- response body (first 200 bytes) ---"
  head -c 200 /tmp/waf-checkpoint.out || true
  echo
  exit 1
fi
echo "RESULT=PASS"
