# k3s-learn (Envoy Gateway + Prometheus/Grafana)

This repo now uses Envoy Gateway as the shared public edge, with Prometheus and Grafana as the primary observability path.

Primary signals:

- Metrics: Prometheus
- Logs: Loki (optional)
- Traces: Tempo (optional)
- Collection/Pipeline: Prometheus direct scrape for metrics, OpenTelemetry Collector for optional logs/traces
- Visualization: Grafana

App routing stays on the shared Envoy Gateway resources, and `podinfo-2` is fronted by Anubis before requests reach the app service.

## Architecture

```text
Clients
  -> shared-gateway (Envoy Gateway / Envoy)
      -> podinfo (demo namespace)
      -> anubis-podinfo-2 -> podinfo-2 (demo namespace)
      -> Redis-backed route-scoped rate limit for podinfo (gateway-system)

Observability namespace
  - kube-prometheus-stack (Prometheus + Grafana)
  - Loki (optional)
  - Tempo (optional)
  - otel-collector-logs (optional)
  - otel-collector-traces (optional)

Telemetry flow
  - Envoy Gateway controller metrics -> Prometheus
  - Envoy proxy metrics -> Prometheus
  - App /metrics -> Prometheus
  - Gateway access logs and traces are intentionally not wired in v1 of the Envoy Gateway migration
```

## Repository Layout

```text
manifests/
  global/
    10-gateway.yaml
    15-ratelimit.yaml
    20-observability.yaml
    30-alerts-global.yaml
    40-networkpolicy-gateway.yaml
    otel-stack/
      kube-prometheus-stack-values.yaml
      loki-values.yaml
      tempo-values.yaml
      otel-collector-logs-values.yaml
      otel-collector-traces-values.yaml
  apps/
    podinfo/
    podinfo-2/
  optional/
    tailscale/

Makefile
```

## Prerequisites

- Kubernetes cluster (`k3s` is fine)
- Helm 3
- Gateway API CRDs
- Envoy Gateway installed with `GatewayClass` named `envoy`
- cert-manager installed

Current pinned chart versions in this repo (verified on 2026-03-13):

- `prometheus-community/kube-prometheus-stack` `82.10.3`
- `grafana/loki` `6.55.0`
- `grafana-community/tempo` `2.0.0` with `tempo.tag=2.10.2`
- `open-telemetry/opentelemetry-collector` `0.147.0`

Note: Tempo project is active. The old `grafana/tempo` chart path is deprecated; this repo uses the maintained `grafana-community/tempo` chart source.

Observability profiles:

- Default profile: `single-node-prod-small`
- Goal: durable single-node production for k3s with PVC-backed Prometheus, Loki, Tempo, and Alertmanager plus explicit memory budgets
- Future path: add a separate multi-node HA profile later instead of overloading the single-node defaults

Example k3s install:

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL=stable \
  INSTALL_K3S_EXEC="server --disable=traefik --write-kubeconfig-mode 644" \
  sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

## Install Platform Prerequisites

### 1) Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 2) Gateway API

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
kubectl get crd | grep gateway.networking.k8s.io
```

### 3) Envoy Gateway

```bash
make install-envoy-gateway

kubectl -n gateway-system rollout status deploy/envoy-gateway --timeout=180s
kubectl get gatewayclass envoy
```

The Envoy Gateway install uses [envoy-gateway-values.yaml](/Users/ilyasa/Developer/k3s-learn/manifests/global/envoy-gateway-values.yaml) to:

- give the Envoy Gateway control plane explicit memory requests and limits
- enable `GatewayNamespace` deployment mode so the `shared-gateway` proxy stays in `gateway-system`
- enable Redis-backed global rate limiting for Envoy Gateway

### 4) cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.0/cert-manager.yaml
kubectl wait --for=condition=Available -n cert-manager deploy/cert-manager --timeout=180s
kubectl wait --for=condition=Available -n cert-manager deploy/cert-manager-webhook --timeout=180s
kubectl wait --for=condition=Available -n cert-manager deploy/cert-manager-cainjector --timeout=180s
```

## Install Observability Stack

Install Prometheus/Grafana by default. Loki, Tempo, and the log/trace collectors are optional.

The default profile is `single-node-prod-small`, which is the low-memory production profile for k3s:

```bash
make install-otel-stack
```

This default installs:

- kube-prometheus-stack

To also install Loki, Tempo, and the log/trace collectors:

```bash
make install-otel-stack OTEL_ENABLE_LOGS_TRACES=true
```

To install a different profile in the future:

```bash
make install-otel-stack OTEL_PROFILE=single-node-prod-small
```

