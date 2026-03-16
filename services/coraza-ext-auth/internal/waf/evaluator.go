package waf

import (
	"context"
	"fmt"
	"log/slog"
	"net/url"
	"strconv"
	"strings"
	"time"

	coreruleset "github.com/corazawaf/coraza-coreruleset/v4"
	"github.com/corazawaf/coraza/v3"
	corazatypes "github.com/corazawaf/coraza/v3/types"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
)

const defaultDirectives = `
Include @coraza.conf-recommended
Include @crs-setup.conf.example
SecRuleEngine On
Include @owasp_crs/*.conf
`

type Evaluator struct {
	waf    coraza.WAF
	logger *slog.Logger
}

func NewEvaluator(bodyLimit int, logger *slog.Logger) (*Evaluator, error) {
	return NewEvaluatorWithDirectives(bodyLimit, strings.TrimSpace(defaultDirectives), logger)
}

func NewEvaluatorWithDirectives(bodyLimit int, directives string, logger *slog.Logger) (*Evaluator, error) {
	if logger == nil {
		logger = slog.Default()
	}

	wafConfig := coraza.NewWAFConfig().
		WithRootFS(coreruleset.FS).
		WithRequestBodyAccess().
		WithRequestBodyLimit(bodyLimit).
		WithRequestBodyInMemoryLimit(bodyLimit).
		WithErrorCallback(func(mr corazatypes.MatchedRule) {
			logger.Warn("coraza error callback", "message", mr.ErrorLog())
		}).
		WithDirectives(strings.TrimSpace(directives))

	wafEngine, err := coraza.NewWAF(wafConfig)
	if err != nil {
		return nil, fmt.Errorf("init coraza waf: %w", err)
	}

	return &Evaluator{
		waf:    wafEngine,
		logger: logger,
	}, nil
}

func (e *Evaluator) Evaluate(_ context.Context, req model.Request) model.Result {
	if req.ID == "" {
		req.ID = strconv.FormatInt(time.Now().UnixNano(), 10)
	}

	tx := e.waf.NewTransactionWithID(req.ID)
	defer func() {
		tx.ProcessLogging()
		_ = tx.Close()
	}()

	tx.ProcessConnection(req.ClientIP, req.ClientPort, req.ServerIP, req.ServerPort)
	tx.ProcessURI(req.Path, req.Method, req.Protocol)

	if req.Host != "" {
		tx.SetServerName(req.Host)
		tx.AddRequestHeader("host", req.Host)
	}

	for _, header := range req.Headers {
		tx.AddRequestHeader(strings.ToLower(header.Key), header.Value)
	}

	if req.Query != "" {
		queryValues, err := url.ParseQuery(req.Query)
		if err != nil {
			e.logger.Warn("unable to parse query arguments", "request_id", req.ID, "query", req.Query, "error", err)
		} else {
			for key, values := range queryValues {
				for _, value := range values {
					tx.AddGetRequestArgument(key, value)
				}
			}
		}
	}

	if interruption := tx.ProcessRequestHeaders(); interruption != nil {
		return e.handleInterruption(req, interruption)
	}

	if len(req.Body) > 0 {
		if interruption, _, err := tx.WriteRequestBody(req.Body); err != nil {
			return model.Result{
				Decision:       model.DecisionError,
				HTTPStatusCode: 500,
				Body:           "internal authorization error",
				Err:            fmt.Errorf("write request body: %w", err),
			}
		} else if interruption != nil {
			return e.handleInterruption(req, interruption)
		}
	}

	if interruption, err := tx.ProcessRequestBody(); err != nil {
		return model.Result{
			Decision:       model.DecisionError,
			HTTPStatusCode: 500,
			Body:           "internal authorization error",
			Err:            fmt.Errorf("process request body: %w", err),
		}
	} else if interruption != nil {
		return e.handleInterruption(req, interruption)
	}

	return model.Result{
		Decision: model.DecisionAllow,
	}
}

func (e *Evaluator) handleInterruption(req model.Request, interruption *corazatypes.Interruption) model.Result {
	ruleID := strconv.Itoa(interruption.RuleID)
	e.logger.Warn(
		"coraza interruption",
		"request_id", req.ID,
		"mode", req.Mode,
		"rule_id", interruption.RuleID,
		"action", interruption.Action,
		"status", interruption.Status,
		"host", req.Host,
		"path", req.Path,
	)

	if req.Mode == model.ModeBlock {
		return model.Result{
			Decision:       model.DecisionDeny,
			HTTPStatusCode: 403,
			Body:           "blocked by coraza waf",
			RuleID:         ruleID,
			Interruption: &model.Interruption{
				RuleID: interruption.RuleID,
				Action: interruption.Action,
				Status: interruption.Status,
				Data:   interruption.Data,
			},
		}
	}

	return model.Result{
		Decision: model.DecisionAllow,
		Interruption: &model.Interruption{
			RuleID: interruption.RuleID,
			Action: interruption.Action,
			Status: interruption.Status,
			Data:   interruption.Data,
		},
	}
}
