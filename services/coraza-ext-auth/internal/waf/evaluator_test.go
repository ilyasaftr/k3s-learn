package waf

import (
	"context"
	"io"
	"log/slog"
	"testing"

	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
)

const testDirectives = `
SecRuleEngine On
SecRule REQUEST_URI "@streq /blocked" "id:101,phase:1,deny,status:403"
`

func newTestLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestEvaluatorAllow(t *testing.T) {
	evaluator, err := NewEvaluatorWithDirectives(4096, testDirectives, newTestLogger())
	if err != nil {
		t.Fatalf("new evaluator: %v", err)
	}

	result := evaluator.Evaluate(context.Background(), model.Request{
		ID:       "req-1",
		Method:   "GET",
		Path:     "/ok",
		Protocol: "HTTP/1.1",
		Mode:     model.ModeDetect,
	})
	if result.Decision != model.DecisionAllow {
		t.Fatalf("expected allow decision, got %q", result.Decision)
	}
	if result.Interruption != nil {
		t.Fatal("expected no interruption")
	}
}

func TestEvaluatorInterruptionDetectModeAllows(t *testing.T) {
	evaluator, err := NewEvaluatorWithDirectives(4096, testDirectives, newTestLogger())
	if err != nil {
		t.Fatalf("new evaluator: %v", err)
	}

	result := evaluator.Evaluate(context.Background(), model.Request{
		ID:       "req-2",
		Method:   "GET",
		Path:     "/blocked",
		Protocol: "HTTP/1.1",
		Mode:     model.ModeDetect,
	})
	if result.Decision != model.DecisionAllow {
		t.Fatalf("expected allow decision in detect mode, got %q", result.Decision)
	}
	if result.Interruption == nil {
		t.Fatal("expected interruption in detect mode")
	}
}

func TestEvaluatorInterruptionBlockModeDenies(t *testing.T) {
	evaluator, err := NewEvaluatorWithDirectives(4096, testDirectives, newTestLogger())
	if err != nil {
		t.Fatalf("new evaluator: %v", err)
	}

	result := evaluator.Evaluate(context.Background(), model.Request{
		ID:       "req-3",
		Method:   "GET",
		Path:     "/blocked",
		Protocol: "HTTP/1.1",
		Mode:     model.ModeBlock,
	})
	if result.Decision != model.DecisionDeny {
		t.Fatalf("expected deny decision in block mode, got %q", result.Decision)
	}
	if result.HTTPStatusCode != 403 {
		t.Fatalf("expected HTTP 403, got %d", result.HTTPStatusCode)
	}
	if result.RuleID == "" {
		t.Fatal("expected rule id in blocked response")
	}
}
