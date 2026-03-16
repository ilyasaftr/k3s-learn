package model

import "context"

type Mode string

const (
	ModeDetect Mode = "detect"
	ModeBlock  Mode = "block"
)

type Decision string

const (
	DecisionAllow Decision = "allow"
	DecisionDeny  Decision = "deny"
	DecisionError Decision = "error"
)

type Header struct {
	Key   string
	Value string
}

type Request struct {
	ID       string
	Method   string
	Path     string
	Query    string
	Host     string
	Protocol string
	Mode     Mode

	Headers []Header
	Body    []byte

	ClientIP   string
	ClientPort int
	ServerIP   string
	ServerPort int
}

type Interruption struct {
	RuleID int
	Action string
	Status int
	Data   string
}

type Result struct {
	Decision       Decision
	HTTPStatusCode int
	Body           string
	RuleID         string
	Interruption   *Interruption
	Err            error
}

type Evaluator interface {
	Evaluate(ctx context.Context, req Request) Result
}

type Recorder interface {
	Record(req Request, result Result)
}
