KUBECTL ?= kubectl
HELM ?= helm
APP ?= podinfo
OTEL_PROFILE ?= single-node-prod-small
OTEL_ENABLE_LOGS_TRACES ?= false
CORAZA_EXT_AUTH_IMAGE ?=

APP_DIR := manifests/apps/$(APP)
OTEL_PROFILE_DIR := manifests/global/otel-stack/profiles/$(OTEL_PROFILE)

.PHONY: apply-issuer-example install-envoy-gateway install-optional-tailscale-operator install-otel-stack apply-global apply-app apply-all apply-optional-tailscale-grafana verify-global verify-tls verify-otel-stack verify-app verify-all verify-optional-tailscale-grafana clean-app clean-global clean-otel-stack clean-optional-tailscale-grafana clean-all check-app

apply-issuer-example:
	$(KUBECTL) apply -f manifests/global/00-clusterissuer-cloudflare.example.yaml

install-envoy-gateway:
	$(HELM) upgrade -i envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
		--namespace gateway-system --create-namespace \
		--version v1.7.1 \
		-f manifests/global/envoy-gateway-values.yaml

install-optional-tailscale-operator:
	@test -n "$$TS_OAUTH_CLIENT_ID" || (echo "TS_OAUTH_CLIENT_ID is required" && exit 1)
	@test -n "$$TS_OAUTH_CLIENT_SECRET" || (echo "TS_OAUTH_CLIENT_SECRET is required" && exit 1)
	$(HELM) repo add tailscale https://pkgs.tailscale.com/helmcharts
	$(HELM) repo update
	$(HELM) upgrade --install tailscale-operator tailscale/tailscale-operator \
		--namespace tailscale --create-namespace \
		--set-string oauth.clientId="$$TS_OAUTH_CLIENT_ID" \
		--set-string oauth.clientSecret="$$TS_OAUTH_CLIENT_SECRET" \
		--wait

install-otel-stack:
	@test -d $(OTEL_PROFILE_DIR) || (echo "Unknown OTEL_PROFILE=$(OTEL_PROFILE). Available: single-node-prod-small" && exit 1)
	$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts
	$(HELM) repo add grafana https://grafana.github.io/helm-charts
	@if [ "$(OTEL_ENABLE_LOGS_TRACES)" = "true" ]; then $(HELM) repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts; fi
	@if [ "$(OTEL_ENABLE_LOGS_TRACES)" = "true" ]; then $(HELM) repo add grafana-community https://grafana-community.github.io/helm-charts; fi
	$(HELM) repo update
	$(HELM) upgrade -i kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace observability --create-namespace \
		--version 82.10.3 \
		-f manifests/global/otel-stack/kube-prometheus-stack-values.yaml \
		-f $(OTEL_PROFILE_DIR)/kube-prometheus-stack-values.yaml
	-$(HELM) uninstall otel-collector-metrics -n observability
	@if [ "$(OTEL_ENABLE_LOGS_TRACES)" = "true" ]; then \
		$(HELM) upgrade -i loki grafana/loki \
			--namespace observability \
			--version 6.55.0 \
			-f manifests/global/otel-stack/loki-values.yaml \
			-f $(OTEL_PROFILE_DIR)/loki-values.yaml; \
		$(HELM) upgrade -i tempo grafana-community/tempo \
			--namespace observability \
			--version 2.0.0 \
			-f manifests/global/otel-stack/tempo-values.yaml \
			-f $(OTEL_PROFILE_DIR)/tempo-values.yaml; \
		$(HELM) upgrade -i otel-collector-logs open-telemetry/opentelemetry-collector \
			--namespace observability \
			--version 0.147.0 \
			--reset-values \
			-f manifests/global/otel-stack/otel-collector-logs-values.yaml \
			-f $(OTEL_PROFILE_DIR)/otel-collector-logs-values.yaml; \
		$(HELM) upgrade -i otel-collector-traces open-telemetry/opentelemetry-collector \
			--namespace observability \
			--version 0.147.0 \
			--reset-values \
			-f manifests/global/otel-stack/otel-collector-traces-values.yaml \
			-f $(OTEL_PROFILE_DIR)/otel-collector-traces-values.yaml; \
	else \
		$(HELM) uninstall otel-collector-traces -n observability || true; \
		$(HELM) uninstall otel-collector-logs -n observability || true; \
		$(HELM) uninstall tempo -n observability || true; \
		$(HELM) uninstall loki -n observability || true; \
	fi

