package topicreadcore

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type blockedModerationResolver struct {
	started chan struct{}
	release chan struct{}
	calls   atomic.Int32
}

func (r *blockedModerationResolver) ResolvePDS(ctx context.Context, _ string) (string, error) {
	r.calls.Add(1)
	select {
	case r.started <- struct{}{}:
	default:
	}
	select {
	case <-r.release:
		return "https://pds.example", nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func TestModerationRefreshSurvivesCancelledRequester(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	resolver := &blockedModerationResolver{started: make(chan struct{}, 2), release: make(chan struct{})}
	transport := &moderationHTTP{}
	m := NewModerationService(resolver, transport)
	auth := gatewaycore.AuthContext{DID: "did:example:viewer", Authorization: "Bearer private"}
	proofs := []string{"p0", "p1", "p2", "p3", "p4"}
	now := time.Now()
	first, stopFirst := context.WithCancel(ctx)
	defer stopFirst()
	finished := make(chan error, 1)
	go func() {
		_, err := m.RequireProofs(first, auth, proofs, now)
		finished <- err
	}()
	select {
	case <-resolver.started:
	case <-ctx.Done():
		t.Fatal("refresh did not start")
	}
	stopFirst()
	select {
	case err := <-finished:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled requester returned %v", err)
		}
	case <-ctx.Done():
		t.Fatal("cancelled requester remained blocked")
	}
	// The shared fetch remains in flight while a second feed asks for the same
	// viewer. Its result must remain moderated and be reusable by later feeds.
	go func() {
		value, err := m.RequireProofs(ctx, auth, proofs, now)
		if err == nil && value.Allows("did:example:block", "story", nil, nil) {
			err = errors.New("block policy was lost")
		}
		finished <- err
	}()
	close(resolver.release)
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("second requester did not finish")
	}
	if resolver.calls.Load() != 1 || len(transport.calls) != 6 {
		t.Fatalf("duplicate refresh: resolves=%d requests=%d", resolver.calls.Load(), len(transport.calls))
	}
}

func TestModerationRefreshCancelledContextDoesNotStartFetch(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	resolver := &blockedModerationResolver{}
	m := NewModerationService(resolver, &moderationHTTP{})
	_, err := m.RequireProofs(ctx, gatewaycore.AuthContext{DID: "did:example:viewer"}, []string{"p0", "p1", "p2", "p3", "p4"}, time.Now())
	if !errors.Is(err, context.Canceled) || resolver.calls.Load() != 0 {
		t.Fatalf("err=%v resolves=%d", err, resolver.calls.Load())
	}
}
