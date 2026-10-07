package operationscore

// Runs acquisition/standby and, while owned, coordinates workload, periodic renewal, and
// an independent expiry watchdog. Any completion cancels all owned work; joining precedes
// bounded release, so an old worker cannot keep publishing after reacquisition.

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

func (leaseSupervisor *LeaseSupervisor) event(phase string, authority RoleLeaseAuthority, err error) {
	if leaseSupervisor.OnEvent != nil {
		leaseSupervisor.OnEvent(LeaseEvent{phase, authority, err})
	}
}
func sleep(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(max(0, duration))
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// Run retries acquisition until cancellation and runs at most one joined ownership epoch
// at a time.
func (leaseSupervisor *LeaseSupervisor) Run(ctx context.Context, operation func(context.Context, RoleLeaseAuthority) error) error {
	if err := leaseSupervisor.Config.Validate(); err != nil {
		return err
	}
	if leaseSupervisor.Store == nil || operation == nil {
		return ErrInvalidProgress
	}
	for ctx.Err() == nil {
		started := time.Now()
		leaseSupervisor.event("acquiring", RoleLeaseAuthority{}, nil)
		lease, err := leaseSupervisor.Store.Acquire(ctx, leaseSupervisor.Config.Role, leaseSupervisor.Config.OwnerID, leaseSupervisor.Config.LeaseDuration)
		if err != nil {
			leaseSupervisor.event("acquisition_failed", RoleLeaseAuthority{}, err)
		} else if lease == nil {
			leaseSupervisor.event("standby", RoleLeaseAuthority{}, nil)
		} else {
			leaseSupervisor.event("acquired", lease.RoleLeaseAuthority, nil)
			leaseSupervisor.runOwned(ctx, *lease, started, operation)
		}
		if err := sleep(ctx, leaseSupervisor.Config.StandbyRetryInterval); err != nil {
			return err
		}
	}
	return ctx.Err()
}
func (leaseSupervisor *LeaseSupervisor) runOwned(parent context.Context, lease FencedRoleLease, started time.Time, operation func(context.Context, RoleLeaseAuthority) error) {
	authority := lease.RoleLeaseAuthority
	// Anchor safety to request start, not response receipt: network delay must not
	// grant extra ownership time beyond the database lease.
	deadline := started.Add(min(leaseSupervisor.Config.LeaseDuration, lease.ExpiresAt.Sub(lease.UpdatedAt)) - 5*time.Second)
	var deadlineMutex sync.Mutex
	safeDeadline := func() time.Time { deadlineMutex.Lock(); defer deadlineMutex.Unlock(); return deadline }
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	err := leaseSupervisor.Store.Validate(ctx, authority)
	if err == nil {
		leaseSupervisor.event("validated", authority, nil)
		err = ctx.Err()
	}
	if err == nil && !time.Now().Before(safeDeadline()) {
		err = ErrAuthorityExpired
	}
	if err == nil {
		// Each worker reports once; buffering all reports allows cancellation/join
		// even though only the first completion determines the stopping cause.
		results := make(chan error, 3)
		var ownedWorkers sync.WaitGroup
		ownedWorkers.Add(3)
		go func() {
			defer ownedWorkers.Done()
			leaseSupervisor.event("operation_started", authority, nil)
			results <- operation(ctx, authority)
		}()
		// Expiry is watched independently so a blocked renewal cannot keep the
		// workload alive past the conservative safe deadline.
		go func() {
			defer ownedWorkers.Done()
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
			defer ownedWorkers.Done()
			scheduled := started.Add(leaseSupervisor.Config.RenewInterval)
			for ctx.Err() == nil {
				if err := sleep(ctx, time.Until(scheduled)); err != nil {
					results <- err
					return
				}
				remaining := time.Until(safeDeadline())
				if remaining <= 0 {
					results <- ErrAuthorityExpired
					return
				}
				renewed, attempt, err := leaseSupervisor.renewWithRetry(ctx, authority, safeDeadline)
				if err != nil {
					results <- err
					return
				}
				confirmed := attempt.Add(min(leaseSupervisor.Config.LeaseDuration, renewed.ExpiresAt.Sub(renewed.UpdatedAt)) - 5*time.Second)
				deadlineMutex.Lock()
				if !time.Now().Before(deadline) || !time.Now().Before(confirmed) {
					deadlineMutex.Unlock()
					results <- ErrAuthorityExpired
					return
				}
				deadline = confirmed
				deadlineMutex.Unlock()
				leaseSupervisor.event("renewed", authority, nil)
				scheduled = scheduled.Add(leaseSupervisor.Config.RenewInterval)
				if !scheduled.After(time.Now()) {
					scheduled = time.Now().Add(leaseSupervisor.Config.RenewInterval)
				}
			}
			results <- ctx.Err()
		}()
		err = <-results
		leaseSupervisor.event("operation_stopping", authority, err)
		cancel()
		// Join workload cleanup before releasing authority or entering standby.
		ownedWorkers.Wait()
		leaseSupervisor.event("operation_stopped", authority, err)
	} else {
		leaseSupervisor.event("validation_failed", authority, err)
	}
	// Cancellation must not suppress release, but cleanup remains bounded.
	releaseCtx, stop := context.WithTimeout(context.WithoutCancel(parent), 3*time.Second)
	defer stop()
	releaseErr := leaseSupervisor.Store.Release(releaseCtx, authority)
	if releaseErr != nil && !errors.Is(releaseErr, ErrLeaseConflict) {
		leaseSupervisor.event("release_failed", authority, releaseErr)
	} else {
		leaseSupervisor.event("released", authority, releaseErr)
	}
}