apply-global:
	$(KUBECTL) apply -f manifests/global/10-gateway.yaml
	$(KUBECTL) apply -f manifests/global/15-ratelimit.yaml
	@test -n "$(CORAZA_EXT_AUTH_IMAGE)" || (echo "CORAZA_EXT_AUTH_IMAGE is required (digest-pinned), e.g. ghcr.io/<org>/coraza-envoy-ext-authz@sha256:<digest>" && exit 1)
	@tmp=$$(mktemp); \
		sed "s#__CORAZA_EXT_AUTH_IMAGE__#$(CORAZA_EXT_AUTH_IMAGE)#g" manifests/global/16-waf-coraza.yaml > $$tmp; \
		$(KUBECTL) apply -f $$tmp; \
		rm -f $$tmp
	$(KUBECTL) apply -f manifests/global/20-observability.yaml
	$(KUBECTL) apply -f manifests/global/24-prometheus-monitors.yaml
	./scripts/grafana_dashboards.sh apply
	$(KUBECTL) apply -f manifests/global/30-alerts-global.yaml
	$(KUBECTL) apply -f manifests/global/40-networkpolicy-gateway.yaml

check-app:
	@test -d $(APP_DIR) || (echo "Unknown APP=$(APP). Available: podinfo, podinfo-2" && exit 1)

apply-app: check-app
	$(KUBECTL) apply -f $(APP_DIR)/app.yaml
	@if [ -f $(APP_DIR)/anubis.yaml ]; then $(KUBECTL) apply -f $(APP_DIR)/anubis.yaml; fi
	@if [ -f $(APP_DIR)/rate-limit.yaml ]; then $(KUBECTL) apply -f $(APP_DIR)/rate-limit.yaml; fi
	@if [ -f $(APP_DIR)/waf.yaml ]; then $(KUBECTL) apply -f $(APP_DIR)/waf.yaml; fi
	$(KUBECTL) apply -f $(APP_DIR)/observability.yaml
	$(KUBECTL) apply -f $(APP_DIR)/alerts.yaml

apply-optional-tailscale-grafana:
	$(KUBECTL) apply -f manifests/optional/tailscale/01-grafana-ingress.yaml

apply-all: apply-global
	$(MAKE) apply-app APP=podinfo
	$(MAKE) apply-app APP=podinfo-2

verify-global:
	$(KUBECTL) get gatewayclass envoy
	$(KUBECTL) get gateway -n gateway-system
	$(KUBECTL) wait -n gateway-system --for=condition=Programmed gateway/shared-gateway --timeout=180s
	$(KUBECTL) wait -n gateway-system --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True gateway/shared-gateway --timeout=180s
	$(KUBECTL) get securitypolicy coraza-waf -n gateway-system
	$(KUBECTL) wait -n gateway-system --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True securitypolicy/coraza-waf --timeout=180s
	$(KUBECTL) get referencegrant coraza-ext-auth-from-demo -n gateway-system
	$(KUBECTL) rollout status -n gateway-system deploy/coraza-ext-auth --timeout=180s
	$(KUBECTL) get deploy,svc -n gateway-system | grep -E 'envoy-gateway|redis|shared-gateway|coraza-ext-auth'
	$(KUBECTL) get prometheusrule -n observability
	$(KUBECTL) get networkpolicy -n gateway-system
	$(KUBECTL) get gateway shared-gateway -n gateway-system -o jsonpath='{.status.conditions[?(@.type=="Accepted")].message}' | grep -vi "unresolved backend reference"

verify-tls:
	$(KUBECTL) wait -n gateway-system --for=condition=Ready certificate/klawu-wildcard-cert --timeout=600s
	$(KUBECTL) get certificate klawu-wildcard-cert -n gateway-system
	$(KUBECTL) get secret klawu-tls -n gateway-system
	$(KUBECTL) describe gateway shared-gateway -n gateway-system

