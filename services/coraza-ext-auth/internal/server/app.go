package server

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"google.golang.org/grpc"
)

const shutdownTimeout = 10 * time.Second

type App struct {
	logger *slog.Logger

	grpcBind    string
	metricsBind string

	authzServer authv3.AuthorizationServer
	httpHandler http.Handler

	grpcServer      *grpc.Server
	metricsServer   *http.Server
	grpcListener    net.Listener
	metricsListener net.Listener

	errCh      chan error
	startOnce  sync.Once
	shutOnce   sync.Once
	shutdownCh chan struct{}
}

func New(
	grpcBind string,
	metricsBind string,
	authzServer authv3.AuthorizationServer,
	httpHandler http.Handler,
	logger *slog.Logger,
) *App {
	if logger == nil {
		logger = slog.Default()
	}

	return &App{
		logger:      logger,
		grpcBind:    grpcBind,
		metricsBind: metricsBind,
		authzServer: authzServer,
		httpHandler: httpHandler,
		errCh:       make(chan error, 2),
		shutdownCh:  make(chan struct{}),
	}
}

func (a *App) Start() error {
	var startErr error
	a.startOnce.Do(func() {
		a.grpcListener, startErr = net.Listen("tcp", a.grpcBind)
		if startErr != nil {
			startErr = errors.Join(errors.New("listen grpc"), startErr)
			return
		}

		a.metricsListener, startErr = net.Listen("tcp", a.metricsBind)
		if startErr != nil {
			startErr = errors.Join(errors.New("listen metrics"), startErr)
			_ = a.grpcListener.Close()
			return
		}

		a.grpcServer = grpc.NewServer()
		authv3.RegisterAuthorizationServer(a.grpcServer, a.authzServer)

		a.metricsServer = &http.Server{
			Handler: a.httpHandler,
		}

		go func() {
			a.logger.Info("starting gRPC server", "bind", a.grpcListener.Addr().String())
			if err := a.grpcServer.Serve(a.grpcListener); err != nil {
				if !errors.Is(err, net.ErrClosed) {
					a.errCh <- err
				}
			}
		}()

		go func() {
			a.logger.Info("starting metrics server", "bind", a.metricsListener.Addr().String())
			if err := a.metricsServer.Serve(a.metricsListener); err != nil {
				if !errors.Is(err, http.ErrServerClosed) {
					a.errCh <- err
				}
			}
		}()
	})

	return startErr
}

func (a *App) Wait(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return a.Shutdown(context.Background())
	case err := <-a.errCh:
		_ = a.Shutdown(context.Background())
		return err
	case <-a.shutdownCh:
		return nil
	}
}

func (a *App) Shutdown(ctx context.Context) error {
	var shutdownErr error
	a.shutOnce.Do(func() {
		defer close(a.shutdownCh)

		if ctx == nil {
			ctx = context.Background()
		}
		shutdownCtx, cancel := context.WithTimeout(ctx, shutdownTimeout)
		defer cancel()

		if a.metricsServer != nil {
			if err := a.metricsServer.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
				shutdownErr = errors.Join(shutdownErr, err)
			}
		}

		if a.grpcServer != nil {
			a.grpcServer.GracefulStop()
		}
	})
	return shutdownErr
}

func (a *App) GRPCAddr() string {
	if a.grpcListener == nil {
		return ""
	}
	return a.grpcListener.Addr().String()
}

func (a *App) MetricsAddr() string {
	if a.metricsListener == nil {
		return ""
	}
	return a.metricsListener.Addr().String()
}
