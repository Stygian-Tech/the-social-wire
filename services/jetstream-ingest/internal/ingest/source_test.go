package ingest

import "testing"

func TestSourceIdentityRejectsCrossHostCursorReuse(t *testing.T) {
	source := SourceIdentity{
		Environment: "dev", Host: "jetstream.us-west.bsky.network",
		StreamNSID: "network.bsky.jetstream.subscribeEvents", FilterFingerprint: "abc",
		CursorKind: "jetstream_v2_seq", Generation: "west-v1",
	}
	checkpoint := Checkpoint{
		Host: "jetstream.us-east.bsky.network", StreamNSID: source.StreamNSID,
		FilterFingerprint: source.FilterFingerprint, CursorKind: source.CursorKind,
	}
	if err := source.ValidateCheckpoint(checkpoint); err == nil {
		t.Fatal("expected cross-host checkpoint rejection")
	}
}
