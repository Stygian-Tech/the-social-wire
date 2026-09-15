package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

type stubLeaseAcquirer struct {
	calls int
	lease store.Lease
	errs  []error
}

func (s *stubLeaseAcquirer) AcquireLease(
	_ context.Context,
	_ string,
	_ string,
	_ time.Duration,
) (store.Lease, error) {
	index := s.calls
	s.calls++
	if index < len(s.errs) {
		return store.Lease{}, s.errs[index]
	}
	return s.lease, nil
}

func TestAcquireLeaseWithRetryWaitsForHandoff(t *testing.T) {
	want := store.Lease{Name: "jetstream-v2-ingest", OwnerID: "new-owner", FencingToken: 9}
	database := &stubLeaseAcquirer{
		lease: want,
		errs:  []error{store.ErrLeaseUnavailable, store.ErrLeaseUnavailable},
	}

	lease, err := acquireLeaseWithRetry(
		context.Background(),
		database,
		want.Name,
		want.OwnerID,
		30*time.Second,
		time.Millisecond,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	if err != nil {
		t.Fatalf("acquire lease: %v", err)
	}
	if lease != want {
		t.Fatalf("lease = %+v, want %+v", lease, want)
	}
	if database.calls != 3 {
		t.Fatalf("AcquireLease calls = %d, want 3", database.calls)
	}
}

func TestAcquireLeaseWithRetryReturnsNonLeaseErrors(t *testing.T) {
	wantErr := errors.New("database unavailable")
	database := &stubLeaseAcquirer{errs: []error{wantErr}}

	_, err := acquireLeaseWithRetry(
		context.Background(),
		database,
		"jetstream-v2-ingest",
		"new-owner",
		30*time.Second,
		time.Millisecond,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}
	if database.calls != 1 {
		t.Fatalf("AcquireLease calls = %d, want 1", database.calls)
	}
}

func TestAcquireLeaseWithRetryStopsWhenCancelled(t *testing.T) {
	database := &stubLeaseAcquirer{errs: []error{store.ErrLeaseUnavailable}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := acquireLeaseWithRetry(
		ctx,
		database,
		"jetstream-v2-ingest",
		"new-owner",
		30*time.Second,
		time.Hour,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context.Canceled", err)
	}
}

func TestExpiredCanaryDoesNotOpenDatabase(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, stop := context.WithCancel(context.Background())
		expires := time.Now().Add(-time.Second)
		state := &health.State{}
		done := make(chan error, 1)
		go func() {
			done <- runLane(ctx, config.Lane{Name: config.WireLaneName, Config: config.Config{
				PipelineMode: config.WirePipelineMode, DatabaseURL: "invalid-database-url",
				ReplayCanaryExpiresAt: &expires,
			}}, state, slog.New(slog.NewTextHandler(io.Discard, nil)))
		}()
		synctest.Wait()
		select {
		case err := <-done:
			t.Fatalf("expired lane reached database or returned: %v", err)
		default:
		}
		if !state.Snapshot().Paused {
			t.Fatal("expired lane was not paused")
		}
		stop()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	})
}
