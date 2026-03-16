package authz

import (
	"context"
	"errors"
	"log/slog"
	"testing"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
)

type fakeEvaluator struct {
	result model.Result
}

func (f fakeEvaluator) Evaluate(_ context.Context, _ model.Request) model.Result {
	return f.result
}

type fakeRecorder struct {
	called bool
	req    model.Request
	result model.Result
}

func (f *fakeRecorder) Record(req model.Request, result model.Result) {
	f.called = true
	f.req = req
	f.result = result
}

func TestServiceCheckUsesEvaluatorAndRecorder(t *testing.T) {
	recorder := &fakeRecorder{}
	svc := NewService(
		fakeEvaluator{result: model.Result{Decision: model.DecisionAllow}},
		recorder,
		slog.Default(),
	)

	res, err := svc.Check(context.Background(), &authv3.CheckRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.GetOkResponse() == nil {
		t.Fatal("expected allow response")
	}
	if !recorder.called {
		t.Fatal("expected recorder to be called")
	}
}

func TestServiceCheckErrorDecision(t *testing.T) {
	recorder := &fakeRecorder{}
	svc := NewService(
		fakeEvaluator{result: model.Result{Decision: model.DecisionError, Err: errors.New("boom")}},
		recorder,
		slog.Default(),
	)

	res, err := svc.Check(context.Background(), &authv3.CheckRequest{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.GetDeniedResponse() == nil {
		t.Fatal("expected denied response")
	}
}
