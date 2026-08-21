package ingest

import (
	"bytes"
	"testing"

	jetstream "github.com/bluesky-social/jetstream"
)

func TestPrepareBatchAcceptsArbitraryCursorJumps(t *testing.T) {
	events := []jetstream.Event{
		{DID: "did:plc:a", Seq: 10, TimeUS: 1_000_000, Kind: jetstream.KindCommit, Commit: &jetstream.Commit{Operation: jetstream.OpCreate, Collection: "site.standard.entry", Rkey: "one", Rev: "1", Record: map[string]any{"$type": "site.standard.entry"}}},
		{DID: "did:plc:a", Seq: 9_999, TimeUS: 2_000_000, Kind: jetstream.KindCommit, Commit: &jetstream.Commit{Operation: jetstream.OpDelete, Collection: "site.standard.entry", Rkey: "two", Rev: "2"}},
	}
	prepared, cursor, _, err := PrepareBatch(events, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared) != 2 || cursor != 9_999 {
		t.Fatalf("prepared=%d cursor=%d", len(prepared), cursor)
	}
}

func TestPrepareBatchOmitsDuplicateRecordCBORFromInboxPayload(t *testing.T) {
	events := []jetstream.Event{{
		DID: "did:plc:a", Seq: 5, Kind: jetstream.KindCommit,
		Commit: &jetstream.Commit{
			Operation: jetstream.OpCreate, Collection: "site.standard.entry", Rkey: "one", Rev: "1",
			Record: map[string]any{"$type": "site.standard.entry"}, RecordCBOR: []byte{1, 2, 3},
		},
	}}
	prepared, _, _, err := PrepareBatch(events, nil)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(prepared[0].Payload, []byte("record_cbor")) {
		t.Fatalf("inbox payload retained duplicate CBOR: %s", prepared[0].Payload)
	}
}

func TestPrepareBatchRejectsNonProjectableCreate(t *testing.T) {
	events := []jetstream.Event{{
		DID: "did:plc:a", Seq: 3, Kind: jetstream.KindCommit,
		Commit: &jetstream.Commit{Operation: jetstream.OpCreate, Collection: "site.standard.entry", Rkey: "one", Rev: "1", RecordCBOR: []byte{1}},
	}}
	if _, _, _, err := PrepareBatch(events, nil); err == nil {
		t.Fatal("expected missing JSON record failure")
	}
}

func TestPrepareBatchStagesLifecycleOnlyForTrackedDIDs(t *testing.T) {
	events := []jetstream.Event{
		{DID: "did:plc:tracked", Seq: 11, Kind: jetstream.KindAccount, Account: &jetstream.Account{DID: "did:plc:tracked", Active: false}},
		{DID: "did:plc:untracked", Seq: 20, Kind: jetstream.KindIdentity, Identity: &jetstream.Identity{DID: "did:plc:untracked"}},
	}
	prepared, cursor, _, err := PrepareBatch(events, map[string]struct{}{"did:plc:tracked": {}})
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared) != 1 || prepared[0].RepoDID != "did:plc:tracked" {
		t.Fatalf("prepared=%#v", prepared)
	}
	if cursor != 20 {
		t.Fatalf("checkpoint should advance over intentionally discarded lifecycle event: %d", cursor)
	}
}

func TestPrepareBatchWireStagesGlobalLifecycleEvents(t *testing.T) {
	events := []jetstream.Event{
		{DID: "did:plc:one", Seq: 11, Kind: jetstream.KindAccount, Account: &jetstream.Account{DID: "did:plc:one", Active: false}},
		{DID: "did:plc:two", Seq: 12, Kind: jetstream.KindIdentity, Identity: &jetstream.Identity{DID: "did:plc:two"}},
	}
	prepared, cursor, _, err := PrepareBatchForPipeline(events, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared) != 2 || cursor != 12 {
		t.Fatalf("prepared=%#v cursor=%d", prepared, cursor)
	}
}

func TestPrepareBatchDefersCommitScopeDecisionToStagingTransaction(t *testing.T) {
	events := []jetstream.Event{{
		DID: "did:plc:not-in-snapshot", Seq: 21, Kind: jetstream.KindCommit,
		Commit: &jetstream.Commit{
			Operation: jetstream.OpCreate, Collection: "site.standard.document",
			Rkey: "article", Rev: "rev", Record: map[string]any{"$type": "site.standard.document"},
		},
	}}
	prepared, cursor, _, err := PrepareBatch(events, map[string]struct{}{})
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared) != 1 || cursor != 21 {
		t.Fatalf("prepared=%#v cursor=%d", prepared, cursor)
	}
}

func TestPrepareBatchRejectsMismatchedEnvelope(t *testing.T) {
	events := []jetstream.Event{{DID: "did:plc:a", Seq: 1, Kind: jetstream.KindSync, Commit: &jetstream.Commit{}}}
	if _, _, _, err := PrepareBatch(events, nil); err == nil {
		t.Fatal("expected mismatched envelope error")
	}
}
