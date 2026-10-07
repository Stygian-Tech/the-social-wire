package wireworkercore

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHostDrainReadinessAndJoinedCancellation(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires canonical isolated PostgreSQL")
	}
	generation, _ := newGenerationID()
	host, err := NewHost(map[string]string{"DATABASE_URL": dsn, "APP_ENV": "dev", "WIRE_FEED_MODE": "api", "WIRE_ACTOR_HMAC_SECRET": strings.Repeat("x", 32), "WIRE_INBOX_SOURCE_GENERATIONS": generation}, "drain")
	if err != nil {
		t.Fatal(err)
	}
	defer host.DB.Close()
	if err = host.Startup(context.Background()); err != nil {
		t.Fatal(err)
	}
	if host.Ready(context.Background()) == nil {
		t.Fatal("unstarted drain reported ready")
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- host.Run(ctx, nil) }()
	deadline := time.Now().Add(time.Second)
	for host.Ready(context.Background()) != nil && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if err = host.Ready(context.Background()); err != nil {
		cancel()
		<-done
		t.Fatal(err)
	}
	cancel()
	select {
	case err = <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("host did not join cancellation")
	}
}

func TestCycleTopicMaterializationPreservesOutcomeAndIndependentFailures(t *testing.T) {
	for _, generated := range []bool{false, true} {
		t.Run(map[bool]string{false: "skipped", true: "generated"}[generated], func(t *testing.T) {
			outcome := CycleOutcome{}
			if generated {
				outcome.GenerationID = "generation"
			}
			financeCalls, sportsCalls := 0, 0
			failure := errors.New("finance failure")
			err := materializeCycleTopics(context.Background(), outcome, func() error { financeCalls++; return failure }, func() error { sportsCalls++; return nil })
			if sportsCalls != 1 || financeCalls != map[bool]int{false: 0, true: 1}[generated] {
				t.Fatalf("calls finance=%d sports=%d", financeCalls, sportsCalls)
			}
			if generated != errors.Is(err, failure) {
				t.Fatalf("unexpected error %v", err)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	called := false
	err := materializeCycleTopics(ctx, CycleOutcome{GenerationID: "generation"}, func() error { cancel(); return nil }, func() error { called = true; return nil })
	if called || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation did not stop next topic: %v", err)
	}
}
