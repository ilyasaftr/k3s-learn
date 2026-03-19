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

load_profiles_yaml_from_configmap() {
  kubectl get configmap "$CM_NAME" -n "$NS" -o jsonpath='{.data.profiles\.yaml}'
}

extract_strict_block() {
  awk '
    /^  strict:/ {in_strict=1}
    in_strict {
      if ($0 ~ /^  [^[:space:]]/ && $0 !~ /^  strict:/) exit
      print
    }
  '
}

assert_outbound_observe_contract() {
  local profiles_yaml strict_block strict_mode_value
  profiles_yaml="$(load_profiles_yaml_from_configmap)"
  strict_block="$(printf '%s\n' "$profiles_yaml" | extract_strict_block)"
  strict_mode_value="$(printf '%s\n' "$strict_block" | awk '/^[[:space:]]*SecRuleEngine[[:space:]]+/ {print $2; exit}')"

  if [[ "$strict_mode_value" != "DetectionOnly" ]]; then
    echo "RESULT=FAIL"
    echo "reason=outbound-threshold-observe requires strict SecRuleEngine DetectionOnly, found ${strict_mode_value:-<empty>}"
    exit 1
  fi

  if ! printf '%s\n' "$strict_block" | grep -Eq '^[[:space:]]*SecResponseBodyMimeType[[:space:]].*application/json([[:space:]]|$)'; then
    echo "RESULT=FAIL"
    echo "reason=outbound-threshold-observe requires strict directives to include application/json in SecResponseBodyMimeType"
    exit 1
  fi
}

