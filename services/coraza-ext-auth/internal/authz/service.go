package authz

import (
	"context"
	"fmt"
	"log/slog"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
)

type Service struct {
	authv3.UnimplementedAuthorizationServer
	evaluator model.Evaluator
	recorder  model.Recorder
	logger    *slog.Logger
}

func NewService(evaluator model.Evaluator, recorder model.Recorder, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}

	return &Service{
		evaluator: evaluator,
		recorder:  recorder,
		logger:    logger,
	}
}

func (s *Service) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	parsed := ParseCheckRequest(req)
	result := s.evaluator.Evaluate(ctx, parsed)

	if s.recorder != nil {
		s.recorder.Record(parsed, result)
	}

	ruleID := result.RuleID
	if ruleID == "" && result.Interruption != nil {
		ruleID = strconvItoa(result.Interruption.RuleID)
	}
	log := s.logger.With(
		"request_id", parsed.ID,
		"host", parsed.Host,
		"path", parsed.Path,
		"mode", parsed.Mode,
		"rule_id", ruleID,
		"decision", result.Decision,
	)

	switch result.Decision {
	case model.DecisionError:
		log.Error("ext_authz evaluation failed", "error", result.Err)
	case model.DecisionDeny:
		log.Warn("ext_authz denied request")
	default:
		log.Info("ext_authz allowed request")
	}

	return ToCheckResponse(parsed, result), nil
}

func strconvItoa(v int) string {
	if v == 0 {
		return ""
	}
	return fmt.Sprintf("%d", v)
}
