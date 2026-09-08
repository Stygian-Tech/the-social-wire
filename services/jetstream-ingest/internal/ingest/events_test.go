package ingest

import (
	"bytes"
	"encoding/json"
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

func TestPrepareBatchWireStagesBothAccountStates(t *testing.T) {
	events := []jetstream.Event{
		{DID: "did:plc:one", Seq: 11, Kind: jetstream.KindAccount, Account: &jetstream.Account{DID: "did:plc:one", Active: false}},
		{DID: "did:plc:two", Seq: 12, Kind: jetstream.KindIdentity, Identity: &jetstream.Identity{DID: "did:plc:two"}},
		{DID: "did:plc:three", Seq: 13, Kind: jetstream.KindAccount, Account: &jetstream.Account{DID: "did:plc:three", Active: true}},
		{DID: "did:plc:four", Seq: 14, Kind: jetstream.KindSync, Sync: &jetstream.Sync{DID: "did:plc:four", Rev: "rev"}},
	}
	prepared, cursor, _, err := PrepareBatchForPipeline(events, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared) != 2 || prepared[0].RepoDID != "did:plc:one" || prepared[1].RepoDID != "did:plc:three" || cursor != 14 {
		t.Fatalf("prepared=%#v cursor=%d", prepared, cursor)
	}
}

func TestPrepareWireAccountReactivationPrecedesLaterRecommendation(t *testing.T) {
	const did = "did:plc:reactivated"
	events := []jetstream.Event{
		{DID: did, Seq: 101, TimeUS: 1_000_001, Kind: jetstream.KindAccount, Account: &jetstream.Account{DID: did, Active: false}},
		{DID: did, Seq: 102, TimeUS: 1_000_002, Kind: jetstream.KindAccount, Account: &jetstream.Account{DID: did, Active: true}},
		{DID: did, Seq: 103, TimeUS: 1_000_003, Kind: jetstream.KindCommit, Commit: &jetstream.Commit{
			Operation: jetstream.OpCreate, Collection: "site.standard.graph.recommend", Rkey: "after-reactivation", Rev: "3m22222222224",
			Record: map[string]any{"$type": "site.standard.graph.recommend", "document": "at://did:plc:author/site.standard.document/article"},
		}},
	}
	prepared, cursor, eventTime, err := PrepareBatchForPipeline(events, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared) != 3 || cursor != 103 || eventTime.UnixMicro() != 1_000_003 {
		t.Fatalf("reactivation must survive before recommendation: rows=%d cursor=%d time=%s", len(prepared), cursor, eventTime)
	}
	for index, expectedActive := range []bool{false, true} {
		if prepared[index].Seq != uint64(101+index) || prepared[index].Kind != "account" || prepared[index].RepoDID != did {
			t.Fatalf("account event order changed: %#v", prepared[index])
		}
		var payload struct {
			Account struct {
				Active bool `json:"active"`
			} `json:"account"`
		}
		if err := json.Unmarshal(prepared[index].Payload, &payload); err != nil {
			t.Fatal(err)
		}
		if payload.Account.Active != expectedActive {
			t.Fatalf("account active=%t want %t", payload.Account.Active, expectedActive)
		}
	}
	if prepared[2].Seq != 103 || prepared[2].Collection == nil || *prepared[2].Collection != "site.standard.graph.recommend" {
		t.Fatalf("recommendation did not follow reactivation: %#v", prepared[2])
	}
}

func TestPrepareBatchWireFiltersOnlyLinklessPostCreates(t *testing.T) {
	collection := "app.bsky.feed.post"
	events := []jetstream.Event{
		{DID: "did:plc:plain", Seq: 20, Kind: jetstream.KindCommit, Commit: &jetstream.Commit{
			Operation: jetstream.OpCreate, Collection: collection, Rkey: "plain", Rev: "one",
			Record: map[string]any{"$type": collection, "text": "No external article"},
		}},
		{DID: "did:plc:linked", Seq: 21, Kind: jetstream.KindCommit, Commit: &jetstream.Commit{
			Operation: jetstream.OpCreate, Collection: collection, Rkey: "linked", Rev: "one",
			Record: map[string]any{"$type": collection, "embed": map[string]any{
				"external": map[string]any{"uri": "https://publisher.example/story"},
			}},
		}},
		{DID: "did:plc:linked", Seq: 22, Kind: jetstream.KindCommit, Commit: &jetstream.Commit{
			Operation: jetstream.OpUpdate, Collection: collection, Rkey: "linked", Rev: "two",
			Record: map[string]any{"$type": collection, "text": "Link removed"},
		}},
		{DID: "did:plc:linked", Seq: 23, Kind: jetstream.KindCommit, Commit: &jetstream.Commit{
			Operation: jetstream.OpDelete, Collection: collection, Rkey: "linked", Rev: "three",
		}},
	}
	prepared, cursor, _, err := PrepareBatchForPipeline(events, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if cursor != 23 {
		t.Fatalf("checkpoint should advance over filtered post: %d", cursor)
	}
	if len(prepared) != 3 {
		t.Fatalf("prepared=%#v", prepared)
	}
	for index, sequence := range []uint64{21, 22, 23} {
		if prepared[index].Seq != sequence {
			t.Fatalf("prepared sequences=%v", []uint64{prepared[0].Seq, prepared[1].Seq, prepared[2].Seq})
		}
	}
}

func TestWirePostLinkDetectionMatchesWorkerURLShape(t *testing.T) {
	if !containsHTTPURL(map[string]any{"facets": []any{
		map[string]any{"features": []any{map[string]any{"uri": "https://example.com/a"}}},
	}}) {
		t.Fatal("expected nested HTTPS URI")
	}
	for _, record := range []any{
		map[string]any{"uri": "at://did:plc:author/app.bsky.feed.post/one"},
		map[string]any{"url": "ftp://example.com/file"},
		map[string]any{"text": "https://example.com is not a structured link"},
	} {
		if containsHTTPURL(record) {
			t.Fatalf("unexpected public HTTP URL in %#v", record)
		}
	}
}

func BenchmarkPrepareWireBatchFiltersLinklessPosts(b *testing.B) {
	events := make([]jetstream.Event, 1_000)
	for index := range events {
		events[index] = jetstream.Event{
			DID: "did:plc:linkless", Seq: uint64(index + 1), Kind: jetstream.KindCommit,
			Commit: &jetstream.Commit{
				Operation: jetstream.OpCreate, Collection: "app.bsky.feed.post",
				Rkey: "post", Rev: "rev",
				Record: map[string]any{"$type": "app.bsky.feed.post", "text": "No link"},
			},
		}
	}
	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		prepared, cursor, _, err := PrepareBatchForPipeline(events, nil, true)
		if err != nil {
			b.Fatal(err)
		}
		if len(prepared) != 0 || cursor != 1_000 {
			b.Fatalf("prepared=%d cursor=%d", len(prepared), cursor)
		}
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
