package authz

import (
	"testing"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
)

func TestParseCheckRequestNilSafe(t *testing.T) {
	parsed := ParseCheckRequest(nil)
	if parsed.Method != "GET" {
		t.Fatalf("expected default method GET, got %q", parsed.Method)
	}
	if parsed.Path != "/" {
		t.Fatalf("expected default path /, got %q", parsed.Path)
	}
	if parsed.Mode != model.ModeDetect {
		t.Fatalf("expected default mode detect, got %q", parsed.Mode)
	}
}

func TestNormalizeMode(t *testing.T) {
	parsed := ParseCheckRequest(&authv3.CheckRequest{
		Attributes: &authv3.AttributeContext{
			ContextExtensions: map[string]string{"mode": "block"},
			Request:           &authv3.AttributeContext_Request{Http: &authv3.AttributeContext_HttpRequest{}},
		},
	})
	if parsed.Mode != model.ModeBlock {
		t.Fatalf("expected mode block, got %q", parsed.Mode)
	}

	parsed = ParseCheckRequest(&authv3.CheckRequest{
		Attributes: &authv3.AttributeContext{
			ContextExtensions: map[string]string{"mode": "something-else"},
			Request:           &authv3.AttributeContext_Request{Http: &authv3.AttributeContext_HttpRequest{}},
		},
	})
	if parsed.Mode != model.ModeDetect {
		t.Fatalf("expected fallback mode detect, got %q", parsed.Mode)
	}
}

func TestParseCheckRequestFields(t *testing.T) {
	parsed := ParseCheckRequest(&authv3.CheckRequest{
		Attributes: &authv3.AttributeContext{
			ContextExtensions: map[string]string{"mode": "detect"},
			Source: &authv3.AttributeContext_Peer{
				Address: &corev3.Address{
					Address: &corev3.Address_SocketAddress{
						SocketAddress: &corev3.SocketAddress{
							Address: "10.0.0.10",
							PortSpecifier: &corev3.SocketAddress_PortValue{
								PortValue: 12345,
							},
						},
					},
				},
			},
			Request: &authv3.AttributeContext_Request{
				Http: &authv3.AttributeContext_HttpRequest{
					Id:       "req-1",
					Method:   "POST",
					Path:     "/foo?a=1&b=2",
					Host:     "podinfo.klawu.com",
					Protocol: "HTTP/2",
					Headers: map[string]string{
						"X-Test": "abc",
					},
					Body: "hello",
				},
			},
		},
	})

	if parsed.ID != "req-1" {
		t.Fatalf("unexpected id: %q", parsed.ID)
	}
	if parsed.Method != "POST" {
		t.Fatalf("unexpected method: %q", parsed.Method)
	}
	if parsed.Path != "/foo" || parsed.Query != "a=1&b=2" {
		t.Fatalf("unexpected path/query: %q / %q", parsed.Path, parsed.Query)
	}
	if parsed.Host != "podinfo.klawu.com" {
		t.Fatalf("unexpected host: %q", parsed.Host)
	}
	if parsed.Protocol != "HTTP/2" {
		t.Fatalf("unexpected protocol: %q", parsed.Protocol)
	}
	if parsed.ClientIP != "10.0.0.10" || parsed.ClientPort != 12345 {
		t.Fatalf("unexpected source peer: %s:%d", parsed.ClientIP, parsed.ClientPort)
	}
	if len(parsed.Headers) == 0 {
		t.Fatal("expected headers")
	}
	if string(parsed.Body) != "hello" {
		t.Fatalf("unexpected body: %q", string(parsed.Body))
	}
}