This installs the selected observability components in namespace `observability`.

The `single-node-prod-small` profile currently does all of the following when logs/traces are enabled:

- keeps Prometheus, Grafana, Alertmanager, Loki, Tempo, and the two optional OTel collectors
- enables PVC-backed storage for Prometheus, Loki, Tempo, and Alertmanager
- applies explicit memory requests and limits to the core monitoring pods
- reduces Prometheus retention to `72h` and Tempo retention to `24h`
- disables `kubeEtcd`, `kubeControllerManager`, `kubeScheduler`, and `kubeProxy` scraping to keep the namespace smaller on k3s

## Apply This Repo

```bash
make apply-global
make apply-app APP=podinfo
make apply-app APP=podinfo-2
```

`make apply-global` now installs the shared Envoy Gateway resources in `gateway-system`, the Redis backend that `podinfo` uses for route-scoped global rate limiting, direct Prometheus scrape monitors, and the vendored official Envoy Gateway Grafana dashboards.

`make apply-app APP=podinfo-2` now also deploys Anubis in `demo` and repoints the public `HTTPRoute` so `podinfo-2.klawu.com` is challenged before traffic reaches the original `podinfo-2` service. The original `podinfo-2` ClusterIP service remains available for in-cluster access and metrics scraping.

The initial Anubis rollout is conservative:

- all public paths on `podinfo-2.klawu.com` go through Anubis first
- there are no public bypasses for `/healthz` or `/metrics`
- the original `podinfo-2` service still handles in-cluster app traffic and Prometheus scraping

The current Envoy Gateway setup uses direct Prometheus scraping for metrics. Gateway OTLP access logs and tracing are still intentionally not configured in v1.

## Coraza WAF (Proxy-WASM)

This repo now applies a global Coraza WAF policy on `shared-gateway` using Envoy Gateway `EnvoyExtensionPolicy` with WASM:

- Scope: global on `shared-gateway` (covers `podinfo` and `podinfo-2`)
- Mode: `SecRuleEngine DetectionOnly` (non-blocking first rollout)
- Rules: `@recommended-conf` + baseline CRS (`@crs-setup-conf`, `@owasp_crs/*.conf`)
- Module source: pinned OCI digest (`ghcr.io/corazawaf/coraza-proxy-wasm@sha256:...`)

`podinfo` also has a route-specific override policy in [waf.yaml](/Users/ilyasa/Developer/k3s-learn/manifests/apps/podinfo/waf.yaml) with `SecRuleEngine On`, so blocking is enabled only for `podinfo` while `podinfo-2` remains under global detection mode.

The policy is defined in [16-waf-coraza.yaml](/Users/ilyasa/Developer/k3s-learn/manifests/global/16-waf-coraza.yaml).

Verify it is attached:

```bash
kubectl get envoyextensionpolicy coraza-waf -n gateway-system
kubectl get envoyextensionpolicy coraza-waf -n gateway-system -o yaml
```

Detection test examples (requests should still pass in DetectionOnly mode):

```bash
curl -sk --resolve podinfo.klawu.com:443:<LB_IP> \
  "https://podinfo.klawu.com/?q=<script>alert(1)</script>"

curl -sk --resolve podinfo-2.klawu.com:443:<LB_IP> \
  "https://podinfo-2.klawu.com/?id=1%27%20OR%20%271%27=%271"
```

For `podinfo` route-level blocking mode, malicious payloads should return a blocked response:

```bash
curl -sk -o /dev/null -w "%{http_code}\n" \
  --resolve podinfo.klawu.com:443:<LB_IP> \
  "https://podinfo.klawu.com/?q=<script>alert(1)</script>"
```

Rollback:

```bash
kubectl delete -f manifests/global/16-waf-coraza.yaml
```

If you use the wildcard cert flow:

```bash
make apply-issuer-example
```

## Verify

### Verify observability stack and policies

```bash
make verify-otel-stack
make verify-global
kubectl get pvc -n observability
```

`make verify-global` also checks that:

- Envoy Gateway is running in `gateway-system`
- `redis` is up in `gateway-system`
- `shared-gateway` is accepted and programmed

`make verify-otel-stack` now also checks that:

- direct `PodMonitor` resources exist for the Envoy Gateway controller, Envoy proxy, and demo app metrics
- vendored Grafana dashboard ConfigMaps are present in `observability`

### Verify TLS and apps

```bash
make verify-tls
make verify-app APP=podinfo
make verify-app APP=podinfo-2
```

`make verify-app APP=podinfo` now checks the route-scoped `BackendTrafficPolicy` too.

