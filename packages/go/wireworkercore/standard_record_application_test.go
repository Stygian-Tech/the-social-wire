package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func seedStandardClaim(t *testing.T, db *sql.DB, generation string, seq int64, kind, operation, revision, cid string, record map[string]any, at time.Time) InboxEvent {
	t.Helper()
	repo := "did:example:" + generation
	var payload map[string]any
	cursor := "jetstream_us"
	if kind == "snapshot" {
		cursor = "pds_record_snapshot"
		payload = map[string]any{"snapshot": map[string]any{"cid": cid, "rev": revision, "record": record}}
	} else {
		payload = map[string]any{"commit": map[string]any{"record": record}}
	}
	data, _ := json.Marshal(payload)
	token := fmt.Sprint("token-", seq)
	_, err := db.Exec(`INSERT INTO wire_ingestion_inbox(environment,source_generation,seq,source_host,cursor_kind,event_kind,repo_did,collection,operation,record_key,payload,event_time,status,next_attempt_at,lease_token,lease_owner,lease_expires_at,repo_rev,record_cid) VALUES('dev',$1,$2,'jetstream.example',$3,$4,$5,'site.standard.document',$6,'rkey',$7::jsonb,$8,'leased',$8,$9,'wire-worker',$10,$11,$12)`, generation, seq, cursor, kind, repo, operation, string(data), at, token, at.Add(120*time.Second), revision, cid)
	if err != nil {
		t.Fatal(err)
	}
	return InboxEvent{Repository: InboxRepository{"dev", generation, repo}, Sequence: seq, SourceHost: "jetstream.example", CursorKind: cursor, EventKind: kind, Collection: nullString("site.standard.document"), Operation: nullString(operation), RecordKey: nullString("rkey"), PayloadJSON: string(data), EventTime: at, LeaseToken: token, AttemptCount: 1}
}
func TestStandardApplicationSnapshotCommitAndAuthoritativeDelete(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	generation, _ := newGenerationID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	hasher, _ := wirecore.NewActorHasher([]byte(strings.Repeat("x", 32)))
	app := StandardRecordApplication{DB: db, Hasher: hasher}
	record := map[string]any{"$type": "site.standard.document", "title": "Fixture title", "url": "https://" + generation + ".example/article", "lang": "en-US", "publishedAt": at.Add(-time.Hour).Format(time.RFC3339)}
	identity := wirecore.Canonicalize(record["url"].(string))
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM wire_standard_record_fences WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey)
		hash, _ := hasher.Hash("did:example:" + generation)
		_, _ = db.Exec(`DELETE FROM wire_active_actors WHERE actor_key_hash=$1`, hash)
	})
	snapshot := seedStandardClaim(t, db, generation, 1, "snapshot", "update", "3333333333333", "same", record, at)
	if outcome, err := app.Apply(ctx, snapshot, at); err != nil || outcome != InboxApplied {
		t.Fatalf("snapshot %s %v", outcome, err)
	}
	var count int
	var signal sql.NullTime
	if err := db.QueryRow(`SELECT last_signal_at FROM wire_items WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&signal); err != nil {
		t.Fatal(err)
	}
	if signal.Valid {
		t.Fatal("snapshot gained ranking activity")
	}
	if err := db.QueryRow(`SELECT count(*) FROM wire_signal_events WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&count); err != nil || count != 0 {
		t.Fatalf("snapshot signals %d %v", count, err)
	}
	commit := seedStandardClaim(t, db, generation, 2, "commit", "create", "2222222222222", "same", record, at.Add(time.Second))
	if outcome, err := app.Apply(ctx, commit, at.Add(time.Second)); err != nil || outcome != InboxApplied {
		t.Fatalf("commit %s %v", outcome, err)
	}
	if err := db.QueryRow(`SELECT count(*) FROM wire_signal_events WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&count); err != nil || count != 1 {
		t.Fatalf("commit signals %d %v", count, err)
	}
	stale := seedStandardClaim(t, db, generation, 3, "commit", "delete", "2222222222223", "", nil, at.Add(2*time.Second))
	if outcome, err := app.Apply(ctx, stale, at.Add(2*time.Second)); err != nil || outcome != InboxTerminal {
		t.Fatalf("stale deletion %s %v", outcome, err)
	}
	current := seedStandardClaim(t, db, generation, 4, "commit", "delete", "4444444444444", "", nil, at.Add(3*time.Second))
	if outcome, err := app.Apply(ctx, current, at.Add(3*time.Second)); err != nil || outcome != InboxApplied {
		t.Fatalf("authoritative deletion %s %v", outcome, err)
	}
	if err := db.QueryRow(`SELECT count(*) FROM wire_signal_events WHERE canonical_key=$1`, identity.CanonicalKey).Scan(&count); err != nil || count != 0 {
		t.Fatalf("delete signals %d %v", count, err)
	}
}
func TestStandardApplicationRejectsForgedRetainedClaim(t *testing.T) {
	db := generationDatabase(t)
	generation, _ := newGenerationID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	record := map[string]any{"$type": "site.standard.document", "title": "Real title", "url": "https://" + generation + ".example/article"}
	event := seedStandardClaim(t, db, generation, 1, "snapshot", "update", "3333333333333", "same", record, at)
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation=$1`, generation) })
	event.PayloadJSON = strings.ReplaceAll(event.PayloadJSON, "Real title", "Forged title")
	app := StandardRecordApplication{DB: db}
	if _, err := app.Apply(context.Background(), event, at); !errorsIsMalformed(err) {
		t.Fatalf("forged claim accepted %v", err)
	}
	var status string
	if err := db.QueryRow(`SELECT status FROM wire_ingestion_inbox WHERE source_generation=$1 AND seq=1`, generation).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "leased" {
		t.Fatal("forged caller acknowledged durable row")
	}
}
func errorsIsMalformed(err error) bool { return err == ErrMalformedDocument }
