package server

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"testing"
	"time"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

type allowAuthzServer struct {
	authv3.UnimplementedAuthorizationServer
}

func TestAppStartsAndServesHealthAndGrpc(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	app := New(
		"127.0.0.1:0",
		"127.0.0.1:0",
		allowAuthzServer{},
		mux,
		logger,
	)

	if err := app.Start(); err != nil {
		t.Fatalf("start app: %v", err)
	}
	t.Cleanup(func() {
		_ = app.Shutdown(context.Background())
	})

	if app.GRPCAddr() == "" {
		t.Fatal("grpc addr should be set after start")
	}
	if app.MetricsAddr() == "" {
		t.Fatal("metrics addr should be set after start")
	}

	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://" + app.MetricsAddr() + "/healthz")
	if err != nil {
		t.Fatalf("healthz request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("unexpected healthz status: %d", resp.StatusCode)
	}

	conn, err := grpc.DialContext(
		context.Background(),
		app.GRPCAddr(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithBlock(),
		grpc.WithContextDialer(func(ctx context.Context, addr string) (net.Conn, error) {
			dialer := &net.Dialer{}
			return dialer.DialContext(ctx, "tcp", addr)
		}),
	)
	if err != nil {
		t.Fatalf("grpc dial failed: %v", err)
	}
	_ = conn.Close()
}
