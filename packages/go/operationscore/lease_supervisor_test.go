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
func (s *supervisorStore) Validate(ctx context.Context, _ RoleLeaseAuthority) error {
	if s.validate != nil {
		return s.validate(ctx)
	}
	return s.validation
}
func (s *supervisorStore) Renew(ctx context.Context, _ RoleLeaseAuthority, _ time.Duration) (FencedRoleLease, error) {
	return s.renew(ctx)
}
func (s *supervisorStore) Release(context.Context, RoleLeaseAuthority) error {
	if s.release != nil {
		s.release()
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
	s := LeaseSupervisor{Store: store, Config: DefaultSupervisorConfig("role", "owner")}
	go func() {
		s.runOwned(parent, testLease(), time.Now(), func(ctx context.Context, _ RoleLeaseAuthority) error {
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
		s := LeaseSupervisor{Store: store, Config: DefaultSupervisorConfig("role", "owner")}
		s.runOwned(parent, testLease(), time.Now(), func(context.Context, RoleLeaseAuthority) error { t.Error("started without authority"); return nil })
		cancel()
	}
}
func TestSupervisorWatchdogCancelsBlockedRenewal(t *testing.T) {
	store := &supervisorStore{renew: func(ctx context.Context) (FencedRoleLease, error) { <-ctx.Done(); return FencedRoleLease{}, ctx.Err() }}
	config := DefaultSupervisorConfig("role", "owner")
	config.LeaseDuration = 5100 * time.Millisecond
	config.RenewInterval = 10 * time.Millisecond
	s := LeaseSupervisor{Store: store, Config: config}
	start := time.Now()
	s.runOwned(context.Background(), testLease(), start, func(ctx context.Context, _ RoleLeaseAuthority) error {
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
