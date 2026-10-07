package thinappviewcore

import (
	"context"
	"database/sql"
	"errors"
	_ "github.com/jackc/pgx/v5/stdlib"
	"os"
	"testing"
	"time"
)

// Never consult DATABASE_URL: this suite may only use an explicitly supplied
// disposable database with the canonical repository migrations already applied.
func inboxDatabase(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL to a disposable, canonically migrated PostgreSQL database")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}
func TestPostgresInboxFIFOAndStaleLease(t *testing.T) {
	db := inboxDatabase(t)
	ctx := context.Background()
	store := InboxStore{DB: db}
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	env := "go-appview-" + nonce
	gen := "generation"
	did := "did:plc:" + nonce
	viewer := "did:plc:viewer" + nonce
	at := time.Now().UTC().Truncate(time.Microsecond)
	t.Cleanup(func() {
		db.Exec("DELETE FROM appview_ingestion_inbox WHERE environment=$1", env)
		db.Exec("DELETE FROM appview_publication_scopes WHERE viewer_did=$1", viewer)
	})
	if _, err := db.Exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did) VALUES($1,'fixture',$2)`, viewer, did); err != nil {
		t.Fatal(err)
	}
	for _, seq := range []int64{1, 2} {
		if _, err := db.Exec(`INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,collection,operation,payload,event_time,next_attempt_at) VALUES($1,$2,$3,'fixture','jetstream_v2_seq','commit',$4,'site.standard.document','create','{}',$5,$5)`, env, gen, seq, did, at); err != nil {
			t.Fatal(err)
		}
	}
	first, err := store.Claim(ctx, env, gen, "first", 10, at.Add(time.Second), at)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 1 || first[0].Sequence != 1 {
		t.Fatalf("per-repository FIFO: %+v", first)
	}
	blocked, err := store.Claim(ctx, env, gen, "second", 10, at.Add(time.Minute), at)
	if err != nil {
		t.Fatal(err)
	}
	if len(blocked) != 0 {
		t.Fatal("unexpired repository claim must block later events")
	}
	replacement, err := store.Claim(ctx, env, gen, "second", 10, at.Add(time.Minute), at.Add(2*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(replacement) != 1 || replacement[0].Sequence != 1 || replacement[0].LeaseToken == first[0].LeaseToken {
		t.Fatal("expired lease must be replaced with a fresh fence")
	}
	if err := store.Applied(ctx, first[0], "first", at.Add(time.Hour), at); !errors.Is(err, ErrStaleInboxLease) {
		t.Fatalf("stale acknowledgement: %v", err)
	}
	if err := store.Applied(ctx, replacement[0], "second", at.Add(time.Hour), at.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	next, err := store.Claim(ctx, env, gen, "second", 10, at.Add(time.Minute), at.Add(3*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(next) != 1 || next[0].Sequence != 2 {
		t.Fatal("acknowledgement must unblock the next repository event")
	}
}