render_default_directives() {
  cat <<'EOF'
      Include @coraza.conf-recommended
      SecRuleEngine DetectionOnly
      SecRequestBodyAccess On
      SecRequestBodyLimit 1048576
      SecRequestBodyLimitAction Reject
      SecResponseBodyAccess On
      SecResponseBodyLimit 1048576
      SecResponseBodyLimitAction Reject
      Include @crs-setup.conf.example
      SecAction "id:10000001,phase:1,pass,nolog,t:none,setvar:tx.blocking_paranoia_level=1"
      SecAction "id:10000002,phase:1,pass,nolog,t:none,setvar:tx.inbound_anomaly_score_threshold=10"
      SecAction "id:10000003,phase:1,pass,nolog,t:none,setvar:tx.outbound_anomaly_score_threshold=8"
      Include @owasp_crs/*.conf
      SecRuleRemoveById 941130
EOF
}

render_strict_directives() {
  local engine="$1" excluded="$2" inbound="$3" outbound="$4" request_limit="$5" response_limit="$6" response_mimes="$7"

  cat <<EOF
      Include @coraza.conf-recommended
      SecRuleEngine ${engine}
      SecRequestBodyAccess On
      SecRequestBodyLimit ${request_limit}
      SecRequestBodyLimitAction Reject
      SecResponseBodyAccess On
      SecResponseBodyLimit ${response_limit}
      SecResponseBodyLimitAction Reject
      SecResponseBodyMimeType ${response_mimes}
      Include @crs-setup.conf.example
      SecAction "id:10000101,phase:1,pass,nolog,t:none,setvar:tx.blocking_paranoia_level=1"
      SecAction "id:10000102,phase:1,pass,nolog,t:none,setvar:tx.inbound_anomaly_score_threshold=${inbound}"
      SecAction "id:10000103,phase:1,pass,nolog,t:none,setvar:tx.outbound_anomaly_score_threshold=${outbound}"
      SecAction "id:10000104,phase:1,pass,nolog,t:none,setvar:tx.early_blocking=1"
      Include @owasp_crs/*.conf
EOF

  if [[ -n "$excluded" ]]; then
    printf '      SecRuleRemoveById %s\n' "$excluded"
  fi
}

strict_engine="On"
strict_excluded=""
strict_inbound="5"
strict_outbound="4"
strict_request_limit="1048576"
strict_response_limit="1048576"
strict_mimes="text/plain text/html text/xml application/json"

run_mode="status"
host="podinfo.klawu.com"
path="/"
method="GET"
payload=""
expected_code="200"

case "$checkpoint" in
  mode-detect)
    strict_engine="DetectionOnly"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  mode-block)
    strict_engine="On"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="403"
    ;;
  exclude-949110)
    strict_engine="On"
    strict_excluded="949110"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  inbound-threshold-high)
    strict_engine="On"
    strict_inbound="100"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  inbound-threshold-low)
    strict_engine="On"
    strict_inbound="1"
    run_mode="status"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="403"
    ;;
  outbound-threshold-observe)
    strict_engine="DetectionOnly"
    strict_outbound="1"
    run_mode="observe"
    path="/echo"
    method="POST"
    payload="x=<script>alert(1)</script>"
    expected_code="202"
    ;;
  request-body-limit-low)
    strict_engine="On"
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
    strict_engine="On"
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
    strict_engine="On"
    strict_inbound="100"
    strict_outbound="100"
    strict_response_limit="16"
    run_mode="status"
    path="/"
    method="GET"
    expected_code="403"
    ;;
  response-body-limit-default)
    strict_engine="On"
    strict_inbound="100"
    strict_outbound="100"
    strict_response_limit="1048576"
    run_mode="status"
    path="/"
    method="GET"
    expected_code="200"
    ;;
  query-no-body)
    strict_engine="On"
    run_mode="status"
    path='/?q=<script>alert(1)</script>'
    method="GET"
    expected_code="403"
    ;;
  scope-podinfo2-unaffected)
    strict_engine="On"
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
default_directives="$(render_default_directives)"
strict_directives="$(render_strict_directives "$strict_engine" "$strict_excluded" "$strict_inbound" "$strict_outbound" "$strict_request_limit" "$strict_response_limit" "$strict_mimes")"
cat > "$tmp_profiles" <<EOF
default_profile: default
profiles:
  default:
    directives: |
${default_directives}
  strict:
    directives: |
${strict_directives}
EOF

kubectl create configmap "$CM_NAME" -n "$NS" \
  --from-file=profiles.yaml="$tmp_profiles" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "$checkpoint" == "outbound-threshold-observe" ]]; then
  assert_outbound_observe_contract
fi

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
  observe_logs="$(kubectl logs -n "$NS" -l app=coraza-ext-proc-block --since=2m --prefix=true | grep 'coraza ext_proc request summary' | grep 'path=/echo' || true)"
  echo "CHECKPOINT=$checkpoint STATUS=$status_code EXPECTED=$expected_code"
  printf '%s\n' "$observe_logs" | tail -n 3 || true
  if [[ "$status_code" != "$expected_code" ]]; then
    echo "RESULT=FAIL"
    exit 1
  fi
  if [[ -z "$observe_logs" ]]; then
    echo "RESULT=FAIL"
    echo "reason=missing ext-proc summary logs for path=/echo"
    exit 1
  fi
  if ! printf '%s\n' "$observe_logs" | grep -Eq 'action_results='; then
    echo "RESULT=FAIL"
    echo "reason=missing action_results field in ext-proc summary logs"
    exit 1
  fi
  if ! printf '%s\n' "$observe_logs" | grep -Eq 'action[:=]response_body'; then
    echo "RESULT=FAIL"
    echo "reason=missing response_body action evidence in ext-proc summary logs"
    exit 1
  fi
  if ! printf '%s\n' "$observe_logs" | grep -Eq 'threshold[:=]1([^0-9]|$)'; then
    echo "RESULT=FAIL"
    echo "reason=missing threshold=1 evidence for response_body action"
    exit 1
  fi
  if ! printf '%s\n' "$observe_logs" | grep -Eq 'threshold_source[:=]profile_directive'; then
    echo "RESULT=FAIL"
    echo "reason=missing threshold_source=profile_directive evidence for response_body action"
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
