package operationscore

import (
	"context"
	"errors"
	"sync"
	"time"
)

// LeaseSupervisor cancels and joins ownership work before releasing or reacquiring.
// Event callbacks may run concurrently and must not block control operations.
type LeaseSupervisor struct {
	Store   RoleLeaseStore
	Config  SupervisorConfig
	OnEvent func(LeaseEvent)
}

func (s *LeaseSupervisor) event(phase string, a RoleLeaseAuthority, err error) {
	if s.OnEvent != nil {
		s.OnEvent(LeaseEvent{phase, a, err})
	}
}
func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(max(0, d))
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
func (s *LeaseSupervisor) Run(ctx context.Context, operation func(context.Context, RoleLeaseAuthority) error) error {
	if err := s.Config.Validate(); err != nil {
		return err
	}
	if s.Store == nil || operation == nil {
		return ErrInvalidProgress
	}
	for ctx.Err() == nil {
		started := time.Now()
		s.event("acquiring", RoleLeaseAuthority{}, nil)
		lease, err := s.Store.Acquire(ctx, s.Config.Role, s.Config.OwnerID, s.Config.LeaseDuration)
		if err != nil {
			s.event("acquisition_failed", RoleLeaseAuthority{}, err)
		} else if lease == nil {
			s.event("standby", RoleLeaseAuthority{}, nil)
		} else {
			s.event("acquired", lease.RoleLeaseAuthority, nil)
			s.runOwned(ctx, *lease, started, operation)
		}
		if err := sleep(ctx, s.Config.StandbyRetryInterval); err != nil {
			return err
		}
	}
	return ctx.Err()
}
func (s *LeaseSupervisor) runOwned(parent context.Context, lease FencedRoleLease, started time.Time, operation func(context.Context, RoleLeaseAuthority) error) {
	a := lease.RoleLeaseAuthority
	deadline := started.Add(min(s.Config.LeaseDuration, lease.ExpiresAt.Sub(lease.UpdatedAt)) - 5*time.Second)
	var mu sync.Mutex
	safeDeadline := func() time.Time { mu.Lock(); defer mu.Unlock(); return deadline }
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	err := s.Store.Validate(ctx, a)
	if err == nil {
		err = ctx.Err()
	}
	if err == nil && !time.Now().Before(safeDeadline()) {
		err = ErrAuthorityExpired
	}
	if err == nil {
		results := make(chan error, 3)
		var wg sync.WaitGroup
		wg.Add(3)
		go func() { defer wg.Done(); s.event("operation_started", a, nil); results <- operation(ctx, a) }()
		go func() {
			defer wg.Done()
			for ctx.Err() == nil {
				if err := sleep(ctx, time.Until(safeDeadline())); err != nil {
					results <- err
					return
				}
				if !time.Now().Before(safeDeadline()) {
					results <- ErrAuthorityExpired
					return
				}
			}
			results <- ctx.Err()
		}()
		go func() {
			defer wg.Done()
			scheduled := started.Add(s.Config.RenewInterval)
			for ctx.Err() == nil {
				if err := sleep(ctx, time.Until(scheduled)); err != nil {
					results <- err
					return
				}
				attempt := time.Now()
				remaining := time.Until(safeDeadline())
				if remaining <= 0 {
					results <- ErrAuthorityExpired
					return
				}
				renewCtx, stop := context.WithTimeout(ctx, min(3*time.Second, remaining))
				renewed, err := s.Store.Renew(renewCtx, a, s.Config.LeaseDuration)
				stop()
				if err != nil {
					results <- err
					return
				}
				confirmed := attempt.Add(min(s.Config.LeaseDuration, renewed.ExpiresAt.Sub(renewed.UpdatedAt)) - 5*time.Second)
				mu.Lock()
				if !time.Now().Before(deadline) || !time.Now().Before(confirmed) {
					mu.Unlock()
					results <- ErrAuthorityExpired
					return
				}
				deadline = confirmed
				mu.Unlock()
				scheduled = scheduled.Add(s.Config.RenewInterval)
				if !scheduled.After(time.Now()) {
					scheduled = time.Now().Add(s.Config.RenewInterval)
				}
			}
			results <- ctx.Err()
		}()
		err = <-results
		s.event("operation_stopping", a, err)
		cancel()
		wg.Wait()
		s.event("operation_stopped", a, err)
	} else {
		s.event("validation_failed", a, err)
	}
	// Cancellation must not suppress release, but cleanup remains bounded.
	releaseCtx, stop := context.WithTimeout(context.WithoutCancel(parent), 3*time.Second)
	defer stop()
	releaseErr := s.Store.Release(releaseCtx, a)
	if releaseErr != nil && !errors.Is(releaseErr, ErrLeaseConflict) {
		s.event("release_failed", a, releaseErr)
	} else {
		s.event("released", a, releaseErr)
	}
}
