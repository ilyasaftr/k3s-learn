package authz

import (
	"testing"

	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
	"google.golang.org/grpc/codes"
)

func TestAllowResponse(t *testing.T) {
	res := ToCheckResponse(model.Request{Mode: model.ModeDetect}, model.Result{Decision: model.DecisionAllow})

	if got := res.GetStatus().GetCode(); got != int32(codes.OK) {
		t.Fatalf("expected gRPC OK, got %d", got)
	}
	if res.GetOkResponse() == nil {
		t.Fatal("expected ok response")
	}
}

func TestDenyResponse(t *testing.T) {
	res := ToCheckResponse(
		model.Request{Mode: model.ModeBlock},
		model.Result{
			Decision:       model.DecisionDeny,
			HTTPStatusCode: 403,
			Body:           "blocked by coraza waf",
			RuleID:         "101",
		},
	)

	if got := res.GetStatus().GetCode(); got != int32(codes.PermissionDenied) {
		t.Fatalf("expected gRPC PermissionDenied, got %d", got)
	}

	denied := res.GetDeniedResponse()
	if denied == nil {
		t.Fatal("expected denied response")
	}
	if denied.GetStatus().GetCode() != typev3.StatusCode_Forbidden {
		t.Fatalf("expected HTTP 403, got %v", denied.GetStatus().GetCode())
	}
	if denied.GetBody() != "blocked by coraza waf" {
		t.Fatalf("unexpected denied body: %q", denied.GetBody())
	}
}

func TestInternalErrorResponse(t *testing.T) {
	res := ToCheckResponse(
		model.Request{Mode: model.ModeDetect},
		model.Result{
			Decision: model.DecisionError,
		},
	)

	denied := res.GetDeniedResponse()
	if denied == nil {
		t.Fatal("expected denied response")
	}
	if denied.GetStatus().GetCode() != typev3.StatusCode_InternalServerError {
		t.Fatalf("expected HTTP 500, got %v", denied.GetStatus().GetCode())
	}
}
