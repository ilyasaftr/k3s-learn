#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
load_env

HOSTS_ENV="${STATE_DIR}/hosts.env"
[[ -f "${HOSTS_ENV}" ]] || die "missing hosts env: ${HOSTS_ENV} (run do_create.sh first)"
# shellcheck disable=SC1090
source "${HOSTS_ENV}"

hydrate_host_from_droplets_tsv() {
  local role="$1"
  local var_prefix="$2"
  local line id name ip
  line="$(awk -F'\t' -v r="${role}" '$1==r {print $0; exit}' "${STATE_DIR}/droplets.tsv" 2>/dev/null || true)"
  [[ -n "${line}" ]] || return 0
  name="$(printf '%s\n' "${line}" | awk -F'\t' '{print $2}')"
  id="$(printf '%s\n' "${line}" | awk -F'\t' '{print $3}')"
  [[ -n "${id}" ]] || return 0
  ip="$(api GET "/v2/droplets/${id}" | jq -r '.droplet.networks.v4[]? | select(.type=="public") | .ip_address' | head -n1)"
  [[ -n "${ip}" ]] || return 0
  export "${var_prefix}_NAME=${name}"
  export "${var_prefix}_IP=${ip}"
  export "${var_prefix}_ID=${id}"
}

if [[ -z "${SUT_WAF_IP:-}" ]]; then
  hydrate_host_from_droplets_tsv "sut-waf" "SUT_WAF"
fi
if [[ -z "${SUT_GOFILTER_IP:-}" ]]; then
  hydrate_host_from_droplets_tsv "sut-go-filter" "SUT_GOFILTER"
fi
if [[ -z "${BENCH_DRIVER_IP:-}" ]]; then
  hydrate_host_from_droplets_tsv "bench-driver" "BENCH_DRIVER"
fi

[[ -n "${SUT_WAF_IP:-}" ]] || die "missing SUT_WAF_IP after host hydration"
[[ -n "${SUT_GOFILTER_IP:-}" ]] || die "missing SUT_GOFILTER_IP after host hydration"
[[ -n "${BENCH_DRIVER_IP:-}" ]] || die "missing BENCH_DRIVER_IP after host hydration"

ALT_VARIANT_NAME="${BENCH_ALT_VARIANT_NAME}"
ALT_VARIANT_KIND="${BENCH_ALT_VARIANT_KIND}"

K6_REMOTE_SCRIPT="/tmp/bench-k6.js"
K6_REMOTE_SUMMARY="/tmp/k6-summary.json"
K6_REMOTE_OUT="/tmp/k6-run.log"
RESULTS_CSV="${RAW_DIR}/results.csv"
SAMPLER_DIR="${RAW_DIR}/samplers"
mkdir -p "${SAMPLER_DIR}"
SAMPLER_SCRIPT_LOCAL="${RAW_DIR}/bench-sampler.sh"

cat > "${RAW_DIR}/bench-k6.js" <<'EOF'
import http from "k6/http";
import { check, sleep } from "k6";
import { Counter } from "k6/metrics";

const status2xx = new Counter("status_2xx");
const status4xx = new Counter("status_4xx");
const status5xx = new Counter("status_5xx");
const status403 = new Counter("status_403");

const hosts = (__ENV.HOSTS_CSV || "").split(",").filter(Boolean);
const targetIp = __ENV.TARGET_IP;
const scheme = __ENV.SCHEME || "http";

export const options = {
  vus: Number(__ENV.VUS || 100),
  duration: __ENV.DURATION || "40s",
  insecureSkipTLSVerify: true,
};

let idx = 0;
function nextHost() {
  const host = hosts[idx % hosts.length];
  idx++;
  return host;
}

export default function () {
  const host = nextHost();
  const r = Math.random();
  let path = "/";
  if (r < Number(__ENV.ATTACK_RATE || 0.02)) {
    path = "/?q=%3Cscript%3Ealert(1)%3C/script%3E";
  } else if (r < Number(__ENV.ATTACK_RATE || 0.02) + Number(__ENV.INFO_RATE || 0.08)) {
    path = "/api/info";
  }
  const url = `${scheme}://${targetIp}${path}`;
  const res = http.get(url, {
    headers: {
      Host: host,
      "User-Agent": "k6-ab-bench/1.0",
    },
  });

  if (res.status >= 200 && res.status < 300) status2xx.add(1);
  else if (res.status >= 400 && res.status < 500) status4xx.add(1);
  else if (res.status >= 500) status5xx.add(1);
  if (res.status === 403) status403.add(1);

  check(res, { "status < 600": (r) => r.status < 600 });
  sleep(0.05);
}
EOF

