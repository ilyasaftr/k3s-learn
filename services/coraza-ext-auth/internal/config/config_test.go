package config

import (
	"log/slog"
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	t.Setenv(EnvGRPCBind, "")
	t.Setenv(EnvMetricsBind, "")
	t.Setenv(EnvLogLevel, "")
	t.Setenv(EnvRequestBodyLimitByte, "")

	cfg := Load()
	if cfg.GRPCBind != ":9002" {
		t.Fatalf("unexpected grpc bind: %q", cfg.GRPCBind)
	}
	if cfg.MetricsBind != ":9090" {
		t.Fatalf("unexpected metrics bind: %q", cfg.MetricsBind)
	}
	if cfg.LogLevel != slog.LevelInfo {
		t.Fatalf("unexpected log level: %v", cfg.LogLevel)
	}
	if cfg.RequestBodyLimit != 1048576 {
		t.Fatalf("unexpected request body limit: %d", cfg.RequestBodyLimit)
	}
}

func TestLoadInvalidBodyLimitFallsBack(t *testing.T) {
	t.Setenv(EnvRequestBodyLimitByte, "invalid")
	cfg := Load()
	if cfg.RequestBodyLimit != 1048576 {
		t.Fatalf("expected fallback request body limit, got %d", cfg.RequestBodyLimit)
	}

	t.Setenv(EnvRequestBodyLimitByte, "0")
	cfg = Load()
	if cfg.RequestBodyLimit != 1048576 {
		t.Fatalf("expected fallback request body limit for zero, got %d", cfg.RequestBodyLimit)
	}
}

func TestLoadCustomValues(t *testing.T) {
	t.Setenv(EnvGRPCBind, "127.0.0.1:10000")
	t.Setenv(EnvMetricsBind, "127.0.0.1:10001")
	t.Setenv(EnvLogLevel, "debug")
	t.Setenv(EnvRequestBodyLimitByte, "4096")

	cfg := Load()
	if cfg.GRPCBind != "127.0.0.1:10000" {
		t.Fatalf("unexpected grpc bind: %q", cfg.GRPCBind)
	}
	if cfg.MetricsBind != "127.0.0.1:10001" {
		t.Fatalf("unexpected metrics bind: %q", cfg.MetricsBind)
	}
	if cfg.LogLevel != slog.LevelDebug {
		t.Fatalf("unexpected log level: %v", cfg.LogLevel)
	}
	if cfg.RequestBodyLimit != 4096 {
		t.Fatalf("unexpected request body limit: %d", cfg.RequestBodyLimit)
	}
}
