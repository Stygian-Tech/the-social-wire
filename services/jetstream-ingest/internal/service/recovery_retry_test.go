package service

import (
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestRecoveryRetryPressureIncreasesUntilDurableCursorAdvances(t *testing.T) {
	retry := newRecoveryRetryBackoff(time.Second, 8*time.Second)
	for index, want := range []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 8 * time.Second} {
		if got := retry.next(false); got != want {
			t.Fatalf("failure %d delay=%s want=%s", index, got, want)
		}
	}
	prior := uint64(100)
	for _, checkpoint := range []*ingest.Checkpoint{nil, {}, {LastStagedSeq: &prior}} {
		if recoveryCursorProgressed(&prior, checkpoint) {
			t.Fatal("transport success or unchanged durable cursor reset retry pressure")
		}
	}
	advanced := uint64(120)
	if !recoveryCursorProgressed(&prior, &ingest.Checkpoint{LastStagedSeq: &advanced}) {
		t.Fatal("committed burst prefix was ignored")
	}
	if got := retry.next(true); got != time.Second {
		t.Fatalf("durable progress did not reset delay: %s", got)
	}
	if got := retry.next(false); got != 2*time.Second {
		t.Fatalf("next failure did not resume exponential pressure: %s", got)
	}
}