if [[ "${BENCH_DRIVER_IP}" == "local" ]]; then
  cp "${RAW_DIR}/bench-k6.js" "${K6_REMOTE_SCRIPT}"
else
  scp_to "${RAW_DIR}/bench-k6.js" "${BENCH_DRIVER_IP}" "${K6_REMOTE_SCRIPT}"
fi

render_bench_manifest() {
  local n="$1"
  local out="$2"
  cat > "${out}" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: bench
---
EOF
  local i
  for i in $(seq 1 "${n}"); do
    cat >> "${out}" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo-${i}
  namespace: bench
spec:
  replicas: 1
  selector:
    matchLabels:
      app: podinfo-${i}
  template:
    metadata:
      labels:
        app: podinfo-${i}
    spec:
      containers:
      - name: podinfo
        image: stefanprodan/podinfo:6.11.0
        command: ["./podinfo"]
        args: ["--port=9898","--port-metrics=9797"]
        ports:
        - containerPort: 9898
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo-${i}
  namespace: bench
spec:
  selector:
    app: podinfo-${i}
  ports:
  - name: http
    port: 9898
    targetPort: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo-${i}
  namespace: bench
spec:
  parentRefs:
  - name: shared-gateway
    namespace: gateway-system
    sectionName: http
  hostnames:
  - podinfo-${i}.klawu.com
  rules:
  - backendRefs:
    - name: podinfo-${i}
      port: 9898
---
EOF
  done
}

render_waf_policy() {
  local n="$1"
  local out="$2"
  cat > "${out}" <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: bench-waf
  namespace: bench
spec:
  targetRefs:
EOF
  local i
  for i in $(seq 1 "${n}"); do
    cat >> "${out}" <<EOF
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: podinfo-${i}
EOF
  done
  cat >> "${out}" <<EOF
  extProc:
  - backendRefs:
    - group: ""
      kind: Service
      name: coraza-ext-proc-block
      namespace: gateway-system
      port: 9002
    failOpen: false
    messageTimeout: ${BENCH_WAF_MESSAGE_TIMEOUT}
    processingMode:
      request:
        body: ${BENCH_WAF_REQUEST_BODY_MODE}
EOF

  if [[ "${BENCH_WAF_RESPONSE_BODY_MODE}" != "None" ]]; then
    cat >> "${out}" <<EOF
      response:
        body: ${BENCH_WAF_RESPONSE_BODY_MODE}
EOF
  fi
}