verify-otel-stack:
	$(HELM) list -n observability
	$(KUBECTL) get pods -n observability
	@if [ "$(OTEL_ENABLE_LOGS_TRACES)" = "true" ]; then $(KUBECTL) get svc -n observability | grep -E 'loki|tempo|prometheus|grafana|otel-collector-(logs|traces)'; else $(KUBECTL) get svc -n observability | grep -E 'prometheus|grafana'; fi
	@if [ "$(OTEL_ENABLE_LOGS_TRACES)" = "true" ]; then $(KUBECTL) get deployment -n observability | grep -E 'otel-collector-(logs|traces)'; fi
	$(KUBECTL) get podmonitor -n observability | grep -E 'envoy-gateway-controller|envoy-gateway-proxy|demo-app-metrics|coraza-ext-auth'
	./scripts/grafana_dashboards.sh verify
	@if [ "$(OTEL_ENABLE_LOGS_TRACES)" = "true" ]; then $(KUBECTL) get configmap grafana-otel-datasources -n observability; fi

verify-app: check-app
	$(KUBECTL) get deployment,svc,httproute -n demo | grep $(APP)
	@if [ -f $(APP_DIR)/anubis.yaml ]; then $(KUBECTL) get deployment,svc -n demo | grep anubis-$(APP); fi
	@if [ -f $(APP_DIR)/rate-limit.yaml ]; then $(KUBECTL) get backendtrafficpolicy -n demo | grep $(APP); fi
	@if [ -f $(APP_DIR)/waf.yaml ]; then $(KUBECTL) get securitypolicy -n demo | grep $(APP); fi
	$(KUBECTL) get prometheusrule -n observability | grep $(APP)
	$(KUBECTL) get networkpolicy -n demo | grep $(APP)

verify-all: verify-otel-stack verify-global
	$(MAKE) verify-tls
	$(MAKE) verify-app APP=podinfo
	$(MAKE) verify-app APP=podinfo-2

verify-optional-tailscale-grafana:
	$(KUBECTL) get pods -n tailscale
	$(KUBECTL) get ingress grafana-tailscale -n observability
	$(KUBECTL) describe ingress grafana-tailscale -n observability
	$(KUBECTL) get endpointslice -n observability -l kubernetes.io/service-name=kube-prometheus-stack-grafana
	$(KUBECTL) describe endpointslice -n observability -l kubernetes.io/service-name=kube-prometheus-stack-grafana

clean-app: check-app
	-$(KUBECTL) delete -f $(APP_DIR)/alerts.yaml
	-$(KUBECTL) delete -f $(APP_DIR)/observability.yaml
	@if [ -f $(APP_DIR)/waf.yaml ]; then $(KUBECTL) delete -f $(APP_DIR)/waf.yaml; fi
	@if [ -f $(APP_DIR)/rate-limit.yaml ]; then $(KUBECTL) delete -f $(APP_DIR)/rate-limit.yaml; fi
	@if [ -f $(APP_DIR)/anubis.yaml ]; then $(KUBECTL) delete -f $(APP_DIR)/anubis.yaml; fi
	-$(KUBECTL) delete -f $(APP_DIR)/app.yaml

clean-global:
	-$(KUBECTL) delete -f manifests/global/40-networkpolicy-gateway.yaml
	-$(KUBECTL) delete -f manifests/global/30-alerts-global.yaml
	-$(KUBECTL) delete -f manifests/global/22-observability-logs-traces.yaml
	-./scripts/grafana_dashboards.sh delete
	-$(KUBECTL) delete -f manifests/global/24-prometheus-monitors.yaml
	-$(KUBECTL) delete -f manifests/global/20-observability.yaml
	-$(KUBECTL) delete -f manifests/global/16-waf-coraza.yaml
	-$(KUBECTL) delete -f manifests/global/15-ratelimit.yaml
	-$(KUBECTL) delete -f manifests/global/10-gateway.yaml

clean-otel-stack:
	-$(HELM) uninstall otel-collector-traces -n observability
	-$(HELM) uninstall otel-collector-logs -n observability
	-$(HELM) uninstall tempo -n observability
	-$(HELM) uninstall loki -n observability
	-$(HELM) uninstall kube-prometheus-stack -n observability

clean-optional-tailscale-grafana:
	-$(KUBECTL) delete -f manifests/optional/tailscale/01-grafana-ingress.yaml

clean-all:
	-$(MAKE) clean-app APP=podinfo-2
	-$(MAKE) clean-app APP=podinfo
	-$(MAKE) clean-global
	-$(MAKE) clean-optional-tailscale-grafana
	-$(MAKE) clean-otel-stack
