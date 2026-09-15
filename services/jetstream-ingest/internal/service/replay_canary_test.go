package service

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
)

func TestReplayCanaryExpiredRestartDoesNotInvokeLane(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		expires := time.Now().Add(-time.Second)
		for range 2 { // A replacement owner receives the same retained absolute expiry.
			ctx, stop := context.WithCancel(context.Background())
			state := &health.State{}
			done := make(chan error, 1)
			go func() {
				done <- RunWithReplayCanary(ctx, config.Config{PipelineMode: config.WirePipelineMode, ReplayCanaryExpiresAt: &expires}, state, func(context.Context) error {
					t.Error("expired owner started database/lease/replay work")
					return nil
				})
			}()
			synctest.Wait()
			if !state.Snapshot().Paused || state.Snapshot().Ready || state.Snapshot().LastError != ErrReplayCanaryExpired.Error() {
				t.Fatalf("expired health = %+v", state.Snapshot())
			}
			select {
			case <-done:
				t.Fatal("expired lane returned and permits supervisor restart")
			default:
			}
			stop()
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		}
	})
}

type canaryRoundTripper func(*http.Request) (*http.Response, error)

func (f canaryRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestReplayCanaryCancelsInflightTransportAndWaitsForCleanup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, stop := context.WithCancel(context.Background())
		defer stop()
		expires := time.Now().Add(time.Second)
		state := &health.State{}
		flushed := make(chan struct{})
		cleanup := make(chan struct{})
		done := make(chan error, 1)
		go func() {
			done <- RunWithReplayCanary(ctx, config.Config{PipelineMode: config.WirePipelineMode, ReplayCanaryExpiresAt: &expires}, state, func(laneContext context.Context) error {
				client := http.Client{Transport: canaryRoundTripper(func(request *http.Request) (*http.Response, error) {
					<-request.Context().Done()
					return nil, request.Context().Err()
				})}
				request, err := http.NewRequestWithContext(laneContext, http.MethodGet, "https://archive.invalid/test", nil)
				if err != nil {
					return err
				}
				_, err = client.Do(request)
				if !errors.Is(err, context.DeadlineExceeded) {
					t.Errorf("transport cancellation = %v", err)
				}
				<-cleanup // Simulate finishing durable usage/staging after transport cancellation.
				close(flushed)
				return err
			})
		}()
		time.Sleep(time.Second)
		synctest.Wait()
		if state.Snapshot().Paused {
			t.Fatal("published stopped state before lane cleanup joined")
		}
		select {
		case <-done:
			t.Fatal("detached unfinished lane")
		default:
		}
		close(cleanup)
		synctest.Wait()
		select {
		case <-flushed:
		default:
			t.Fatal("missing cleanup")
		}
		if !state.Snapshot().Paused {
			t.Fatal("deadline did not park lane after cleanup")
		}
		stop()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	})
}

func TestReplayCanaryIsolatedFromAppViewSupervisor(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, stop := context.WithCancel(context.Background())
		expires := time.Now().Add(time.Second)
		wireState := &health.State{}
		var wireStarts, appViewStarts atomic.Int32
		var appViewContext context.Context
		done := make(chan struct{})
		go func() {
			Supervisor{Logger: slog.New(slog.NewTextHandler(io.Discard, nil)), Lanes: []SupervisedLane{
				{Name: "wire", Run: func(ctx context.Context) error {
					return RunWithReplayCanary(ctx, config.Config{PipelineMode: config.WirePipelineMode, ReplayCanaryExpiresAt: &expires}, wireState, func(ctx context.Context) error {
						wireStarts.Add(1)
						<-ctx.Done()
						return ctx.Err()
					})
				}},
				{Name: "appview", Run: func(ctx context.Context) error {
					return RunWithReplayCanary(ctx, config.Config{PipelineMode: config.DefaultPipelineMode}, &health.State{}, func(ctx context.Context) error {
						appViewStarts.Add(1)
						appViewContext = ctx
						<-ctx.Done()
						return ctx.Err()
					})
				}},
			}}.Run(ctx)
			close(done)
		}()
		time.Sleep(5 * time.Second)
		synctest.Wait()
		if wireStarts.Load() != 1 || appViewStarts.Load() != 1 || appViewContext.Err() != nil || !wireState.Snapshot().Paused {
			t.Fatalf("lane isolation failed: wire=%d appview=%d paused=%t", wireStarts.Load(), appViewStarts.Load(), wireState.Snapshot().Paused)
		}
		stop()
		<-done
	})
}

func TestReplayCanaryUnsetPreservesCallbackAndEarlyFailure(t *testing.T) {
	want := errors.New("lane failure")
	for _, expiry := range []*time.Time{nil, func() *time.Time { v := time.Now().Add(time.Hour); return &v }()} {
		state := &health.State{}
		err := RunWithReplayCanary(context.Background(), config.Config{PipelineMode: config.WirePipelineMode, ReplayCanaryExpiresAt: expiry}, state, func(context.Context) error { return want })
		if !errors.Is(err, want) || state.Snapshot().Paused {
			t.Fatalf("early failure = %v", err)
		}
	}
}

func TestReplayCanaryParentCancellationDoesNotReportExpiry(t *testing.T) {
	ctx, stop := context.WithCancel(context.Background())
	expires := time.Now().Add(time.Hour)
	state := &health.State{}
	err := RunWithReplayCanary(ctx, config.Config{PipelineMode: config.WirePipelineMode, ReplayCanaryExpiresAt: &expires}, state, func(ctx context.Context) error {
		stop()
		<-ctx.Done()
		return ctx.Err()
	})
	if !errors.Is(err, context.Canceled) || state.Snapshot().Paused {
		t.Fatalf("parent cancellation = %v", err)
	}
}