render_wasm_policy() {
  local n="$1"
  local out="$2"
  cat > "${out}" <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: bench-wasm
  namespace: bench
spec:
  targetRefs:
EOF
  local i
  for i in $(seq 1 "${n}"); do
    cat >> "${out}" <<EOF
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: podinfo-${i}
EOF
  done
  cat >> "${out}" <<EOF
  wasm:
  - name: coraza-proxy-wasm
    failOpen: false
    code:
      type: Image
      image:
        url: ${BENCH_WASM_IMAGE}
    config:
      default_directives: default
      directives_map:
        default:
        - Include @recommended-conf
        - SecRuleEngine On
        - Include @crs-setup-conf
        - SecRequestBodyLimit 4096
        - SecRequestBodyInMemoryLimit 4096
        - SecRequestBodyNoFilesLimit 4096
        - SecResponseBodyLimit 4096
        - SecResponseBodyMimeType text/plain text/html text/xml application/json
        - Include @owasp_crs/*.conf
EOF
}

prepare_scenario_on_sut() {
  local ip="$1"
  local variant_label="$2"
  local variant_kind="$3"
  local n="$4"
  local manifest="${RAW_DIR}/bench-${variant_label}-${n}.yaml"
  local policy_manifest="${RAW_DIR}/bench-${variant_label}-${n}-policy.yaml"

  render_bench_manifest "${n}" "${manifest}"
  scp_to "${manifest}" "${ip}" "/tmp/bench-manifest.yaml"
  ssh_run "${ip}" "kubectl delete ns bench --ignore-not-found=true --wait=true || true"
  ssh_run "${ip}" "kubectl apply -f /tmp/bench-manifest.yaml"
  ssh_run "${ip}" "kubectl rollout status -n bench deploy --timeout=240s"

  if [[ "${variant_kind}" == "waf" ]]; then
    cat > "${RAW_DIR}/bench-refgrant.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: coraza-ext-proc-from-bench
  namespace: gateway-system
spec:
  from:
  - group: gateway.envoyproxy.io
    kind: EnvoyExtensionPolicy
    namespace: bench
  to:
  - group: ""
    kind: Service
    name: coraza-ext-proc-block
EOF
    scp_to "${RAW_DIR}/bench-refgrant.yaml" "${ip}" "/tmp/bench-refgrant.yaml"
    ssh_run "${ip}" "kubectl apply -f /tmp/bench-refgrant.yaml"

    render_waf_policy "${n}" "${policy_manifest}"
    scp_to "${policy_manifest}" "${ip}" "/tmp/bench-waf.yaml"
    ssh_run "${ip}" "kubectl apply -f /tmp/bench-waf.yaml && kubectl -n bench get envoyextensionpolicy bench-waf -o yaml >/tmp/bench-waf-status.yaml"
  elif [[ "${variant_kind}" == "wasm" ]]; then
    render_wasm_policy "${n}" "${policy_manifest}"
    scp_to "${policy_manifest}" "${ip}" "/tmp/bench-wasm.yaml"
    ssh_run "${ip}" "kubectl apply -f /tmp/bench-wasm.yaml && kubectl -n bench get envoyextensionpolicy bench-wasm -o yaml >/tmp/bench-wasm-status.yaml"
  fi
}

prepare_scenario_on_sut_parallel() {
  local scenario="$1"
  local waf_log="${LOG_DIR}/prepare-waf-s${scenario}.log"
  local alt_log="${LOG_DIR}/prepare-${ALT_VARIANT_NAME}-s${scenario}.log"
  local waf_pid alt_pid

  (
    prepare_scenario_on_sut "${SUT_WAF_IP}" "waf" "waf" "${scenario}"
  ) > "${waf_log}" 2>&1 &
  waf_pid=$!

  (
    prepare_scenario_on_sut "${SUT_GOFILTER_IP}" "${ALT_VARIANT_NAME}" "${ALT_VARIANT_KIND}" "${scenario}"
  ) > "${alt_log}" 2>&1 &
  alt_pid=$!

  wait_for_background_job "${waf_pid}" "${waf_log}" "prepare scenario=${scenario} variant=waf"
  wait_for_background_job "${alt_pid}" "${alt_log}" "prepare scenario=${scenario} variant=${ALT_VARIANT_NAME}"
}

check_policy_ready_on_sut() {
  local ip="$1"
  local variant_kind="$2"

  if [[ "${variant_kind}" == "waf" ]]; then
    ssh_run "${ip}" "kubectl -n bench wait --for=jsonpath='{.status.ancestors[0].conditions[?(@.type==\"Accepted\")].status}'=True envoyextensionpolicy/bench-waf --timeout=180s"
  elif [[ "${variant_kind}" == "go-filter" ]]; then
    ssh_run "${ip}" "kubectl -n gateway-system wait --for=jsonpath='{.status.ancestors[0].conditions[?(@.type==\"Accepted\")].status}'=True envoypatchpolicy/bench-go-filter --timeout=180s"
    ssh_run "${ip}" "kubectl -n gateway-system wait --for=jsonpath='{.status.ancestors[0].conditions[?(@.type==\"Programmed\")].status}'=True envoypatchpolicy/bench-go-filter --timeout=180s"
  elif [[ "${variant_kind}" == "wasm" ]]; then
    ssh_run "${ip}" "kubectl -n bench wait --for=jsonpath='{.status.ancestors[0].conditions[?(@.type==\"Accepted\")].status}'=True envoyextensionpolicy/bench-wasm --timeout=180s"
  else
    die "unsupported variant kind for policy readiness: ${variant_kind}"
  fi
}

enforcement_probe() {
  local ip="$1"
  local variant_label="$2"
  local variant_kind="$3"
  local host="$4"
  local benign attack

  check_policy_ready_on_sut "${ip}" "${variant_kind}"

  benign="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://${ip}/" || true)"
  attack="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://${ip}/?q=%3Cscript%3Ealert(1)%3C/script%3E" || true)"

  [[ "${benign}" == "200" ]] || die "enforcement gate failed on ${variant_label} (${ip}): benign expected 200, got ${benign}"
  [[ "${attack}" == "403" ]] || die "enforcement gate failed on ${variant_label} (${ip}): attack expected 403, got ${attack}"
}

enforcement_gate_for_scenario() {
  local scenario="$1"
  local host="podinfo-1.klawu.com"
  local waf_log="${LOG_DIR}/gate-waf-s${scenario}.log"
  local alt_log="${LOG_DIR}/gate-${ALT_VARIANT_NAME}-s${scenario}.log"
  local waf_pid alt_pid
  if (( scenario > 0 )); then
    host="podinfo-1.klawu.com"
  fi
  log "enforcement gate scenario=${scenario}: require 200 benign + 403 attack on both variants"
  (
    enforcement_probe "${SUT_WAF_IP}" "waf" "waf" "${host}"
  ) > "${waf_log}" 2>&1 &
  waf_pid=$!
  (
    enforcement_probe "${SUT_GOFILTER_IP}" "${ALT_VARIANT_NAME}" "${ALT_VARIANT_KIND}" "${host}"
  ) > "${alt_log}" 2>&1 &
  alt_pid=$!

  wait_for_background_job "${waf_pid}" "${waf_log}" "enforcement gate scenario=${scenario} variant=waf"
  wait_for_background_job "${alt_pid}" "${alt_log}" "enforcement gate scenario=${scenario} variant=${ALT_VARIANT_NAME}"
}

create_sampler_script() {
cat > "${SAMPLER_SCRIPT_LOCAL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
OUT="${1:?out required}"
SECONDS_TOTAL="${2:?seconds required}"
WAF_SELECTOR="${3:-app=coraza-ext-proc-block}"
ENVOY_SELECTOR="${4:-app.kubernetes.io/name=envoy}"
START="$(date +%s)"
while true; do
  NOW="$(date +%s)"
  if (( NOW - START >= SECONDS_TOTAL )); then
    break
  fi
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ts=${TS}" >> "${OUT}"
  kubectl top pod -n gateway-system -l "${WAF_SELECTOR}" --no-headers 2>/dev/null | awk '{print "kind=waf,pod="$1",cpu="$2",mem="$3}' >> "${OUT}" || true
  kubectl top pod -n gateway-system -l "${ENVOY_SELECTOR}" --no-headers 2>/dev/null | awk '{print "kind=envoy,pod="$1",cpu="$2",mem="$3}' >> "${OUT}" || true
  sleep 5
done
EOF
}

stage_sampler_script() {
  local ip="$1"
  local remote_sampler="/tmp/bench-sampler.sh"
  scp_to "${SAMPLER_SCRIPT_LOCAL}" "${ip}" "${remote_sampler}"
  ssh_run "${ip}" "chmod +x ${remote_sampler}"
}

start_sampler() {
  local ip="$1"
  local variant_label="$2"
  local variant_kind="$3"
  local scenario="$4"
  local repeat="$5"
  local remote_sampler="/tmp/bench-sampler.sh"
  local remote_out="/tmp/bench-sampler-${variant_label}-${scenario}-${repeat}.log"

  local selector
  if [[ "${variant_kind}" == "waf" ]]; then
    selector="app=coraza-ext-proc-block"
  else
    selector="${BENCH_ALT_RESOURCE_SELECTOR:-app.kubernetes.io/name=envoy}"
  fi

  local total_seconds
  total_seconds=$(( BENCH_WARMUP + ${BENCH_DURATION%s} + BENCH_COOLDOWN + 15 ))
  ssh_run "${ip}" "nohup ${remote_sampler} ${remote_out} ${total_seconds} '${selector}' 'app.kubernetes.io/name=envoy' >/tmp/bench-sampler-nohup.log 2>&1 & echo \$!" > "${SAMPLER_DIR}/${variant_label}-${scenario}-${repeat}.pid"
}

wait_for_background_job() {
  local pid="$1"
  local log_file="$2"
  local description="$3"

  if wait "${pid}"; then
    return 0
  fi

  if [[ -f "${log_file}" ]]; then
    sed -n '1,200p' "${log_file}" >&2
  fi
  die "${description} failed"
}

stop_sampler_and_fetch() {
  local ip="$1"
  local variant="$2"
  local scenario="$3"
  local repeat="$4"
  local remote_out="/tmp/bench-sampler-${variant}-${scenario}-${repeat}.log"
  local local_out="${SAMPLER_DIR}/${variant}-${scenario}-${repeat}.log"

  ssh_run "${ip}" "test -f ${remote_out} && tail -n +1 ${remote_out} || true" > "${local_out}" || true
}

extract_sampler_avg() {
  local file="$1"
  local pod_match="$2"
  awk -F'[=,]' -v pat="${pod_match}" '
    /pod=/ {
      pod=$4; cpu=$6; mem=$8;
      if (pod ~ pat) {
        gsub(/m/,"",cpu);
        gsub(/Mi/,"",mem);
        if (cpu ~ /^[0-9.]+$/) { cpu_sum+=cpu; cpu_n++; }
        if (mem ~ /^[0-9.]+$/) { mem_sum+=mem; mem_n++; }
      }
    }
    END {
      cpu_avg=(cpu_n>0)?cpu_sum/cpu_n:0;
      mem_avg=(mem_n>0)?mem_sum/mem_n:0;
      printf "%.2f,%.2f\n", cpu_avg, mem_avg;
    }
  ' "${file}"
}

run_k6_once() {
  local target_ip="$1"
  local hosts_csv="$2"
  local scenario="$3"
  local variant="$4"
  local repeat="$5"
  local local_summary="${RAW_DIR}/k6-${variant}-s${scenario}-r${repeat}.json"
  local local_log="${RAW_DIR}/k6-${variant}-s${scenario}-r${repeat}.log"

  if [[ "${BENCH_DRIVER_IP}" == "local" ]]; then
    k6 run "${K6_REMOTE_SCRIPT}" --summary-export "${K6_REMOTE_SUMMARY}" --vus "${BENCH_VUS}" --duration "${BENCH_DURATION}" \
      -e TARGET_IP="${target_ip}" -e HOSTS_CSV="${hosts_csv}" -e SCHEME=http \
      -e ATTACK_RATE="${BENCH_ATTACK_RATE}" -e INFO_RATE="${BENCH_INFO_RATE}" > "${K6_REMOTE_OUT}" 2>&1
    cat "${K6_REMOTE_SUMMARY}" > "${local_summary}"
    cat "${K6_REMOTE_OUT}" > "${local_log}"
  else
    ssh_run "${BENCH_DRIVER_IP}" "k6 run ${K6_REMOTE_SCRIPT} --summary-export ${K6_REMOTE_SUMMARY} --vus ${BENCH_VUS} --duration ${BENCH_DURATION} -e TARGET_IP=${target_ip} -e HOSTS_CSV='${hosts_csv}' -e SCHEME=http -e ATTACK_RATE=${BENCH_ATTACK_RATE} -e INFO_RATE=${BENCH_INFO_RATE} > ${K6_REMOTE_OUT} 2>&1"
    ssh_run "${BENCH_DRIVER_IP}" "cat ${K6_REMOTE_SUMMARY}" > "${local_summary}"
    ssh_run "${BENCH_DRIVER_IP}" "cat ${K6_REMOTE_OUT}" > "${local_log}"
  fi
}

csv_header() {
  cat > "${RESULTS_CSV}" <<'EOF'
variant,scenario,repeat,rps,p95_ms,p99_ms,fail_rate,status2xx,status4xx,status5xx,status403,waf_cpu_m,waf_mem_mi,envoy_cpu_m,envoy_mem_mi
EOF
}

append_result() {
  local variant="$1"
  local scenario="$2"
  local repeat="$3"
  local variant_kind="$4"
  local summary="${RAW_DIR}/k6-${variant}-s${scenario}-r${repeat}.json"
  local sampler="${SAMPLER_DIR}/${variant}-${scenario}-${repeat}.log"

  local rps p95 p99 fail s2 s4 s5 s403
  rps="$(jq -r '.metrics.http_reqs.values.rate // .metrics.http_reqs.rate // 0' "${summary}")"
  p95="$(jq -r '.metrics.http_req_duration.values["p(95)"] // .metrics.http_req_duration["p(95)"] // 0' "${summary}")"
  p99="$(jq -r '.metrics.http_req_duration.values["p(99)"] // .metrics.http_req_duration["p(99)"] // 0' "${summary}")"
  fail="$(jq -r '.metrics.http_req_failed.values.value // .metrics.http_req_failed.value // 0' "${summary}")"
  s2="$(jq -r '.metrics.status_2xx.values.count // .metrics.status_2xx.count // 0' "${summary}")"
  s4="$(jq -r '.metrics.status_4xx.values.count // .metrics.status_4xx.count // 0' "${summary}")"
  s5="$(jq -r '.metrics.status_5xx.values.count // .metrics.status_5xx.count // 0' "${summary}")"
  s403="$(jq -r '.metrics.status_403.values.count // .metrics.status_403.count // 0' "${summary}")"

  local waf_cpu_mem envoy_cpu_mem waf_cpu waf_mem envoy_cpu envoy_mem waf_pod_pattern
  if [[ "${variant_kind}" == "go-filter" || "${variant_kind}" == "wasm" ]]; then
    waf_pod_pattern="shared-gateway|envoy"
  else
    waf_pod_pattern="coraza-ext-proc-block|coraza-go-filter|waf"
  fi
  waf_cpu_mem="$(extract_sampler_avg "${sampler}" "${waf_pod_pattern}")"
  envoy_cpu_mem="$(extract_sampler_avg "${sampler}" "shared-gateway|envoy")"
  waf_cpu="${waf_cpu_mem%,*}"; waf_mem="${waf_cpu_mem#*,}"
  envoy_cpu="${envoy_cpu_mem%,*}"; envoy_mem="${envoy_cpu_mem#*,}"

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${variant}" "${scenario}" "${repeat}" "${rps}" "${p95}" "${p99}" "${fail}" "${s2}" "${s4}" "${s5}" "${s403}" \
    "${waf_cpu}" "${waf_mem}" "${envoy_cpu}" "${envoy_mem}" >> "${RESULTS_CSV}"
}

build_hosts_csv() {
  local n="$1"
  local out=""
  local i
  for i in $(seq 1 "${n}"); do
    if [[ -n "${out}" ]]; then out="${out},"; fi
    out="${out}podinfo-${i}.klawu.com"
  done
  printf "%s\n" "${out}"
}

summarize_markdown() {
  local out="${ARTIFACT_ROOT}/summary.md"
  {
    echo "# Coraza A/B Benchmark Summary"
    echo
    echo "- run_id: \`${BENCH_RUN_ID}\`"
    echo "- bench_mode: \`${BENCH_MODE}\`"
    echo "- k3s-learn ref: \`${K3S_LEARN_REF}\`"
    echo "- region/size: \`${DO_REGION}\` / \`${DO_SIZE}\`"
    echo "- repeats per scenario: \`${BENCH_REPEATS}\`"
    echo "- VUS/duration: \`${BENCH_VUS}\` / \`${BENCH_DURATION}\`"
    echo
    echo "## Median by Scenario"
    echo
    echo "| scenario | variant | rps_median | p95_ms_median | p99_ms_median | fail_rate_median | status403_median | waf_cpu_m_avg | waf_mem_mi_avg | envoy_cpu_m_avg | envoy_mem_mi_avg |"
    echo "|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|"
    awk -F',' '
      NR==1{next}
      {
        key=$2 FS $1;
        rps[key]=rps[key] " " $4;
        p95[key]=p95[key] " " $5;
        p99[key]=p99[key] " " $6;
        fail[key]=fail[key] " " $7;
        s403[key]=s403[key] " " $11;
        wcpu[key]=wcpu[key] " " $12;
        wmem[key]=wmem[key] " " $13;
        ecpu[key]=ecpu[key] " " $14;
        emem[key]=emem[key] " " $15;
      }
      function median(str,   n,a,i,j,t){
        n=split(str,a," ");
        j=0;
        for(i=1;i<=n;i++){ if(a[i]!=""){ j++; b[j]=a[i]+0; } }
        n=j;
        if(n==0){ return 0; }
        for(i=1;i<=n;i++){ for(j=i+1;j<=n;j++){ if(b[i]>b[j]){ t=b[i]; b[i]=b[j]; b[j]=t; } } }
        if(n%2==1){ return b[(n+1)/2]; }
        return (b[n/2]+b[n/2+1])/2;
      }
      END{
        for(k in rps){
          split(k, parts, FS);
          scenario=parts[1]; variant=parts[2];
          printf "| %s | %s | %.2f | %.2f | %.2f | %.5f | %.2f | %.2f | %.2f | %.2f | %.2f |\n",
            scenario, variant,
            median(rps[k]), median(p95[k]), median(p99[k]), median(fail[k]),
            median(s403[k]),
            median(wcpu[k]), median(wmem[k]), median(ecpu[k]), median(emem[k]);
        }
      }
    ' "${RESULTS_CSV}" | sort -t'|' -k2,2n -k3,3
    echo
    echo "## Raw Results"
    echo
    echo '```csv'
    cat "${RESULTS_CSV}"
    echo '```'
    echo
    echo "## Variant Delta Notes"
    echo
    echo '```text'
    cat "${RAW_DIR}/gofilter-parity-delta.txt" 2>/dev/null || true
    echo '```'
  } > "${out}"
}

csv_header
create_sampler_script
stage_sampler_script "${SUT_WAF_IP}"
stage_sampler_script "${SUT_GOFILTER_IP}"

# Bring parity delta note from bootstrap output.
if [[ -f "${RAW_DIR}/gofilter-parity-delta.txt" ]]; then
  :
elif [[ -f "${RAW_DIR}/../raw/gofilter-parity-delta.txt" ]]; then
  cp "${RAW_DIR}/../raw/gofilter-parity-delta.txt" "${RAW_DIR}/gofilter-parity-delta.txt"
fi

for scenario in ${BENCH_SCENARIOS}; do
  log "prepare scenario=${scenario} on both variants"
  prepare_scenario_on_sut_parallel "${scenario}"
  enforcement_gate_for_scenario "${scenario}"

  hosts_csv="$(build_hosts_csv "${scenario}")"
  for repeat in $(seq 1 "${BENCH_REPEATS}"); do
    log "run variant=waf scenario=${scenario} repeat=${repeat}"
    start_sampler "${SUT_WAF_IP}" "waf" "waf" "${scenario}" "${repeat}"
    sleep "${BENCH_WARMUP}"
    run_k6_once "${SUT_WAF_IP}" "${hosts_csv}" "${scenario}" "waf" "${repeat}"
    sleep "${BENCH_COOLDOWN}"
    stop_sampler_and_fetch "${SUT_WAF_IP}" "waf" "${scenario}" "${repeat}"
    append_result "waf" "${scenario}" "${repeat}" "waf"

    log "run variant=${ALT_VARIANT_NAME} scenario=${scenario} repeat=${repeat}"
    start_sampler "${SUT_GOFILTER_IP}" "${ALT_VARIANT_NAME}" "${ALT_VARIANT_KIND}" "${scenario}" "${repeat}"
    sleep "${BENCH_WARMUP}"
    run_k6_once "${SUT_GOFILTER_IP}" "${hosts_csv}" "${scenario}" "${ALT_VARIANT_NAME}" "${repeat}"
    sleep "${BENCH_COOLDOWN}"
    stop_sampler_and_fetch "${SUT_GOFILTER_IP}" "${ALT_VARIANT_NAME}" "${scenario}" "${repeat}"
    append_result "${ALT_VARIANT_NAME}" "${scenario}" "${repeat}" "${ALT_VARIANT_KIND}"
  done
done

summarize_markdown
log "benchmark completed: ${ARTIFACT_ROOT}/summary.md"
log "next: scripts/bench/do_destroy.sh"
