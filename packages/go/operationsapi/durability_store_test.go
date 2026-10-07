package operationsapi

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"testing"
	"time"
)

func TestDurabilityCachesOnlyCensusAndKeepsAuthorityLive(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	store, _ := NewPostgresStore(tx, "dev")
	at := time.Now().UTC().Truncate(time.Microsecond)
	fixture, _ := randomUUID()
	if _, err = tx.Exec(ctx, `INSERT INTO appview_jetstream_checkpoints(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_staged_seq,last_applied_seq,replay_state,updated_at) VALUES('dev',$1,'fixture.invalid','fixture','fixture','jetstream_v2_seq',9007199254740993,9007199254740992,'live',$2)`, fixture, at); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO appview_ingestion_leases(environment,lease_name,source_generation,owner_id,fencing_token,acquired_at,lease_expires_at,updated_at) VALUES('dev',$1,$1,'fixture',1,$2,$3,$2)`, fixture, at.Add(-time.Second), at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	for seq, status := range []string{"pending", "dead_letter", "dead_letter"} {
		var dead, reconciled *time.Time
		if status == "dead_letter" {
			dead = &at
		}
		if seq == 2 {
			reconciled = &at
		}
		if _, err = tx.Exec(ctx, `INSERT INTO appview_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,payload,event_time,status,staged_at,dead_lettered_at,reconciled_at) VALUES('dev',$1,$2,'fixture.invalid','jetstream_v2_seq','sync','did:plc:fixture','{}'::jsonb,$3,$4,$5,$6,$7)`, fixture, seq, at, status, at.Add(-10*time.Second), dead, reconciled); err != nil {
			t.Fatal(err)
		}
	}
	snapshot, err := store.FetchIngestionDurabilitySnapshot(ctx, at)
	if err != nil {
		t.Fatal(err)
	}
	counts := snapshot.InboxBySourceGeneration[fixture]
	if counts.Pending != 1 || counts.DeadLetters != 1 || counts.Total != 3 || counts.OldestPendingAgeSeconds == nil || *counts.OldestPendingAgeSeconds != 10 {
		t.Fatal(counts)
	}
	found := false
	for _, checkpoint := range snapshot.Checkpoints {
		if checkpoint.SourceGeneration == fixture {
			found = true
			if checkpoint.IntakeHeartbeatAt == nil || checkpoint.LastStagedSequence == nil || *checkpoint.LastStagedSequence != 9007199254740993 {
				t.Fatal(checkpoint)
			}
		}
	}
	if !found {
		t.Fatal("checkpoint absent")
	}
	if _, err = tx.Exec(ctx, `UPDATE appview_jetstream_checkpoints SET last_applied_seq=9007199254740993 WHERE environment='dev' AND source_generation=$1`, fixture); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE appview_ingestion_leases SET released_at=$2 WHERE environment='dev' AND lease_name=$1`, fixture, at); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `UPDATE appview_ingestion_inbox SET status='applied',applied_at=$2 WHERE environment='dev' AND source_generation=$1 AND seq=0`, fixture, at); err != nil {
		t.Fatal(err)
	}
	live, err := store.FetchIngestionDurabilitySnapshot(ctx, at.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if live.InboxBySourceGeneration[fixture].Pending != 1 || *live.InboxBySourceGeneration[fixture].OldestPendingAgeSeconds != 11 {
		t.Fatal("cached observation lost aging", live.InboxBySourceGeneration[fixture])
	}
	for _, checkpoint := range live.Checkpoints {
		if checkpoint.SourceGeneration == fixture && (checkpoint.IntakeHeartbeatAt != nil || *checkpoint.LastAppliedSequence != 9007199254740993) {
			t.Fatal("authority came from cache", checkpoint)
		}
	}
	if _, err = tx.Exec(ctx, `DELETE FROM appview_ingestion_incidents WHERE environment='dev'`); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{fixture + "a", fixture + "b"} {
		if _, err = tx.Exec(ctx, `INSERT INTO appview_ingestion_incidents(environment,id,source,cursor_kind,category,status,first_detected_at,last_detected_at,updated_at,verification_evidence) VALUES('dev',$1,'jetstream','jetstream_v2_seq','fixture','open',$2,$2,$2,'{"sequence":9007199254740993,"verified":false}'::jsonb)`, id, at); err != nil {
			t.Fatal(err)
		}
	}
	page, err := store.ListIngestionIncidents(ctx, 1, nil)
	if err != nil || page.TotalCount != 2 || page.NextCursor == nil || string(page.Items[0].VerificationEvidence["sequence"]) != "9007199254740993" {
		t.Fatal(page, err)
	}
	next, err := store.ListIngestionIncidents(ctx, 1, page.NextCursor)
	if err != nil || len(next.Items) != 1 || next.Items[0].ID != fixture+"a" {
		t.Fatal(next, err)
	}
}
