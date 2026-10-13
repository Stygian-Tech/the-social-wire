package topicreadcore

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func TestModerationProofChallengeOnlyForMissingCapability(t *testing.T) {
	now := time.Now()
	transport := &moderationHTTP{}
	m := NewModerationService(fixedResolver("https://pds.example"), transport)
	auth := &gatewaycore.AuthContext{DID: "did:example:viewer", Authorization: "Bearer private"}
	if _, err := m.Require(context.Background(), auth, "", now); !errors.Is(err, ErrUpstreamProofRequired) || len(transport.calls) != 0 {
		t.Fatal("cold cache must challenge without fetching", err, transport.calls)
	}
	if _, err := m.Require(context.Background(), auth, "malformed", now); !errors.Is(err, ErrModerationUnavailable) || errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("malformed proofs must not trigger renewal", err)
	}
	if _, err := m.Require(context.Background(), auth, "p0,p1,p2,p3,p4", now); err != nil {
		t.Fatal(err)
	}
	initialCalls := len(transport.calls)
	for _, age := range []time.Duration{time.Minute, 5 * time.Minute} {
		if _, err := m.Require(context.Background(), auth, "", now.Add(age)); err != nil || len(transport.calls) != initialCalls {
			t.Fatal("usable cache must not require proofs", err, transport.calls)
		}
	}
	if _, err := m.Require(context.Background(), auth, "", now.Add(6*time.Minute)); !errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("normal refresh cadence must not silently widen to outage TTL", err)
	}
	transport.fail = true
	if _, err := m.Require(context.Background(), auth, "p0,p1,p2,p3,p4", now.Add(29*time.Minute)); err != nil {
		t.Fatal("actual refresh failure retains bounded stale fallback", err)
	}
	if _, err := m.Require(context.Background(), auth, "", now.Add(31*time.Minute)); !errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("expired cache must challenge", err)
	}
	other := &gatewaycore.AuthContext{DID: "did:example:other"}
	if _, err := m.Require(context.Background(), other, "", now); !errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("another viewer cannot reuse cache", err)
	}
	transport.fail = true
	if _, err := m.Require(context.Background(), other, "p0,p1,p2,p3,p4", now); !errors.Is(err, ErrModerationUnavailable) || errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("upstream failures must remain fail-closed", err)
	}
}

func TestCircleGraphWithoutProofUsesOnlyUsableViewerCache(t *testing.T) {
	now := time.Now()
	reader := &CircleReader{Auth: gatewaycore.AuthContext{DID: "viewer"}}
	fixture := &graphFixture{cached: &CircleGraph{ViewerDID: "viewer", GeneratedAt: now}}
	service := &CircleGraphService{Viewer: reader, Public: fixture, Activity: fixture, Cache: fixture}
	for _, age := range []time.Duration{time.Minute, 10 * time.Minute} {
		if _, err := service.Snapshot(context.Background(), "viewer", nil, now.Add(age)); err != nil {
			t.Fatal("usable graph must not fetch follows", err)
		}
	}
	if _, err := service.Snapshot(context.Background(), "viewer", nil, now.Add(11*time.Minute)); !errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("normal graph refresh must negotiate proofs", err)
	}
	fixture.err = ErrUnavailable
	service.Viewer = fixture
	if result, err := service.Snapshot(context.Background(), "viewer", nil, now.Add(time.Hour)); err != nil || !result.Stale {
		t.Fatal("actual graph outage retains bounded stale fallback", result, err)
	}
	service.Viewer = reader
	if _, err := service.Snapshot(context.Background(), "viewer", nil, now.Add(25*time.Hour)); !errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("expired graph must challenge", err)
	}
	fixture.cached = nil
	if _, err := service.Snapshot(context.Background(), "viewer", nil, now); !errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("missing graph must challenge", err)
	}
	if _, err := reader.ViewerFollows(context.Background(), "other"); !errors.Is(err, ErrUnavailable) || errors.Is(err, ErrUpstreamProofRequired) {
		t.Fatal("wrong viewer must not challenge", err)
	}
}

func TestCircleServiceRejectsAnonymousBeforeRequiringSnapshot(t *testing.T) {
	service := &CircleService{Moderation: NewModerationService(nil, nil)}
	for _, viewer := range []string{"", gatewaycore.AnonymousDiscoveryDID} {
		for _, proofs := range []string{"", "0,1,2,3,4,5"} {
			_, err := service.Edition(context.Background(), gatewaycore.AuthContext{DID: viewer}, proofs, "en", "", time.Now())
			if !errors.Is(err, ErrModerationUnavailable) || errors.Is(err, ErrUpstreamProofRequired) {
				t.Fatal("anonymous callers cannot negotiate viewer proofs", viewer, err)
			}
		}
	}
}
