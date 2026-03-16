# coraza-ext-auth

Envoy gRPC external authorization service (`service.auth.v3.Authorization/Check`) backed by Coraza + OWASP CRS.

## Behavior

- `mode=detect`: logs Coraza interruptions and allows requests.
- `mode=block`: denies interrupted requests with HTTP `403`.
- Body inspection depends on Envoy Gateway `SecurityPolicy.extAuth.bodyToExtAuth.maxRequestBytes`.

The `mode` value is read from Envoy `context_extensions` (configured via `SecurityPolicy.spec.extAuth.contextExtensions`).

## Build and Push

```bash
docker buildx build --platform linux/amd64 \
  -t ghcr.io/<your-org>/coraza-ext-auth:v0.1.0 \
  --push services/coraza-ext-auth

docker buildx imagetools inspect ghcr.io/<your-org>/coraza-ext-auth:v0.1.0
```

Use the resulting digest for `CORAZA_EXT_AUTH_IMAGE`.
