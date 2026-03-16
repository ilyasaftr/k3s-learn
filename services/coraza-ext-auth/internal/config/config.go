package config

import (
	"log/slog"
	"os"
	"strconv"
	"strings"
)

const (
	defaultGRPCBind = ":9002"
	defaultHTTPBind = ":9090"
	defaultBodySize = 1048576
)

const (
	EnvGRPCBind             = "GRPC_BIND"
	EnvMetricsBind          = "METRICS_BIND"
	EnvLogLevel             = "LOG_LEVEL"
	EnvRequestBodyLimitByte = "WAF_REQUEST_BODY_LIMIT_BYTES"
)

type Config struct {
	GRPCBind         string
	MetricsBind      string
	LogLevel         slog.Level
	RequestBodyLimit int
}

func Load() Config {
	return Config{
		GRPCBind:         envOrDefault(EnvGRPCBind, defaultGRPCBind),
		MetricsBind:      envOrDefault(EnvMetricsBind, defaultHTTPBind),
		LogLevel:         parseLevel(envOrDefault(EnvLogLevel, "INFO")),
		RequestBodyLimit: intEnvOrDefault(EnvRequestBodyLimitByte, defaultBodySize),
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
