package metrics

import (
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
	"github.com/prometheus/client_golang/prometheus"
)

type PrometheusRecorder struct {
	requests      *prometheus.CounterVec
	interruptions *prometheus.CounterVec
	failures      prometheus.Counter
}

func NewPrometheusRecorder(registerer prometheus.Registerer) (*PrometheusRecorder, error) {
	recorder := &PrometheusRecorder{
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
	}

	if err := registerer.Register(recorder.requests); err != nil {
		return nil, err
	}
	if err := registerer.Register(recorder.interruptions); err != nil {
		return nil, err
	}
	if err := registerer.Register(recorder.failures); err != nil {
		return nil, err
	}

	return recorder, nil
}

func (r *PrometheusRecorder) Record(req model.Request, result model.Result) {
	mode := string(req.Mode)
	if mode == "" {
		mode = string(model.ModeDetect)
	}

	decision := string(result.Decision)
	if decision == "" {
		decision = string(model.DecisionAllow)
	}
	r.requests.WithLabelValues(mode, decision).Inc()

	if result.Interruption != nil {
		r.interruptions.WithLabelValues(mode).Inc()
	}

	if result.Decision == model.DecisionError {
		r.failures.Inc()
	}
}

type NoopRecorder struct{}

func (NoopRecorder) Record(_ model.Request, _ model.Result) {}
