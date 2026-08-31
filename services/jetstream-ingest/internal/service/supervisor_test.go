package service

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestSupervisorRestartsFailedLaneWithoutStoppingSibling(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var failedCalls atomic.Int32
	var siblingStarted atomic.Bool
	siblingRelease := make(chan struct{})

	supervisor := Supervisor{
		RestartMinDelay: time.Millisecond,
		RestartMaxDelay: 2 * time.Millisecond,
		Lanes: []SupervisedLane{
			{
				Name: "appview",
				Run: func(context.Context) error {
					if failedCalls.Add(1) == 1 {
						return assertionError("startup failed")
					}
					cancel()
					return nil
				},
			},
			{
				Name: "wire",
				Run: func(ctx context.Context) error {
					siblingStarted.Store(true)
					select {
					case <-ctx.Done():
					case <-siblingRelease:
					}
					return nil
				},
			},
		},
	}

	done := make(chan struct{})
	go func() {
		supervisor.Run(ctx)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("supervisor did not stop after cancellation")
	}
	if failedCalls.Load() < 2 {
		t.Fatalf("failed lane calls = %d, want restart", failedCalls.Load())
	}
	if !siblingStarted.Load() {
		t.Fatal("sibling lane never started")
	}
}

type assertionError string

func (e assertionError) Error() string { return string(e) }
