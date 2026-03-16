package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/authz"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/config"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/metrics"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/server"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/waf"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	cfg := config.Load()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: cfg.LogLevel,
	}))
	slog.SetDefault(logger)

	evaluator, err := waf.NewEvaluator(cfg.RequestBodyLimit, logger)
	if err != nil {
		logger.Error("failed to initialize evaluator", "error", err)
		os.Exit(1)
	}

	registry := prometheus.NewRegistry()
	recorder, err := metrics.NewPrometheusRecorder(registry)
	if err != nil {
		logger.Error("failed to initialize metrics recorder", "error", err)
		os.Exit(1)
	}

	authzService := authz.NewService(evaluator, recorder, logger)

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	app := server.New(
		cfg.GRPCBind,
		cfg.MetricsBind,
		authzService,
		mux,
		logger,
	)

	if err := app.Start(); err != nil {
		logger.Error("failed to start service", "error", err)
		os.Exit(1)
	}

	logger.Info(
		"coraza ext_authz service started",
		"grpc_bind", app.GRPCAddr(),
		"metrics_bind", app.MetricsAddr(),
		"request_body_limit_bytes", cfg.RequestBodyLimit,
	)

	runCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := app.Wait(runCtx); err != nil {
		logger.Error("service exited with error", "error", err)
		os.Exit(1)
	}
}
