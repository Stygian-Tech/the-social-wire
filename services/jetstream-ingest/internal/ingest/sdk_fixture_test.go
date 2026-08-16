package ingest

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	jetstream "github.com/bluesky-social/jetstream"
)

func TestOfficialSDKJSONMatchesSwiftGoldenFixture(t *testing.T) {
	events := []jetstream.Event{
		{
			DID: "did:plc:commit", Seq: 101, TimeUS: 1700000000000001, Kind: jetstream.KindCommit,
			Commit: &jetstream.Commit{
				Operation: jetstream.OpCreate, Collection: "site.standard.entry", Rkey: "3jcommit",
				Rev: "3kcommit", CID: "bafycommit", RecordCBOR: []byte{1, 2, 3},
				Record: map[string]any{
					"$type": "site.standard.entry", "createdAt": "2026-08-15T12:00:00Z", "title": "Fixture",
				},
			},
		},
		{
			DID: "did:plc:identity", Seq: 102, TimeUS: 1700000000000002, Kind: jetstream.KindIdentity,
			Identity: &jetstream.Identity{DID: "did:plc:identity", Handle: "identity.example", Seq: 2002, Time: "2026-08-15T12:00:00Z"},
		},
		{
			DID: "did:plc:account", Seq: 103, TimeUS: 1700000000000003, Kind: jetstream.KindAccount,
			Account: &jetstream.Account{DID: "did:plc:account", Active: false, Status: "deleted", Seq: 2003, Time: "2026-08-15T12:00:01Z"},
		},
		{
			DID: "did:plc:sync", Seq: 104, TimeUS: 1700000000000004, Kind: jetstream.KindSync,
			Sync: &jetstream.Sync{DID: "did:plc:sync", Rev: "3ksync", Seq: 2004, Time: "2026-08-15T12:00:02Z"},
		},
	}
	encoded, err := json.Marshal(events)
	if err != nil {
		t.Fatal(err)
	}
	fixturePath := filepath.Join("..", "..", "..", "..", "packages", "swift", "ThinAppViewCore", "Tests", "ThinAppViewCoreTests", "Fixtures", "jetstream-v2-go-sdk-v0.2.0-events.json")
	fixture, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(encoded, bytes.TrimSpace(fixture)) {
		t.Fatalf("official SDK JSON drifted from shared fixture\nencoded: %s\nfixture: %s", encoded, fixture)
	}
}
