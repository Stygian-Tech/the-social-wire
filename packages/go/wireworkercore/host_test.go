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
