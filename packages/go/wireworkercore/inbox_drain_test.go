package wireworkercore

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

type drainFake struct {
	mu            sync.Mutex
	claimed       bool
	applyStarted  chan struct{}
	applyFinished chan struct{}
	next          int
	events        []InboxEvent
}

func (f *drainFake) ClaimWork(_ context.Context, _ time.Time, limit int, _ *InboxRepository) (InboxWorkBatch, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.claimed {
		return InboxWorkBatch{}, nil
	}
	f.claimed = true
	return InboxWorkBatch{Events: f.events[:min(limit, len(f.events))]}, nil
}
func (f *drainFake) ClaimNext(context.Context, InboxRepository, time.Time) (*InboxEvent, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.next++
	return nil, nil
}
func (f *drainFake) ApplyClaimed(ctx context.Context, _ InboxEvent, _ time.Time) (InboxOutcome, error) {
	if f.applyStarted != nil {
		close(f.applyStarted)
		<-ctx.Done()
		close(f.applyFinished)
		return InboxLeaseLost, ctx.Err()
	}
	return InboxApplied, nil
}
func TestDrainCancellationJoinsInFlightApplication(t *testing.T) {
	f := &drainFake{events: []InboxEvent{{}}, applyStarted: make(chan struct{}), applyFinished: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	r := DrainRuntime{Processor: f, Evidence: &DrainEvidence{}, Config: DefaultDrainConfig()}
	go func() { done <- r.Run(ctx) }()
	select {
	case <-f.applyStarted:
	case <-time.After(time.Second):
		t.Fatal("application did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
		select {
		case <-f.applyFinished:
		default:
			t.Fatal("runtime returned before application joined")
		}
	case <-time.After(time.Second):
		t.Fatal("runtime did not terminate")
	}
}
func TestDrainPassiveDeletesDoNotAdvanceRepositoryTurn(t *testing.T) {
	f := &drainFake{events: []InboxEvent{{Collection: nullString("app.bsky.feed.like"), Operation: nullString("delete")}}}
	r := DrainRuntime{Processor: f, Evidence: &DrainEvidence{}, Now: time.Now}
	r.runTurn(context.Background(), f.events[0], DefaultDrainConfig())
	if f.next != 0 {
		t.Fatal("passive prefix advanced turn")
	}
}
func TestDrainReadinessDoesNotHideStaleApplication(t *testing.T) {
	s := &DrainEvidence{}
	at := time.Now()
	id := s.operationStarted(at.Add(-181 * time.Second))
	s.admissionFinished(at, nil)
	if s.Ready(at) == nil {
		t.Fatal("healthy admission hid stale event")
	}
	s.operationFinished(id, at, nil)
	if err := s.Ready(at); err != nil {
		t.Fatal(err)
	}
	if s.Ready(at.Add(61*time.Second)) == nil {
		t.Fatal("old success remained ready")
	}
}
