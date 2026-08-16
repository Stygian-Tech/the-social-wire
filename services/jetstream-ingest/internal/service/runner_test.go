package service

import (
	"errors"
	"testing"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestInclusiveReplayAfterRedeliversLastStagedSequence(t *testing.T) {
	if got := inclusiveReplayAfter(42); got != 41 {
		t.Fatalf("afterSeq = %d, want 41", got)
	}
	if got := inclusiveReplayAfter(0); got != 0 {
		t.Fatalf("zero afterSeq = %d", got)
	}
}

func TestRequireBootstrapSeamFailsClosedForNewGeneration(t *testing.T) {
	if err := requireBootstrapSeam(nil, nil); err == nil {
		t.Fatal("expected a new generation without an explicit seam to fail")
	}
	bootstrap := uint64(41)
	if err := requireBootstrapSeam(nil, &bootstrap); err != nil {
		t.Fatalf("explicit bootstrap seam rejected: %v", err)
	}
	if err := requireBootstrapSeam(&ingest.Checkpoint{LastStagedSeq: 42}, nil); err != nil {
		t.Fatalf("durable checkpoint rejected: %v", err)
	}
}

func TestLatestProgressTimeUsesDurableCheckpointAcrossRestarts(t *testing.T) {
	fallback := time.Unix(300, 0).UTC()
	lastStagedAt := time.Unix(100, 0).UTC()
	replayLastProgressAt := time.Unix(200, 0).UTC()
	if got := latestProgressTime(lastStagedAt, replayLastProgressAt, fallback); !got.Equal(replayLastProgressAt) {
		t.Fatalf("latest progress = %s, want %s", got, replayLastProgressAt)
	}
	if got := latestProgressTime(time.Time{}, time.Time{}, fallback); !got.Equal(fallback) {
		t.Fatalf("brand-new fallback = %s, want %s", got, fallback)
	}
}

func TestIncidentClassification(t *testing.T) {
	if got := classifyIncident(errors.New("websocket: ConsumerTooSlow")); got != "consumer_too_slow" {
		t.Fatalf("ConsumerTooSlow category = %q", got)
	}
	if got := classifyIncident(jetstream.ErrFatal); got != "fatal_stream" {
		t.Fatalf("fatal category = %q", got)
	}
}
