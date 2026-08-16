package service

import (
	"errors"
	"testing"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
)

func TestInclusiveReplayAfterRedeliversLastStagedSequence(t *testing.T) {
	if got := inclusiveReplayAfter(42); got != 41 {
		t.Fatalf("afterSeq = %d, want 41", got)
	}
	if got := inclusiveReplayAfter(0); got != 0 {
		t.Fatalf("zero afterSeq = %d", got)
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
