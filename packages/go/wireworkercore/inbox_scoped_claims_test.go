package wireworkercore

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestScopedInboxClaimsSeekAndStopBeforeUnrelatedBacklog(t *testing.T) {
	db := generationDatabase(t)
	db.SetMaxOpenConns(4)
	id, _ := newGenerationID()
	generation, unrelated := "z-scoped-"+id, "a-unrelated-"+id
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation IN($1,$2)`, generation, unrelated)
	})
	at := time.Now().UTC()
	for _, source := range []string{generation, unrelated} {
		_, err := db.Exec(`INSERT INTO wire_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,next_attempt_at) SELECT 'dev',$1,n,'fixture.example','jetstream_us','identity','did:example:'||lpad(n::text,8,'0'),'{}'::jsonb,$2,'pending',$2 FROM generate_series(1,12000)n`, source, at)
		if err != nil {
			t.Fatal(err)
		}
	}
	// An externally locked head must be skipped without admitting its successor.
	seedInbox(t, db, generation, "did:example:00000001", 12001, "pending", at, "app.bsky.feed.post", "create", `{}`)
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`SELECT seq FROM wire_ingestion_inbox WHERE environment='dev' AND source_generation=$1 AND seq=1 FOR UPDATE`, generation); err != nil {
		t.Fatal(err)
	}
	c := PostgresInboxClaims{DB: db, Scope: &InboxScope{Environment: "dev", Generations: []string{generation}}}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	rows, err := c.claimHeads(ctx, at, 2, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].Sequence != 2 || rows[1].Sequence != 3 {
		t.Fatalf("wrong scoped unlocked heads: %#v", rows)
	}
}

func TestScopedInboxClaimsMultipleGenerationsAndContinuation(t *testing.T) {
	db := generationDatabase(t)
	id, _ := newGenerationID()
	generations := []string{"a-" + id, "b-" + id}
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation IN($1,$2)`, generations[0], generations[1])
	})
	at := time.Now().UTC()
	for _, generation := range generations {
		for index, repo := range []string{"did:example:a", "did:example:b"} {
			seedInbox(t, db, generation, repo, int64(index+1), "pending", at, "app.bsky.feed.post", "create", `{}`)
		}
	}
	c := PostgresInboxClaims{DB: db, Scope: &InboxScope{Environment: "dev", Generations: []string{generations[1], generations[0], generations[0]}}}
	first, err := c.claimHeads(context.Background(), at, 1, nil)
	if err != nil || len(first) != 1 || first[0].Repository.SourceGeneration != generations[0] || first[0].Sequence != 1 {
		t.Fatalf("first generation head: %#v %v", first, err)
	}
	after := first[0].Repository
	next, err := c.claimHeads(context.Background(), at, 3, &after)
	if err != nil || len(next) != 3 {
		t.Fatalf("continuation: %#v %v", next, err)
	}
	for index, want := range []string{generations[0] + ":2", generations[1] + ":1", generations[1] + ":2"} {
		if got := fmt.Sprintf("%s:%d", next[index].Repository.SourceGeneration, next[index].Sequence); got != want {
			t.Fatalf("continuation[%d] = %s, want %s", index, got, want)
		}
	}
}
