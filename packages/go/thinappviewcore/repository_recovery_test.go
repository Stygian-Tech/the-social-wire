package thinappviewcore

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestRecoveryStateDecodesSwiftDates(t *testing.T) {
	var state RecoveryState
	if err := json.Unmarshal([]byte(`{"snapshotId":"swift","pruningComplete":false,"startedAt":813456000,"collections":{},"completed":false}`), &state); err != nil {
		t.Fatal(err)
	}
	if state.StartedAt.Time.Year() != 2026 {
		t.Fatal(state.StartedAt)
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if json.Unmarshal(encoded, &decoded) != nil || decoded["startedAt"] != float64(813456000) {
		t.Fatal("Swift date encoding changed")
	}
}
func TestPostgresRecoveryCursorAndPruneAreFenced(t *testing.T) {
	db := inboxDatabase(t)
	ctx := context.Background()
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	env := "go-recovery-" + nonce
	did := "did:plc:" + nonce
	at := time.Now().UTC().Truncate(time.Microsecond)
	scope := RecoveryContext{Environment: env, SourceGeneration: "gen", Sequence: 1, RepoDID: did, WorkerID: "fixture", LeaseToken: "token"}
	t.Cleanup(func() {
		db.Exec("DELETE FROM appview_repository_recovery_records WHERE environment=$1", env)
		db.Exec("DELETE FROM appview_ingestion_inbox WHERE environment=$1", env)
		db.Exec("DELETE FROM content_items WHERE author_did=$1", did)
	})
	if _, err := db.Exec(`INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,lease_owner,lease_token,lease_expires_at)VALUES($1,'gen',1,'fixture','jetstream_v2_seq','sync',$2,'{}',$3,'leased','fixture','token',$4)`, env, did, at, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	store := RecoveryStore{DB: db}
	state, err := store.Load(ctx, scope)
	if err != nil {
		t.Fatal(err)
	}
	content := ContentStore{DB: db}
	seen := "at://" + did + "/site.standard.document/seen"
	for _, key := range []string{"seen", "missing", "newer"} {
		indexed := at.Add(-time.Second)
		if key == "newer" {
			indexed = state.StartedAt.Add(time.Second)
		}
		if err := content.Upsert(ctx, IndexedContentItem{URI: "at://" + did + "/site.standard.document/" + key, CID: "fixture", AuthorDID: did, Collection: "site.standard.document", CreatedAt: at, IndexedAt: indexed, ExpiresAt: at.Add(time.Hour), Render: ContentRenderFields{Title: key, PublishedAt: at.Format(time.RFC3339)}}); err != nil {
			t.Fatal(err)
		}
	}
	for _, collection := range []string{"site.standard.document", "site.standard.entry"} {
		state.Collections[collection] = RecoveryCollection{Complete: true, SeenCursors: []string{}}
	}
	state, err = store.Save(ctx, scope, state, []string{seen}, true)
	if err != nil {
		t.Fatal(err)
	}
	if !state.Completed {
		t.Fatal("complete bounded recovery")
	}
	if exists, err := content.Exists(ctx, "at://"+did+"/site.standard.document/missing"); err != nil || exists {
		t.Fatal("missing snapshot record was retained")
	}
	for _, key := range []string{"seen", "newer"} {
		if exists, err := content.Exists(ctx, "at://"+did+"/site.standard.document/"+key); err != nil || !exists {
			t.Fatal("snapshot/concurrent record lost")
		}
	}
	stale := scope
	stale.LeaseToken = "old"
	if _, err := store.Load(ctx, stale); !errors.Is(err, ErrStaleInboxLease) {
		t.Fatalf("stale recovery owner %v", err)
	}
}
