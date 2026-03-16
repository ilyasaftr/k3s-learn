# coraza-envoy-ext-authz

Envoy gRPC external authorization service (`envoy.service.auth.v3.Authorization/Check`) backed by Coraza + OWASP CRS.

This service is designed to be attached from Envoy Gateway `SecurityPolicy.extAuth.grpc`.

## Features

- Coraza + CRS request inspection in an external process (no Proxy-WASM runtime).
- Mode switch via `context_extensions`:
  - `mode=detect` -> allow request, log interruption.
  - `mode=block` -> deny interrupted request with `403`.
- Fail-closed service behavior for internal processing errors (`500` deny response).
- Prometheus metrics endpoint (`/metrics`) and health endpoint (`/healthz`).

## Decision Model

Input:
- gRPC `CheckRequest` from Envoy ext_authz.
- `context_extensions.mode` from Envoy Gateway `SecurityPolicy`.

Output:
- Allow: gRPC `codes.OK` + `OkHttpResponse`.
- Blocked request: gRPC `codes.PermissionDenied` + HTTP `403`.
- Internal error: gRPC `codes.PermissionDenied` + HTTP `500`.

Deny response headers:
- `x-coraza-mode`
- `x-coraza-rule-id`

Default mode is `detect` if mode is missing or unknown.

## Configuration

Environment variables:

| Name | Default | Description |
| --- | --- | --- |
| `GRPC_BIND` | `:9002` | gRPC bind address for ext_authz `Check`. |
| `METRICS_BIND` | `:9090` | HTTP bind address for `/healthz` and `/metrics`. |
| `LOG_LEVEL` | `INFO` | `debug`, `info`, `warn`, `error`. |
| `WAF_REQUEST_BODY_LIMIT_BYTES` | `1048576` | Coraza request body limit (bytes). Invalid/non-positive values fallback to default. |

Coraza directives baseline:

```text
Include @coraza.conf-recommended
Include @crs-setup.conf.example
SecRuleEngine On
Include @owasp_crs/*.conf
```

## Run Locally

```bash
go run ./cmd/coraza-ext-auth
```

Check endpoints:

```bash
curl -i http://127.0.0.1:9090/healthz
curl -s http://127.0.0.1:9090/metrics | head
```

Build binary:

```bash
go build ./cmd/coraza-ext-auth
```

## Docker

Build image:

```bash
docker buildx build --platform linux/amd64 \
  -t ghcr.io/<your-org>/coraza-envoy-ext-authz:v0.1.0 \
  --push .
```

Resolve and pin digest:

```bash
docker buildx imagetools inspect ghcr.io/<your-org>/coraza-envoy-ext-authz:v0.1.0
```

Use digest form in manifests:

```text
ghcr.io/<your-org>/coraza-envoy-ext-authz@sha256:<digest>
```

## Envoy Gateway Integration Example

Global detect mode on a `Gateway`:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: coraza-global
  namespace: gateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: shared-gateway
  extAuth:
    failOpen: false
    timeout: 200ms
    contextExtensions:
      mode: detect
    bodyToExtAuth:
      maxRequestBytes: 1048576
      allowPartialMessage: false
    grpc:
      backendRefs:
        - name: coraza-ext-auth
          namespace: gateway-system
          port: 9002
```

Route-level blocking override (for one app only):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: coraza-podinfo-block
  namespace: demo
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: podinfo
  extAuth:
    failOpen: false
    timeout: 200ms
    contextExtensions:
      mode: block
    bodyToExtAuth:
      maxRequestBytes: 1048576
      allowPartialMessage: false
    grpc:
      backendRefs:
        - name: coraza-ext-auth
          namespace: gateway-system
          port: 9002
```

If `SecurityPolicy` and auth service are in different namespaces, add a `ReferenceGrant` in the service namespace.

## Metrics

Prometheus metrics exposed on `/metrics`:

- `coraza_ext_auth_requests_total{mode,decision}`
- `coraza_ext_auth_interruptions_total{mode}`
- `coraza_ext_auth_failures_total`

## Logs

Structured log fields include:

- `request_id`
- `host`
- `path`
- `mode`
- `rule_id`
- `decision`

## Development

```bash
go test ./...
go build ./...
```

## Project Layout

```text
cmd/coraza-ext-auth/main.go      # process bootstrap
internal/config                  # env parsing/defaults
internal/server                  # grpc/http server lifecycle
internal/authz                   # request parse + response mapping
internal/waf                     # coraza evaluator
internal/metrics                 # prometheus recorder
internal/model                   # internal contracts/interfaces
```

## Limitations

- This model is request-time authorization (`ext_authz`), not response-phase WAF inspection.
- Body inspection is bounded by Envoy `bodyToExtAuth.maxRequestBytes`.
- If Envoy policy uses `failOpen=true`, traffic may bypass auth when auth service is unavailable.
