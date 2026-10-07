package indexingworkercore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"sync/atomic"
	"testing"
	"time"
)

func TestConfigParity(t *testing.T) {
	c, err := LoadConfig(map[string]string{"INDEXING_WORKER_ROLE": "CoOrDiNaToR", "RAILWAY_REPLICA_ID": " replica ", "HOSTNAME": "ignored"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Role != Coordinator || c.Port != 8080 || c.AppViewHealthPort != 8081 || c.WireHealthPort != 8082 || c.OwnerID != "replica" || c.LeaseDuration != 30*time.Second || c.ControlEvidenceMaximumAge() != 30*time.Second {
		t.Fatalf("unexpected configuration: %+v", c)
	}
	cases := []map[string]string{{"INDEXING_WORKER_ROLE": "unknown"}, {"PORT": "65535"}, {"PORT": "0"}, {"INDEXING_APPVIEW_HEALTH_PORT": "8080"}, {"INDEXING_ROLE_LEASE_SECONDS": "NaN"}, {"INDEXING_ROLE_LEASE_SECONDS": "+Inf"}, {"INDEXING_ROLE_LEASE_SECONDS": "5"}, {"INDEXING_ROLE_LEASE_RENEW_SECONDS": "25"}, {"INDEXING_ROLE_STANDBY_RETRY_SECONDS": "0"}}
	for _, env := range cases {
		if _, ok := env["INDEXING_WORKER_ROLE"]; !ok {
			env["INDEXING_WORKER_ROLE"] = "projection"
		}
		if _, err := LoadConfig(env); err == nil {
			t.Fatalf("accepted invalid config: %v", env)
		}
	}
}
func TestEvidenceAndWatchdog(t *testing.T) {
	now := time.Unix(100, 0)
	s := NewState()
	for _, name := range laneNames {
		s.Record(name, operationscore.LeaseEvent{Phase: "standby"}, now)
	}
	if !s.HasRecentControlEvidence(now.Add(30*time.Second), 30*time.Second) || s.HasRecentControlEvidence(now.Add(31*time.Second), 30*time.Second) || s.HasRecentControlEvidence(now.Add(-time.Second), 30*time.Second) {
		t.Fatal("freshness boundary incorrect")
	}
	s.Record(AppView, operationscore.LeaseEvent{Phase: "operation_stopping"}, now)
	s.Record(AppView, operationscore.LeaseEvent{Phase: "operation_stopped"}, now.Add(20*time.Second))
	if _, ok := s.UnresponsiveLane(now.Add(29*time.Second), 30*time.Second); ok {
		t.Fatal("early watchdog")
	}
	if name, ok := s.UnresponsiveLane(now.Add(30*time.Second), 30*time.Second); !ok || name != AppView {
		t.Fatal("stopping timestamp reset")
	}
	s.Record(AppView, operationscore.LeaseEvent{Phase: "released"}, now.Add(30*time.Second))
	if _, ok := s.UnresponsiveLane(now.Add(40*time.Second), 30*time.Second); ok {
		t.Fatal("released lane remains stuck")
	}
}

type testLane struct {
	run      func(context.Context) error
	readyErr error
	starts   atomic.Int32
}

func (l *testLane) Run(ctx context.Context, _ *operationscore.RoleLeaseAuthority) error {
	l.starts.Add(1)
	return l.run(ctx)
}
func (l *testLane) Startup(context.Context) error { return l.readyErr }
func (l *testLane) Ready(context.Context) error   { return l.readyErr }
func TestIndependentRestart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var appStarts atomic.Int32
	wire := &testLane{run: func(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }}
	c, _ := LoadConfig(map[string]string{"INDEXING_WORKER_ROLE": "projection"})
	r, err := NewRuntime(c, map[LaneName]LaneFactory{AppView: func() (Lane, error) {
		count := appStarts.Add(1)
		return &testLane{run: func(ctx context.Context) error {
			if count == 1 {
				return errors.New("first host fails")
			}
			<-ctx.Done()
			return ctx.Err()
		}}, nil
	}, Wire: func() (Lane, error) { return wire, nil }}, nil)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- r.Run(ctx) }()
	deadline := time.Now().Add(2 * time.Second)
	for appStarts.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if appStarts.Load() != 2 || wire.starts.Load() != 1 {
		t.Fatalf("restarted healthy lane: app=%d wire=%d", appStarts.Load(), wire.starts.Load())
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("failed to join cancelled hosts")
	}
}
func TestStandbyHealthUsesEvidenceWithoutWorkload(t *testing.T) {
	c, _ := LoadConfig(map[string]string{"INDEXING_WORKER_ROLE": "coordinator"})
	r := &Runtime{Config: c, State: NewState(), active: map[LaneName]Lane{}}
	if r.Ready(context.Background()) == nil {
		t.Fatal("ready without evidence")
	}
	now := time.Now()
	for _, name := range laneNames {
		r.State.Record(name, operationscore.LeaseEvent{Phase: "standby"}, now)
	}
	if err := r.Ready(context.Background()); err != nil {
		t.Fatal(err)
	}
	r.State.Set(AppView, Running, now)
	if r.Ready(context.Background()) == nil {
		t.Fatal("running without host")
	}
	r.setHost(AppView, &testLane{readyErr: errors.New("database unavailable")})
	if r.Startup(context.Background()) == nil {
		t.Fatal("ignored component probe failure")
	}
}
