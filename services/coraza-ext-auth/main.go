package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	coreruleset "github.com/corazawaf/coraza-coreruleset/v4"
	"github.com/corazawaf/coraza/v3"
	corazatypes "github.com/corazawaf/coraza/v3/types"
	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
)

const (
	defaultGRPCBind = ":9002"
	defaultHTTPBind = ":9090"
	defaultBodySize = 1048576
)

const defaultDirectives = `
Include @coraza.conf-recommended
Include @crs-setup.conf.example
SecRuleEngine On
Include @owasp_crs/*.conf
`

type authServer struct {
	authv3.UnimplementedAuthorizationServer
	waf           coraza.WAF
	requests      *prometheus.CounterVec
	interruptions *prometheus.CounterVec
	failures      prometheus.Counter
}

func newAuthServer(bodyLimit int) (*authServer, error) {
	wafConfig := coraza.NewWAFConfig().
		WithRootFS(coreruleset.FS).
		WithRequestBodyAccess().
		WithRequestBodyLimit(bodyLimit).
		WithRequestBodyInMemoryLimit(bodyLimit).
		WithErrorCallback(func(mr corazatypes.MatchedRule) {
			// Coraza engine-level error callback (parsing/runtime warnings).
			slog.Warn("coraza error callback", "message", mr.ErrorLog())
		}).
		WithDirectives(strings.TrimSpace(defaultDirectives))

	waf, err := coraza.NewWAF(wafConfig)
	if err != nil {
		return nil, fmt.Errorf("init coraza waf: %w", err)
	}

	return &authServer{
		waf: waf,
		requests: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "coraza_ext_auth_requests_total",
				Help: "Total ext_authz requests by mode and decision.",
			},
			[]string{"mode", "decision"},
		),
		interruptions: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "coraza_ext_auth_interruptions_total",
				Help: "Total Coraza interruptions by mode.",
			},
			[]string{"mode"},
		),
		failures: prometheus.NewCounter(
			prometheus.CounterOpts{
				Name: "coraza_ext_auth_failures_total",
				Help: "Total ext_authz internal failures.",
			},
		),
	}, nil
}

func (s *authServer) Check(_ context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	attrs := req.GetAttributes()
	httpReq := attrs.GetRequest().GetHttp()
	mode := normalizeMode(attrs.GetContextExtensions())

	if httpReq == nil {
		s.requests.WithLabelValues(mode, "allow").Inc()
		return allowResponse(), nil
	}

	txID := httpReq.GetId()
	if txID == "" {
		txID = strconv.FormatInt(time.Now().UnixNano(), 10)
	}

	tx := s.waf.NewTransactionWithID(txID)
	defer func() {
		tx.ProcessLogging()
		_ = tx.Close()
	}()

	clientIP, clientPort := peerAddress(attrs.GetSource())
	serverIP, serverPort := peerAddress(attrs.GetDestination())
	tx.ProcessConnection(clientIP, clientPort, serverIP, serverPort)

	path, query := splitPathAndQuery(httpReq.GetPath())
	method := httpReq.GetMethod()
	if method == "" {
		method = http.MethodGet
	}
	proto := httpReq.GetProtocol()
	if proto == "" {
		proto = "HTTP/1.1"
	}
	tx.ProcessURI(path, method, proto)

	if host := httpReq.GetHost(); host != "" {
		tx.SetServerName(host)
		tx.AddRequestHeader("host", host)
	}
	addHeaders(tx, httpReq)
	addQueryArgs(tx, query)

	if interruption := tx.ProcessRequestHeaders(); interruption != nil {
		if response := s.handleInterruption(mode, httpReq, interruption); response != nil {
			return response, nil
		}
	}

	if body := requestBody(httpReq); len(body) > 0 {
		if interruption, _, err := tx.WriteRequestBody(body); err != nil {
			return s.internalError(mode, fmt.Errorf("write request body: %w", err)), nil
		} else if interruption != nil {
			if response := s.handleInterruption(mode, httpReq, interruption); response != nil {
				return response, nil
			}
		}
	}

	if interruption, err := tx.ProcessRequestBody(); err != nil {
		return s.internalError(mode, fmt.Errorf("process request body: %w", err)), nil
	} else if interruption != nil {
		if response := s.handleInterruption(mode, httpReq, interruption); response != nil {
			return response, nil
		}
	}

	s.requests.WithLabelValues(mode, "allow").Inc()
	return allowResponse(), nil
}

func (s *authServer) internalError(mode string, err error) *authv3.CheckResponse {
	s.failures.Inc()
	s.requests.WithLabelValues(mode, "error").Inc()
	slog.Error("ext_authz internal error", "mode", mode, "error", err)
	return denyResponse(typev3.StatusCode_InternalServerError, "internal authorization error", "0", mode)
}

func (s *authServer) handleInterruption(mode string, httpReq *authv3.AttributeContext_HttpRequest, interruption *corazatypes.Interruption) *authv3.CheckResponse {
	s.interruptions.WithLabelValues(mode).Inc()
	slog.Warn(
		"coraza interruption",
		"mode", mode,
		"rule_id", interruption.RuleID,
		"action", interruption.Action,
		"status", interruption.Status,
		"method", httpReq.GetMethod(),
		"path", httpReq.GetPath(),
		"host", httpReq.GetHost(),
	)

	if mode == "block" {
		s.requests.WithLabelValues(mode, "deny").Inc()
		return denyResponse(typev3.StatusCode_Forbidden, "blocked by coraza waf", strconv.Itoa(interruption.RuleID), mode)
	}

	s.requests.WithLabelValues(mode, "allow").Inc()
	return nil
}

