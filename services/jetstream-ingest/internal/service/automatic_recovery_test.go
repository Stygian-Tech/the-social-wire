package service

import (
	"errors"
	"fmt"
	"testing"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
)

func TestPinnedLiveFrameCodeAcceptsOnlyExactSDKDiagnostic(t *testing.T) {
	for _, code := range []string{"FutureCursor", "CursorTooOld"} {
		for _, err := range []error{errors.New("jetstream: live stream error: " + code), fmt.Errorf("outer context: %w", errors.New("jetstream: live stream error: "+code+": fixture"))} {
			if got := pinnedLiveFrameCode(err); got != code {
				t.Fatalf("exact wrapped SDK code=%q want %q", got, code)
			}
		}
	}
	for _, err := range []error{nil, errors.New("FutureCursor"), errors.New("jetstream: live stream error: FutureCursorLookalike"), errors.New("jetstream: live stream error: CursorTooOldButNotActually"), errors.New("jetstream: getSegment failed: CursorTooOld"), errors.New("arbitrary message: jetstream: live stream error: FutureCursor: fixture")} {
		if got := pinnedLiveFrameCode(err); got != "" {
			t.Fatalf("lookalike diagnostic accepted: %q %v", got, err)
		}
	}
}

func TestPureLiveProgressWatchReconnectsWithoutArchiveStats(t *testing.T) {
	now := time.Unix(1000, 0)
	watch := liveProgressWatch{pureLive: true}
	if watch.stalled(now, 100, jetstream.Stats{}, false) || watch.stalled(now.Add(liveProgressTimeout-time.Second), 100, jetstream.Stats{}, false) {
		t.Fatal("pure live stream expired early")
	}
	if !watch.stalled(now.Add(liveProgressTimeout), 100, jetstream.Stats{}, false) {
		t.Fatal("pure live source without archive stats never expired")
	}
	if watch.stalled(now.Add(liveProgressTimeout), 101, jetstream.Stats{}, false) || watch.stalled(now.Add(liveProgressTimeout+time.Minute), 101, jetstream.Stats{}, false) {
		t.Fatal("durable cursor progress did not reset pure live idle window")
	}
}
