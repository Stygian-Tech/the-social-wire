package service

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/config"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/health"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/store"
)

func TestInclusiveReplayAfterRedeliversLastStagedSequence(t *testing.T) {
	if got := inclusiveReplayAfter(42); got != 41 {
		t.Fatalf("afterSeq = %d, want 41", got)
	}
	if got := inclusiveReplayAfter(0); got != 0 {
		t.Fatalf("zero afterSeq = %d", got)
	}
}

func TestReplayStartUsesConfiguredLowerBoundWhenNoEventWasStaged(t *testing.T) {
	after := uint64(100)
	cfg := config.Config{BootstrapAfterSeq: &after}
	if got, replaying := replayStart(cfg, &ingest.Checkpoint{}); got != after || !replaying {
		t.Fatalf("empty checkpoint replay start = %d, %t", got, replaying)
	}
	checkpoint := &ingest.Checkpoint{LastStagedSeq: testCursor(180)}
	if got, replaying := replayStart(cfg, checkpoint); got != 179 || !replaying {
		t.Fatalf("staged checkpoint replay start = %d, %t", got, replaying)
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
	if err := requireBootstrapSeam(&ingest.Checkpoint{LastStagedSeq: testCursor(42)}, nil); err != nil {
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

func TestSubscriptionCompletionCannotBecomeLiveTail(t *testing.T) {
	before := uint64(200)
	complete := jetstream.Stats{SealedTip: before, PlannedThrough: before, ResidualGap: 0}
	if err := subscriptionEndError(nil, true, complete, &before); !errors.Is(err, errSnapshotComplete) {
		t.Fatalf("bounded completion error = %v", err)
	}
	if err := subscriptionEndError(nil, false, jetstream.Stats{}, nil); err == nil || errors.Is(err, errSnapshotComplete) {
		t.Fatalf("unbounded completion error = %v", err)
	}
	if err := subscriptionEndError(context.Canceled, true, jetstream.Stats{}, &before); err != nil {
		t.Fatalf("cancelled completion error = %v", err)
	}
}

func TestSnapshotCompletionRequiresExactSealedUpperBound(t *testing.T) {
	before := uint64(200)
	incomplete := []jetstream.Stats{
		{SealedTip: 150, PlannedThrough: 150, ResidualGap: 0},
		{SealedTip: 200, PlannedThrough: 150, ResidualGap: 50},
		{SealedTip: 200, PlannedThrough: 199, ResidualGap: 0},
	}
	for _, stats := range incomplete {
		if err := subscriptionEndError(nil, true, stats, &before); err == nil || errors.Is(err, errSnapshotComplete) {
			t.Fatalf("stats %+v incorrectly completed snapshot: %v", stats, err)
		}
	}
}

func TestDurableSnapshotCompletionMustMatchConfiguredBounds(t *testing.T) {
	after, before := uint64(100), uint64(200)
	cfg := config.Config{
		BootstrapAfterSeq: &after, ReplayBeforeSeq: &before, ReplaySnapshotOnly: true,
	}
	checkpoint := &ingest.Checkpoint{
		LastStagedSeq: testCursor(180), ReplayState: "snapshot_complete",
		ReplayAfterSeq: testCursor(after), ReplayBeforeSeq: testCursor(before),
		ReplaySealedSeq: testCursor(before),
	}
	completed, err := snapshotCheckpointComplete(cfg, checkpoint)
	if err != nil || !completed {
		t.Fatalf("exact completion = %t, %v", completed, err)
	}

	checkpoint.LastStagedSeq = testCursor(201)
	if _, err := snapshotCheckpointComplete(cfg, checkpoint); err == nil {
		t.Fatal("checkpoint beyond configured upper bound was accepted")
	}
	checkpoint.LastStagedSeq = testCursor(180)
	checkpoint.ReplaySealedSeq = testCursor(199)
	if _, err := snapshotCheckpointComplete(cfg, checkpoint); err == nil {
		t.Fatal("mismatched completed bound was accepted")
	}
	checkpoint.ReplaySealedSeq = testCursor(before)
	checkpoint.ReplayAfterSeq = testCursor(99)
	if _, err := snapshotCheckpointComplete(cfg, checkpoint); err == nil {
		t.Fatal("mismatched completed lower bound was accepted")
	}
	checkpoint.ReplayAfterSeq = testCursor(after)
	checkpoint.ReplayState = "replaying"
	completed, err = snapshotCheckpointComplete(cfg, checkpoint)
	if err != nil || completed {
		t.Fatalf("in-progress checkpoint completion = %t, %v", completed, err)
	}
	checkpoint.ReplayBeforeSeq = testCursor(199)
	if _, err := snapshotCheckpointComplete(cfg, checkpoint); err == nil {
		t.Fatal("in-progress checkpoint accepted changed upper bound for the same generation")
	}

	checkpoint.ReplayBeforeSeq = testCursor(before)
	checkpoint.LastStagedSeq = nil
	checkpoint.ReplayState = "snapshot_complete"
	checkpoint.ReplaySealedSeq = testCursor(before)
	completed, err = snapshotCheckpointComplete(cfg, checkpoint)
	if err != nil || !completed || checkpointLastStagedSeq(checkpoint) != 0 {
		t.Fatalf("empty durable completion = %t last=%d error=%v", completed, checkpointLastStagedSeq(checkpoint), err)
	}

	checkpoint.ReplayState = "live"
	if _, err := snapshotCheckpointComplete(cfg, checkpoint); err == nil {
		t.Fatal("bounded snapshot accepted live as a terminal completion state")
	}
}

func TestWireStagingBatchesBoundAdmissionAndAdvanceFilteredTail(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	events := []ingest.InboxEvent{
		{Seq: 8, Time: now.Add(8 * time.Second)},
		{Seq: 2, Time: now.Add(2 * time.Second)},
		{Seq: 5, Time: now.Add(5 * time.Second)},
	}
	batches := wireStagingBatches(events, 10, now.Add(10*time.Second), 2)
	if len(batches) != 3 {
		t.Fatalf("batches=%#v", batches)
	}
	if len(batches[0].events) != 2 || batches[0].lastSeq != 5 {
		t.Fatalf("first batch=%#v", batches[0])
	}
	if len(batches[1].events) != 1 || batches[1].lastSeq != 8 {
		t.Fatalf("second batch=%#v", batches[1])
	}
	if len(batches[2].events) != 0 || batches[2].lastSeq != 10 {
		t.Fatalf("filtered tail batch=%#v", batches[2])
	}
}

func TestWireStagingBatchesKeepNonWireSingleTransaction(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	events := []ingest.InboxEvent{{Seq: 1, Time: now}, {Seq: 2, Time: now}}
	batches := wireStagingBatches(events, 2, now, 0)
	if len(batches) != 1 || len(batches[0].events) != 2 || batches[0].lastSeq != 2 {
		t.Fatalf("batches=%#v", batches)
	}
}

func TestWireRunnerFailsClosedWithoutValidAdmissionLimiter(t *testing.T) {
	runner := NewRunner(
		config.Config{PipelineMode: config.WirePipelineMode},
		nil,
		store.Lease{},
		&health.State{},
		slog.Default(),
	)
	if err := runner.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "admission limiter") {
		t.Fatalf("runner error=%v", err)
	}
}

func testCursor(value uint64) *uint64 {
	return &value
}
