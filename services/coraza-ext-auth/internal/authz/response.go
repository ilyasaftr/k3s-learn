package authz

import (
	"strconv"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc/codes"
)

func ToCheckResponse(req model.Request, result model.Result) *authv3.CheckResponse {
	switch result.Decision {
	case model.DecisionDeny, model.DecisionError:
		statusCode := result.HTTPStatusCode
		if statusCode <= 0 {
			if result.Decision == model.DecisionError {
				statusCode = 500
			} else {
				statusCode = 403
			}
		}

		body := result.Body
		if body == "" {
			if result.Decision == model.DecisionError {
				body = "internal authorization error"
			} else {
				body = "blocked by coraza waf"
			}
		}

		ruleID := result.RuleID
		if ruleID == "" && result.Interruption != nil {
			ruleID = strconv.Itoa(result.Interruption.RuleID)
		}
		if ruleID == "" {
			ruleID = "0"
		}

		return deniedResponse(httpStatusCode(statusCode), body, string(req.Mode), ruleID)
	default:
		return allowResponse()
	}
}

func allowResponse() *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &status.Status{Code: int32(codes.OK)},
		HttpResponse: &authv3.CheckResponse_OkResponse{
			OkResponse: &authv3.OkHttpResponse{},
		},
	}
}

func deniedResponse(httpCode typev3.StatusCode, body, mode, ruleID string) *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &status.Status{Code: int32(codes.PermissionDenied)},
		HttpResponse: &authv3.CheckResponse_DeniedResponse{
			DeniedResponse: &authv3.DeniedHttpResponse{
				Status: &typev3.HttpStatus{Code: httpCode},
				Body:   body,
				Headers: []*corev3.HeaderValueOption{
					{
						Header: &corev3.HeaderValue{
							Key:   "x-coraza-mode",
							Value: mode,
						},
					},
					{
						Header: &corev3.HeaderValue{
							Key:   "x-coraza-rule-id",
							Value: ruleID,
						},
					},
				},
			},
		},
	}
}

func httpStatusCode(code int) typev3.StatusCode {
	switch code {
	case 400:
		return typev3.StatusCode_BadRequest
	case 401:
		return typev3.StatusCode_Unauthorized
	case 403:
		return typev3.StatusCode_Forbidden
	case 404:
		return typev3.StatusCode_NotFound
	case 413:
		return typev3.StatusCode_PayloadTooLarge
	case 429:
		return typev3.StatusCode_TooManyRequests
	case 500:
		return typev3.StatusCode_InternalServerError
	case 503:
		return typev3.StatusCode_ServiceUnavailable
	default:
		return typev3.StatusCode_InternalServerError
	}
}
