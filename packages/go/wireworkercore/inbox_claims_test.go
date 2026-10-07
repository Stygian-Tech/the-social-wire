package wireworkercore

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"
)

func seedInbox(t *testing.T, db *sql.DB, generation, repo string, sequence int64, status string, retry time.Time, collection, operation, payload string) {
	t.Helper()
	var token, owner any
	var expiry any
	if status == "leased" {
		token = "old-token"
		owner = "prior-worker"
		expiry = retry
	}
	_, err := db.Exec(`INSERT INTO wire_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,collection,operation,record_key,payload,event_time,status,next_attempt_at,lease_token,lease_owner,lease_expires_at) VALUES('dev',$1,$2,'jetstream.example','jetstream_us','commit',$3,$4,$5,'rkey',$6::jsonb,$7,$8,$9,$10,$11,$12)`, generation, sequence, repo, collection, operation, payload, time.Now().UTC(), status, retry, token, owner, expiry)
	if err != nil {
		t.Fatal(err)
	}
}
func TestInboxRepositoryBarriersPassivePrefixAndLeaseRecovery(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	at := time.Now().UTC()
	generation, _ := newGenerationID()
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation=$1`, generation) })
	c := PostgresInboxClaims{DB: db, Scope: &InboxScope{Environment: "dev", Generations: []string{generation}}, BatchSize: 1000, Concurrency: 4}
	seedInbox(t, db, generation, "did:example:blocked", 1, "retry", at.Add(time.Hour), "app.bsky.feed.post", "create", `{"commit":{"record":{}}}`)
	seedInbox(t, db, generation, "did:example:blocked", 2, "pending", at.Add(-time.Second), "app.bsky.feed.post", "create", `{"commit":{"record":{}}}`)
	seedInbox(t, db, generation, "did:example:leased", 3, "leased", at.Add(time.Hour), "app.bsky.feed.post", "create", `{"commit":{"record":{}}}`)
	seedInbox(t, db, generation, "did:example:leased", 4, "pending", at.Add(-time.Second), "app.bsky.feed.post", "create", `{"commit":{"record":{}}}`)
	seedInbox(t, db, generation, "did:example:ready", 5, "pending", at.Add(-time.Second), "app.bsky.feed.post", "create", `{"commit":{"record":{}}}`)
	seedInbox(t, db, generation, "did:example:passive", 6, "pending", at.Add(-time.Second), "app.bsky.feed.like", "delete", `{}`)
	seedInbox(t, db, generation, "did:example:passive", 7, "pending", at.Add(-time.Second), "app.bsky.feed.repost", "delete", `{}`)
	seedInbox(t, db, generation, "did:example:passive", 8, "pending", at.Add(-time.Second), "app.bsky.feed.post", "create", `{"commit":{"record":{}}}`)
	batch, err := c.ClaimWork(ctx, at, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(batch.Events) != 3 {
		t.Fatalf("wrong admitted count: %#v", batch.Events)
	}
	for _, event := range batch.Events {
		if event.Repository.RepoDID == "did:example:blocked" || event.Repository.RepoDID == "did:example:leased" {
			t.Fatal("ordering barrier bypassed")
		}
	}
	if batch.Events[0].Sequence != 6 || batch.Events[1].Sequence != 7 {
		t.Fatalf("passive prefix missing %#v", batch.Events)
	}
	var ready InboxEvent
	for _, event := range batch.Events {
		if event.Sequence == 5 {
			ready = event
		}
	}
	if _, err = db.Exec(`UPDATE wire_ingestion_inbox SET lease_token='replacement' WHERE source_generation=$1 AND seq=5`, generation); err != nil {
		t.Fatal(err)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := FinishInbox(ctx, tx, ready, "applied", at, nil, at)
	if err != nil {
		t.Fatal(err)
	}
	if accepted {
		t.Fatal("stale lease acknowledged")
	}
	_ = tx.Rollback()
	if _, err = db.Exec(`UPDATE wire_ingestion_inbox SET lease_expires_at=$2 WHERE source_generation=$1 AND seq=3`, generation, at.Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	claimed, err := c.ClaimNext(ctx, InboxRepository{"dev", generation, "did:example:leased"}, at)
	if err != nil {
		t.Fatal(err)
	}
	if claimed == nil || claimed.Sequence != 3 || claimed.LeaseToken == "old-token" {
		t.Fatalf("did not reclaim expired head %#v", claimed)
	}
}
func TestUnresolvedPassiveReferenceAckHonorsRepositoryHead(t *testing.T) {
	db := generationDatabase(t)
	generation, _ := newGenerationID()
	at := time.Now().UTC()
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation=$1`, generation) })
	payload := fmt.Sprintf(`{"commit":{"record":{"subject":{"uri":"at://missing/%s"}}}}`, generation)
	seedInbox(t, db, generation, "did:example:ready", 1, "pending", at.Add(-time.Second), "app.bsky.feed.like", "create", payload)
	seedInbox(t, db, generation, "did:example:blocked", 2, "retry", at.Add(time.Hour), "app.bsky.feed.post", "create", `{}`)
	seedInbox(t, db, generation, "did:example:blocked", 3, "pending", at.Add(-time.Second), "app.bsky.feed.like", "create", payload)
	c := PostgresInboxClaims{DB: db, Scope: &InboxScope{Environment: "dev", Generations: []string{generation}}, BatchSize: 1000, Concurrency: 4}
	batch, err := c.ClaimWork(context.Background(), at, 4, nil)
	if err != nil {
		t.Fatal(err)
	}
	if batch.PassiveApplied != 1 || len(batch.Events) != 0 {
		t.Fatalf("wrong passive progress %#v", batch)
	}
}