`make verify-app APP=podinfo-2` also checks the `anubis-podinfo-2` deployment and service.

To revert Anubis later, change the backend in [manifests/apps/podinfo-2/app.yaml](/Users/ilyasa/Developer/k3s-learn/manifests/apps/podinfo-2/app.yaml) back from `anubis-podinfo-2:8923` to `podinfo-2:9898`, then remove [manifests/apps/podinfo-2/anubis.yaml](/Users/ilyasa/Developer/k3s-learn/manifests/apps/podinfo-2/anubis.yaml) from the apply flow.

### Verify telemetry with traffic

Generate traffic:

```bash
for i in {1..50}; do curl -sk --resolve podinfo.klawu.com:443:<LB_IP> https://podinfo.klawu.com/ >/dev/null; done
```

To confirm global rate limiting for `podinfo`, run a short burst from one client IP and count the response codes:

```bash
for i in {1..50}; do
  curl -sk -o /dev/null -w "%{http_code}\n" \
    --resolve podinfo.klawu.com:443:<LB_IP> \
    https://podinfo.klawu.com/
done | sort | uniq -c
```

Expected behavior:

- some requests return `200`
- excess requests return `429`
- `podinfo-2` is unaffected because no global rate-limit policy is attached to its route

Then check:

```bash
kubectl get pods -n observability
kubectl get podmonitor -n observability
```

If logs/traces are enabled, also check:

```bash
kubectl logs -n observability deploy/otel-collector-logs --tail=50
kubectl logs -n observability deploy/otel-collector-traces --tail=50
```

Get the local Grafana admin password:

```bash
kubectl get secret -n observability kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

In Grafana, verify:

- Prometheus datasource has `envoy-gateway-controller`, `envoy-gateway-proxy`, and `demo-app-metrics` series
- the official dashboards are present:
  - `Envoy Gateway Global`
  - `Envoy Global`
  - `Envoy Clusters`
  - `Resources Monitor`
- the shared and per-app alerts evaluate against those metrics

## Important Behavior

- App-side OTel instrumentation is not required for v1.
- `podinfo` now uses Envoy Gateway global rate limiting with Redis-backed shared counters.
- The `podinfo` global limit is `10 requests/second` per client IP.
- The limit is shared across all `shared-gateway` replicas, so scaling the gateway does not double the effective `podinfo` quota.
- `podinfo-2` and other routes on `shared-gateway` are not rate-limited by this config.
- App `/metrics` scraping is retained through direct Prometheus scraping, so app-level operational visibility remains.
- Loki, Tempo, and the OTLP log/trace collectors are disabled by default in the repo flow, but can be re-enabled later with `OTEL_ENABLE_LOGS_TRACES=true`.
- `shared-gateway` now gets explicit Envoy resource requests and limits via `EnvoyProxy`.
- The Envoy Gateway control plane now gets explicit resource requests and limits via the Helm values file.
- The low-memory defaults are tuned for single-node durability, not HA.
- Multi-node readiness is handled by the profile layout; do not scale this profile into HA by only increasing replica counts.

## Optional: Tailscale Access for Grafana

Install operator:

```bash
export TS_OAUTH_CLIENT_ID="<your-operator-oauth-client-id>"
export TS_OAUTH_CLIENT_SECRET="<your-operator-oauth-client-secret>"
make install-optional-tailscale-operator
```

Apply Grafana ingress:

```bash
make apply-optional-tailscale-grafana
make verify-optional-tailscale-grafana
```

## Cleanup

```bash
make clean-all
```

Or remove observability stack only:

```bash
make clean-otel-stack
```

## Troubleshooting

- Gateway policy not attached:

```bash
kubectl get gatewayclass envoy
kubectl get gateway shared-gateway -n gateway-system
kubectl describe gateway shared-gateway -n gateway-system
kubectl get pods -n gateway-system
```

- No metrics for gateway/apps:

```bash
kubectl get podmonitor -n observability
kubectl get configmap -n observability | grep grafana-dashboard-
kubectl get pods -n gateway-system -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway
kubectl get pods -n demo -l app=podinfo
kubectl get pods -n demo -l app=podinfo-2
```

- TLS secret not found on first verify:

`make verify-tls` now waits up to 10 minutes for `Certificate/klawu-wildcard-cert` to become `Ready=True` because DNS-01 propagation is asynchronous. If it still times out, inspect challenges:

```bash
kubectl get order,challenge -A
kubectl describe certificate -n gateway-system klawu-wildcard-cert
kubectl logs -n cert-manager deploy/cert-manager --tail=200
```
