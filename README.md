# k3s-learn (kgateway + OTel Stack)

This repo now uses an OTel-first observability stack for kgateway.

Primary signals:

- Metrics: Prometheus (remote-write receiver)
- Logs: Loki
- Traces: Tempo
- Collection/Pipeline: OpenTelemetry Collector (metrics, logs, traces)
- Visualization: Grafana

App routing behavior is unchanged. `podinfo` and `podinfo-2` still run behind the shared kgateway Gateway API resources.

## Architecture

```text
Clients
  -> shared-gateway (kgateway / Envoy)
      -> podinfo / podinfo-2 (demo namespace)

Observability namespace
  - kube-prometheus-stack (Prometheus + Grafana)
  - Loki
  - Tempo
  - otel-collector-metrics
  - otel-collector-logs
  - otel-collector-traces

Telemetry flow
  - Gateway metrics + app /metrics -> otel-collector-metrics -> Prometheus remote write
  - Gateway access logs (OTLP) -> otel-collector-logs -> Loki
  - Gateway traces (OTLP) -> otel-collector-traces -> Tempo
```

## Repository Layout

```text
manifests/
  global/
    10-gateway.yaml
    20-observability.yaml
    21-otel-policies.yaml
    30-alerts-global.yaml
    40-networkpolicy-gateway.yaml
    otel-stack/
      kube-prometheus-stack-values.yaml
      loki-values.yaml
      tempo-values.yaml
      otel-collector-metrics-values.yaml
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
- kgateway installed with `GatewayClass` named `kgateway`
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

### 3) kgateway

```bash
export KGW_VERSION=v2.2.1

helm upgrade -i --create-namespace --namespace kgateway-system \
  --version ${KGW_VERSION} \
  kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds

helm upgrade -i -n kgateway-system \
  --version ${KGW_VERSION} \
  kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway

kubectl -n kgateway-system rollout status deploy/kgateway --timeout=180s
kubectl get gatewayclass kgateway
```

### 4) cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.0/cert-manager.yaml
kubectl wait --for=condition=Available -n cert-manager deploy/cert-manager --timeout=180s
kubectl wait --for=condition=Available -n cert-manager deploy/cert-manager-webhook --timeout=180s
kubectl wait --for=condition=Available -n cert-manager deploy/cert-manager-cainjector --timeout=180s
```

## Install OTel Stack

Install Prometheus/Grafana + Loki + Tempo + three OTel collectors.

The default profile is `single-node-prod-small`, which is the low-memory production profile for k3s:

```bash
make install-otel-stack
```

To install a different profile in the future:

```bash
make install-otel-stack OTEL_PROFILE=single-node-prod-small
```

This installs all observability components in namespace `observability`.

The `single-node-prod-small` profile currently does all of the following:

- keeps Prometheus, Grafana, Alertmanager, Loki, Tempo, and the three OTel collectors
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

### Verify TLS and apps

```bash
make verify-tls
make verify-app APP=podinfo
make verify-app APP=podinfo-2
```

### Verify telemetry with traffic

Generate traffic:

```bash
for i in {1..50}; do curl -sk --resolve podinfo.klawu.com:443:<LB_IP> https://podinfo.klawu.com/ >/dev/null; done
```

Then check:

```bash
kubectl get pods -n observability
kubectl logs -n observability deploy/otel-collector-logs --tail=50
kubectl logs -n observability deploy/otel-collector-traces --tail=50
kubectl logs -n observability deploy/otel-collector-metrics --tail=50
```

In Grafana, verify:

- Prometheus datasource has `kgateway-gateways`, `kgateway-control-plane`, and `demo-app-metrics` series
- Loki has gateway access logs
- Tempo shows gateway traces
- Open the vendored upstream dashboards: `Envoy` and `Kgateway Operations`
- These dashboards are checked into this repo from the kgateway docs so Grafana does not depend on the unstable docs-hosted `.../main/.../*.json` URLs at runtime
- Use `kgateway Log Overview` for OTLP gateway logs with the selector `{service_name="shared-gateway.kgateway-system"}`

## Important Behavior

- App-side OTel instrumentation is not required for v1.
- `podinfo` works with gateway-generated logs/traces immediately.
- App `/metrics` scraping is still retained (via OTel metrics collector), so app-level operational visibility remains.
- Tempo remains gateway-level tracing only in this profile.
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
kubectl get httplistenerpolicy -n kgateway-system
kubectl describe httplistenerpolicy shared-gateway-otel -n kgateway-system
kubectl get referencegrant -n observability
kubectl get svc -n observability | grep otel-collector
```

Expected collector Services for policy backend refs:

- `otel-collector-logs`
- `otel-collector-traces`

- No gateway traces:

```bash
kubectl logs -n observability deploy/otel-collector-traces --tail=200
kubectl get svc -n observability | grep tempo
```

- No gateway logs:

```bash
kubectl logs -n observability deploy/otel-collector-logs --tail=200
kubectl get svc -n observability | grep loki
helm upgrade -i otel-collector-logs open-telemetry/opentelemetry-collector -n observability \
  --version 0.147.0 --reset-values \
  -f manifests/global/otel-stack/otel-collector-logs-values.yaml \
  -f manifests/global/otel-stack/profiles/single-node-prod-small/otel-collector-logs-values.yaml
```

- No metrics for gateway/apps:

```bash
kubectl logs -n observability deploy/otel-collector-metrics --tail=200
kubectl get pods -n kgateway-system -l gateway.networking.k8s.io/gateway-name=shared-gateway
kubectl get pods -n demo -l app=podinfo
kubectl get pods -n demo -l app=podinfo-2
```

- TLS secret not found on first verify:

`make verify-tls` now waits up to 10 minutes for `Certificate/klawu-wildcard-cert` to become `Ready=True` because DNS-01 propagation is asynchronous. If it still times out, inspect challenges:

```bash
kubectl get order,challenge -A
kubectl describe certificate -n kgateway-system klawu-wildcard-cert
kubectl logs -n cert-manager deploy/cert-manager --tail=200
```
