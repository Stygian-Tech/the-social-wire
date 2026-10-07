package runner

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

func validEnvironment() map[string]string {
	return map[string]string{"INDEXING_WORKER_ROLE": "projection", "APP_ENV": "dev", "DATABASE_URL": "postgresql://localhost/test"}
}
func TestCommandOverridesAndStrictConfiguration(t *testing.T) {
	env := validEnvironment()
	configured, c, err := Configuration(env, []string{"--port", "9191", "--hostname", "127.0.0.1"})
	if err != nil || c.Port != 9191 || c.AppViewHealthPort != 9192 || c.WireHealthPort != 9193 || c.Host != "127.0.0.1" {
		t.Fatalf("config %+v %v", c, err)
	}
	if configured["PORT"] != "9191" || env["PORT"] != "" {
		t.Fatal("environment mutated or overrides lost")
	}
	for _, args := range [][]string{{"--port", "0"}, {"--port", "65535"}, {"--unknown"}, {"unexpected"}} {
		if _, _, err := Configuration(env, args); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
	env["APP_ENV"] = "local"
	if _, _, err := Configuration(env, nil); err == nil {
		t.Fatal("accepted non-hosted environment")
	}
	env["APP_ENV"] = "dev"
	env["INDEXING_APPVIEW_HEALTH_PORT"] = "8080"
	if _, _, err := Configuration(env, nil); err == nil {
		t.Fatal("accepted duplicate health port")
	}
}
func TestDomainRoleMapping(t *testing.T) {
	app, wire := domainRoles(indexingworkercore.Projection)
	if app != "projection" || wire != "drain" {
		t.Fatal(app, wire)
	}
	app, wire = domainRoles(indexingworkercore.Coordinator)
	if app != "coordinator" || wire != "rank" {
		t.Fatal(app, wire)
	}
}
func TestServeCancellationJoinsWorkload(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	began, finish := make(chan struct{}), make(chan struct{})
	joined := atomic.Bool{}
	done := make(chan error, 1)
	go func() {
		done <- serve(ctx, listener, http.NotFoundHandler(), func(ctx context.Context) error {
			close(began)
			<-ctx.Done()
			<-finish
			joined.Store(true)
			return ctx.Err()
		})
	}()
	<-began
	cancel()
	select {
	case <-done:
		t.Fatal("returned before workload joined")
	case <-time.After(10 * time.Millisecond):
	}
	close(finish)
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) || !joined.Load() {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("shutdown did not join")
	}
}
func TestServeListenerFailureCancelsWorkload(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	began := make(chan struct{})
	joined := atomic.Bool{}
	done := make(chan error, 1)
	go func() {
		done <- serve(context.Background(), listener, http.NotFoundHandler(), func(ctx context.Context) error { close(began); <-ctx.Done(); joined.Store(true); return ctx.Err() })
	}()
	<-began
	_ = listener.Close()
	select {
	case err := <-done:
		if err == nil || !joined.Load() {
			t.Fatal("listener failure lost or workload still active")
		}
	case <-time.After(time.Second):
		t.Fatal("workload did not stop")
	}
}

type testLane struct{ joined *atomic.Bool }

func (l testLane) Run(ctx context.Context, _ *operationscore.RoleLeaseAuthority) error {
	<-ctx.Done()
	l.joined.Store(true)
	return ctx.Err()
}
func (l testLane) Startup(context.Context) error { return nil }
func (l testLane) Ready(context.Context) error   { return nil }
func TestOwnedLaneClosesAfterJoin(t *testing.T) {
	reserve, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := reserve.Addr().(*net.TCPAddr).Port
	reserve.Close()
	joined, closed := &atomic.Bool{}, &atomic.Bool{}
	lane := &ownedLane{Lane: testLane{joined}, port: port, role: indexingworkercore.Projection, close: func() error {
		if !joined.Load() {
			return errors.New("pool closed before join")
		}
		closed.Store(true)
		return nil
	}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err = lane.Run(ctx, nil)
	if !errors.Is(err, context.Canceled) || !closed.Load() {
		t.Fatal(err)
	}
}
func TestObserverBoundsAndRedactsOperatorLabels(t *testing.T) {
	var output strings.Builder
	logger := slog.New(slog.NewJSONHandler(&output, nil))
	observer := newObserver(nil, "dev", "secret owner/=value", logger)
	observer.record(context.Background(), observedEvent{indexingworkercore.AppView, operationscore.LeaseEvent{Phase: "acquired"}})
	if strings.Contains(output.String(), "secret owner/") {
		t.Fatal("unsafe owner leaked")
	}
	unknown := "postgresql://user:password@private/database"
	if applicationCategory(&unknown) != "unknown" {
		t.Fatal("unknown application leaked")
	}
	if len(safeLabel(strings.Repeat("x", 300), 255)) != 255 {
		t.Fatal("label unbounded")
	}
	observer.logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	for i := 0; i < 1000; i++ {
		observer.event(indexingworkercore.Wire, operationscore.LeaseEvent{Phase: "acquired"})
	}
	if len(observer.queue) != 64 {
		t.Fatal("observer queue unbounded")
	}
}

func TestCancellationDoesNotHideJoinedShutdownFailure(t *testing.T) {
	if !IsCancellation(errors.Join(context.Canceled, context.Canceled)) {
		t.Fatal("normal joined cancellation rejected")
	}
	if IsCancellation(errors.Join(context.Canceled, errors.New("pool shutdown failed"))) {
		t.Fatal("shutdown failure hidden by cancellation")
	}
}
