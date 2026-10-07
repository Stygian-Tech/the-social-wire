package indexingworkercore

import (
	"context"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"sync"
	"time"
)

// Lane exposes component health without competing for the wrapper's authority pool.
type Lane interface {
	Run(context.Context, *operationscore.RoleLeaseAuthority) error
	Startup(context.Context) error
	Ready(context.Context) error
}
type LaneFactory func() (Lane, error)

// Runtime takes externally owned authority/diagnostic resources. Domain lanes own their
// workload pools. Factories must create a fresh host on each component restart.
type Runtime struct {
	Config           Config
	State            *State
	Factories        map[LaneName]LaneFactory
	LeaseStore       operationscore.RoleLeaseStore
	OnEvent          func(LaneName, operationscore.LeaseEvent)
	OnComponentError func(LaneName, error)
	Terminate        func(LaneName)
	mu               sync.RWMutex
	active           map[LaneName]Lane
}

func NewRuntime(config Config, factories map[LaneName]LaneFactory, store operationscore.RoleLeaseStore) (*Runtime, error) {
	for _, name := range laneNames {
		if factories[name] == nil {
			return nil, fmt.Errorf("missing %s lane factory", name)
		}
	}
	if config.Role != Projection && config.Role != Coordinator {
		return nil, errors.New("invalid worker role")
	}
	if config.Role == Coordinator && store == nil {
		return nil, errors.New("coordinator requires authority store")
	}
	return &Runtime{Config: config, State: NewState(), Factories: factories, LeaseStore: store, active: map[LaneName]Lane{}}, nil
}
func (r *Runtime) setHost(name LaneName, host Lane) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if host == nil {
		delete(r.active, name)
	} else {
		r.active[name] = host
	}
}
func (r *Runtime) runHost(ctx context.Context, name LaneName, authority *operationscore.RoleLeaseAuthority) error {
	host, err := r.Factories[name]()
	if err != nil {
		return err
	}
	if host == nil {
		return errors.New("lane factory returned nil")
	}
	r.setHost(name, host)
	defer r.setHost(name, nil)
	r.State.Set(name, Running, time.Now())
	return host.Run(ctx, authority)
}
func (r *Runtime) runProjection(ctx context.Context, name LaneName) error {
	delay := 250 * time.Millisecond
	for ctx.Err() == nil {
		r.State.Set(name, Starting, time.Now())
		err := r.runHost(ctx, name, nil)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if errors.Is(err, context.Canceled) {
			return err
		}
		if err == nil {
			err = fmt.Errorf("%s component exited unexpectedly", name)
		}
		r.State.Set(name, Restarting, time.Now())
		if r.OnComponentError != nil {
			r.OnComponentError(name, err)
		}
		if err := wait(ctx, delay); err != nil {
			return err
		}
		delay = min(delay*2, 10*time.Second)
	}
	return ctx.Err()
}
func (r *Runtime) runCoordinator(ctx context.Context, name LaneName) error {
	role := "indexing.appview-coordinator"
	if name == Wire {
		role = "indexing.wire-materializer"
	}
	r.State.Set(name, Starting, time.Now())
	supervisor := operationscore.LeaseSupervisor{Store: r.LeaseStore, Config: operationscore.SupervisorConfig{Role: role, OwnerID: r.Config.OwnerID, LeaseDuration: r.Config.LeaseDuration, RenewInterval: r.Config.RenewInterval, StandbyRetryInterval: r.Config.StandbyRetryInterval}, OnEvent: func(event operationscore.LeaseEvent) {
		r.State.Record(name, event, time.Now())
		if r.OnEvent != nil {
			r.OnEvent(name, event)
		}
	}}
	return supervisor.Run(ctx, func(owned context.Context, authority operationscore.RoleLeaseAuthority) error {
		return r.runHost(owned, name, &authority)
	})
}

// Run joins all cancelled lanes. A watchdog terminates an unresponsive coordinator
// rather than releasing authority while old work remains alive.
func (r *Runtime) Run(ctx context.Context) error {
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan error, 3)
	watchdogContext, stopWatchdog := context.WithCancel(context.WithoutCancel(ctx))
	defer stopWatchdog()
	watchdogDone := make(chan struct{})
	var workers sync.WaitGroup
	for _, name := range laneNames {
		workers.Add(1)
		go func(name LaneName) {
			defer workers.Done()
			if r.Config.Role == Projection {
				results <- r.runProjection(child, name)
			} else {
				results <- r.runCoordinator(child, name)
			}
		}(name)
	}
	if r.Config.Role == Coordinator {
		go func() { defer close(watchdogDone); results <- r.watchdog(watchdogContext) }()
	} else {
		close(watchdogDone)
	}
	err := <-results
	cancel()
	workers.Wait()
	stopWatchdog()
	<-watchdogDone
	return err
}
func (r *Runtime) watchdog(ctx context.Context) error {
	for ctx.Err() == nil {
		if name, ok := r.State.UnresponsiveLane(time.Now(), 30*time.Second); ok {
			if r.Terminate != nil {
				r.Terminate(name)
			}
			return fmt.Errorf("cancelled %s lane failed to stop", name)
		}
		if err := wait(ctx, 5*time.Second); err != nil {
			return err
		}
	}
	return ctx.Err()
}
func wait(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func (r *Runtime) Startup(ctx context.Context) error { return r.probe(ctx, false) }
func (r *Runtime) Ready(ctx context.Context) error   { return r.probe(ctx, true) }
func (r *Runtime) probe(ctx context.Context, ready bool) error {
	if r.Config.Role == Coordinator && !r.State.HasRecentControlEvidence(time.Now(), r.Config.ControlEvidenceMaximumAge()) {
		return errors.New("control evidence unavailable")
	}
	phases := r.State.Snapshot()
	for _, name := range laneNames {
		phase := phases[name]
		if r.Config.Role == Coordinator && phase == Standby {
			continue
		}
		if phase != Running {
			return fmt.Errorf("%s lane is %s", name, phase)
		}
		r.mu.RLock()
		host := r.active[name]
		r.mu.RUnlock()
		if host == nil {
			return fmt.Errorf("%s lane host unavailable", name)
		}
		var err error
		if ready {
			err = host.Ready(ctx)
		} else {
			err = host.Startup(ctx)
		}
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return nil
}