func allowResponse() *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &status.Status{Code: int32(codes.OK)},
		HttpResponse: &authv3.CheckResponse_OkResponse{
			OkResponse: &authv3.OkHttpResponse{},
		},
	}
}

func denyResponse(httpCode typev3.StatusCode, body, ruleID, mode string) *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &status.Status{Code: int32(codes.PermissionDenied)},
		HttpResponse: &authv3.CheckResponse_DeniedResponse{
			DeniedResponse: &authv3.DeniedHttpResponse{
				Status: &typev3.HttpStatus{Code: httpCode},
				Body:   body,
				Headers: []*corev3.HeaderValueOption{
					{
						Header: &corev3.HeaderValue{
							Key:   "x-coraza-mode",
							Value: mode,
						},
					},
					{
						Header: &corev3.HeaderValue{
							Key:   "x-coraza-rule-id",
							Value: ruleID,
						},
					},
				},
			},
		},
	}
}

func normalizeMode(contextExtensions map[string]string) string {
	for key, value := range contextExtensions {
		if strings.EqualFold(key, "mode") {
			mode := strings.ToLower(strings.TrimSpace(value))
			if mode == "block" {
				return mode
			}
			break
		}
	}
	return "detect"
}

func peerAddress(peer *authv3.AttributeContext_Peer) (string, int) {
	if peer == nil || peer.GetAddress() == nil {
		return "", 0
	}
	socket := peer.GetAddress().GetSocketAddress()
	if socket == nil {
		return "", 0
	}

	port := 0
	switch value := socket.GetPortSpecifier().(type) {
	case *corev3.SocketAddress_PortValue:
		port = int(value.PortValue)
	}
	return socket.GetAddress(), port
}

func splitPathAndQuery(rawPath string) (string, string) {
	if rawPath == "" {
		return "/", ""
	}
	path := rawPath
	query := ""
	if idx := strings.Index(rawPath, "?"); idx >= 0 {
		path = rawPath[:idx]
		query = rawPath[idx+1:]
	}
	if path == "" {
		path = "/"
	}
	return path, query
}

func addQueryArgs(tx corazatypes.Transaction, rawQuery string) {
	if rawQuery == "" {
		return
	}
	queryValues, err := url.ParseQuery(rawQuery)
	if err != nil {
		slog.Warn("unable to parse query arguments", "error", err)
		return
	}
	for key, values := range queryValues {
		for _, value := range values {
			tx.AddGetRequestArgument(key, value)
		}
	}
}

func addHeaders(tx corazatypes.Transaction, httpReq *authv3.AttributeContext_HttpRequest) {
	for key, value := range httpReq.GetHeaders() {
		tx.AddRequestHeader(strings.ToLower(key), value)
	}
	if headerMap := httpReq.GetHeaderMap(); headerMap != nil {
		for _, header := range headerMap.GetHeaders() {
			value := header.GetValue()
			if value == "" && len(header.GetRawValue()) > 0 {
				value = string(header.GetRawValue())
			}
			tx.AddRequestHeader(strings.ToLower(header.GetKey()), value)
		}
	}
}

func requestBody(httpReq *authv3.AttributeContext_HttpRequest) []byte {
	if len(httpReq.GetRawBody()) > 0 {
		return httpReq.GetRawBody()
	}
	if httpReq.GetBody() == "" {
		return nil
	}
	return []byte(httpReq.GetBody())
}

func main() {
	grpcBind := envOrDefault("GRPC_BIND", defaultGRPCBind)
	metricsBind := envOrDefault("METRICS_BIND", defaultHTTPBind)
	logLevel := parseLevel(envOrDefault("LOG_LEVEL", "INFO"))
	bodyLimit := intEnvOrDefault("WAF_REQUEST_BODY_LIMIT_BYTES", defaultBodySize)

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel}))
	slog.SetDefault(logger)

	server, err := newAuthServer(bodyLimit)
	if err != nil {
		slog.Error("failed to initialize ext_authz server", "error", err)
		os.Exit(1)
	}

	prometheus.MustRegister(server.requests, server.interruptions, server.failures)

	metricsMux := http.NewServeMux()
	metricsMux.Handle("/metrics", promhttp.Handler())
	metricsMux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	go func() {
		slog.Info("starting metrics server", "bind", metricsBind)
		if err := http.ListenAndServe(metricsBind, metricsMux); err != nil {
			slog.Error("metrics server exited", "error", err)
			os.Exit(1)
		}
	}()

	listener, err := net.Listen("tcp", grpcBind)
	if err != nil {
		slog.Error("failed to bind gRPC listener", "bind", grpcBind, "error", err)
		os.Exit(1)
	}

	grpcServer := grpc.NewServer()
	authv3.RegisterAuthorizationServer(grpcServer, server)

	slog.Info("starting coraza ext_authz server", "grpc_bind", grpcBind, "metrics_bind", metricsBind, "request_body_limit_bytes", bodyLimit)
	if err := grpcServer.Serve(listener); err != nil {
		slog.Error("gRPC server exited", "error", err)
		os.Exit(1)
	}
}

func envOrDefault(name, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}

func intEnvOrDefault(name string, fallback int) int {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		slog.Warn("invalid int env, using fallback", "name", name, "value", raw, "fallback", fallback)
		return fallback
	}
	return value
}

func parseLevel(raw string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
