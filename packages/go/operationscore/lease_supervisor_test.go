package operationscore

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

type supervisorStore struct {
	validation error
	validate   func(context.Context) error
	release    func()
	renew      func(context.Context) (FencedRoleLease, error)
}

func (*supervisorStore) Acquire(context.Context, string, string, time.Duration) (*FencedRoleLease, error) {
	panic("unused")
}
func (store *supervisorStore) Validate(ctx context.Context, _ RoleLeaseAuthority) error {
	if store.validate != nil {
		return store.validate(ctx)
	}
	return store.validation
}
func (store *supervisorStore) Renew(ctx context.Context, _ RoleLeaseAuthority, _ time.Duration) (FencedRoleLease, error) {
	return store.renew(ctx)
}
func (store *supervisorStore) Release(context.Context, RoleLeaseAuthority) error {
	if store.release != nil {
		store.release()
	}
	return nil
}
func testLease() FencedRoleLease {
	now := time.Now()
	return FencedRoleLease{RoleLeaseAuthority{"test", "role", "owner", 1}, now, now.Add(30 * time.Second), now}
}
func TestSupervisorJoinsBeforeRelease(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	started, cleanup, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var released atomic.Bool
	store := &supervisorStore{release: func() { released.Store(true) }}
	leaseSupervisor := LeaseSupervisor{Store: store, Config: DefaultSupervisorConfig("role", "owner")}
	go func() {
		leaseSupervisor.runOwned(parent, testLease(), time.Now(), func(ctx context.Context, _ RoleLeaseAuthority) error {
			close(started)
			<-ctx.Done()
			<-cleanup
			return ctx.Err()
		})
		close(done)
	}()
	<-started
	cancel()
	select {
	case <-done:
		t.Fatal("returned before operation cleanup")
	case <-time.After(20 * time.Millisecond):
	}
	if released.Load() {
		t.Fatal("released before operation cleanup")
	}
	close(cleanup)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("did not join")
	}
	if !released.Load() {
		t.Fatal("did not release")
	}
}
func TestSupervisorDoesNotStartWithoutAuthority(t *testing.T) {
	for _, cancelDuringValidation := range []bool{false, true} {
		parent, cancel := context.WithCancel(context.Background())
		store := &supervisorStore{validation: ErrLeaseConflict}
		if cancelDuringValidation {
			store.validate = func(context.Context) error { cancel(); return nil }
		}
		leaseSupervisor := LeaseSupervisor{Store: store, Config: DefaultSupervisorConfig("role", "owner")}
		leaseSupervisor.runOwned(parent, testLease(), time.Now(), func(context.Context, RoleLeaseAuthority) error { t.Error("started without authority"); return nil })
		cancel()
	}
}
func TestSupervisorWatchdogCancelsBlockedRenewal(t *testing.T) {
	store := &supervisorStore{renew: func(ctx context.Context) (FencedRoleLease, error) { <-ctx.Done(); return FencedRoleLease{}, ctx.Err() }}
	config := DefaultSupervisorConfig("role", "owner")
	config.LeaseDuration = 5100 * time.Millisecond
	config.RenewInterval = 10 * time.Millisecond
	leaseSupervisor := LeaseSupervisor{Store: store, Config: config}
	start := time.Now()
	leaseSupervisor.runOwned(context.Background(), testLease(), start, func(ctx context.Context, _ RoleLeaseAuthority) error {
		<-ctx.Done()
		if !errors.Is(ctx.Err(), context.Canceled) {
			t.Error(ctx.Err())
		}
		return ctx.Err()
	})
	if time.Since(start) > time.Second {
		t.Fatal("watchdog failed to cancel independently of renewal")
	}
}

func TestSupervisorPublishesFreshControlEvidence(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	validated, renewed := false, false
	store := &supervisorStore{renew: func(context.Context) (FencedRoleLease, error) { return testLease(), nil }}
	config := DefaultSupervisorConfig("role", "owner")
	config.RenewInterval = 10 * time.Millisecond
	supervisor := LeaseSupervisor{Store: store, Config: config, OnEvent: func(event LeaseEvent) {
		switch event.Phase {
		case "validated":
			validated = true
		case "renewed":
			renewed = true
			cancel()
		}
	}}
	supervisor.runOwned(parent, testLease(), time.Now(), func(ctx context.Context, _ RoleLeaseAuthority) error { <-ctx.Done(); return ctx.Err() })
	if !validated || !renewed {
		t.Fatalf("missing control evidence: validated=%v renewed=%v", validated, renewed)
	}
}
