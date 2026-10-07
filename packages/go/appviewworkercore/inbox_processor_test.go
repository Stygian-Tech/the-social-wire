package appviewworkercore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"testing"
	"time"
)

type projectorFunc func(context.Context, thinappviewcore.InboxItem) error

func (f projectorFunc) Apply(ctx context.Context, item thinappviewcore.InboxItem) error {
	return f(ctx, item)
}

type processorRepository struct {
	action   string
	next     time.Time
	renewErr error
}

type cancellingRenewRepository struct {
	processorRepository
	entered chan struct{}
}

func (r *cancellingRenewRepository) Renew(ctx context.Context, _ thinappviewcore.InboxItem, _ string, _, _ time.Time) error {
	close(r.entered)
	<-ctx.Done()
	return ctx.Err()
}

func TestSuccessfulProjectionAcknowledgesAfterCancellingPendingRenewal(t *testing.T) {
	repo := &cancellingRenewRepository{entered: make(chan struct{})}
	processor := InboxProcessor{Repository: repo, Projector: projectorFunc(func(context.Context, thinappviewcore.InboxItem) error {
		<-repo.entered
		return nil
	}), WorkerID: "fixture", LeaseDuration: 3 * time.Millisecond, ProjectionTimeout: time.Second}
	if err := processor.Process(context.Background(), thinappviewcore.InboxItem{}); err != nil {
		t.Fatal(err)
	}
	if repo.action != "applied" {
		t.Fatalf("sibling cancellation suppressed acknowledgement: %s", repo.action)
	}
}

func (r *processorRepository) Applied(context.Context, thinappviewcore.InboxItem, string, time.Time, time.Time) error {
	r.action = "applied"
	return nil
}
func (r *processorRepository) Retry(_ context.Context, _ thinappviewcore.InboxItem, _, _, _ string, next, _ time.Time) error {
	r.action = "retry"
	r.next = next
	return nil
}
func (r *processorRepository) Renew(context.Context, thinappviewcore.InboxItem, string, time.Time, time.Time) error {
	return r.renewErr
}
func (r *processorRepository) DeadLetter(context.Context, thinappviewcore.InboxItem, string, string, string, time.Time, time.Time) error {
	r.action = "dead_letter"
	return nil
}
func TestInboxProcessorTerminalTransitions(t *testing.T) {
	now := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name    string
		attempt int
		failure error
		want    string
	}{{"success", 0, nil, "applied"}, {"retry", 0, errors.New("publisher unavailable"), "retry"}, {"exhausted", 9, errors.New("publisher unavailable"), "dead_letter"}} {
		t.Run(tc.name, func(t *testing.T) {
			repo := &processorRepository{}
			processor := InboxProcessor{Repository: repo, Projector: projectorFunc(func(context.Context, thinappviewcore.InboxItem) error { return tc.failure }), WorkerID: "fixture", LeaseDuration: time.Minute, ProjectionTimeout: time.Second, AppliedRetention: time.Hour, DeadLetterRetention: time.Hour, Now: func() time.Time { return now }, Jitter: func() float64 { return 0 }}
			if err := processor.Process(context.Background(), thinappviewcore.InboxItem{AttemptCount: tc.attempt}); err != nil {
				t.Fatal(err)
			}
			if repo.action != tc.want {
				t.Fatalf("got %s want %s", repo.action, tc.want)
			}
			if tc.want == "retry" && repo.next.Sub(now) != 250*time.Millisecond {
				t.Fatal("first retry backoff")
			}
		})
	}
}
func TestInboxProcessorLeaseLossCancelsProjection(t *testing.T) {
	repo := &processorRepository{renewErr: thinappviewcore.ErrStaleInboxLease}
	canceled := make(chan struct{})
	processor := InboxProcessor{Repository: repo, Projector: projectorFunc(func(ctx context.Context, _ thinappviewcore.InboxItem) error {
		<-ctx.Done()
		close(canceled)
		return ctx.Err()
	}), WorkerID: "fixture", LeaseDuration: 3 * time.Millisecond, ProjectionTimeout: time.Second}
	if err := processor.Process(context.Background(), thinappviewcore.InboxItem{}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-canceled:
	default:
		t.Fatal("lease loss must cancel projection")
	}
	if repo.action != "retry" {
		t.Fatal("must not acknowledge projection after lease loss")
	}
}
func TestInboxRetryDelayBounds(t *testing.T) {
	if InboxRetryDelay(0, -10) != 250*time.Millisecond || InboxRetryDelay(1, 10) != 312500*time.Microsecond || InboxRetryDelay(100, 1) != 30*time.Second {
		t.Fatal("retry delay bounds")
	}
}
