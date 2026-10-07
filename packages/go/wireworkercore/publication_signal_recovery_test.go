package wireworkercore

import (
	"context"
	"database/sql"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"testing"
	"time"
)

func TestPublicationSignalRecoveryUsesLoggedFenceAndKeepsReplaySeparate(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	generation, _ := newGenerationID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	initialized := at.Add(2 * time.Second)
	hasher, _ := wirecore.NewActorHasher([]byte(strings.Repeat("x", 32)))
	event := seedStandardClaim(t, db, generation, 1, "commit", "create", "2222222222222", "record-cid", map[string]any{"$type": "site.standard.document", "url": "https://" + generation + ".example/recovery", "title": "Recovery"}, at)
	event.CursorKind = "jetstream_v2_seq"
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM wire_publication_signal_recovery_jobs WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM wire_ingestion_inbox_epochs WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM appview_jetstream_checkpoints WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM wire_ingestion_inbox WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM wire_standard_record_fences WHERE source_generation=$1`, generation)
		_, _ = db.Exec(`DELETE FROM wire_items WHERE source_domain=$1`, generation+".example")
		actor, _ := hasher.Hash(event.Repository.RepoDID)
		_, _ = db.Exec(`DELETE FROM wire_active_actors WHERE actor_key_hash=$1`, actor)
	})
	if _, err := db.Exec(`UPDATE wire_ingestion_inbox SET cursor_kind='jetstream_v2_seq' WHERE source_generation=$1`, generation); err != nil {
		t.Fatal(err)
	}
	if outcome, err := (StandardRecordApplication{DB: db, Hasher: hasher}).Apply(ctx, event, at); err != nil || outcome != InboxApplied {
		t.Fatalf("projection %s %v", outcome, err)
	}
	if _, err := db.Exec(`DELETE FROM wire_signal_events WHERE source_uri=$1`, event.SourceURI()); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO wire_ingestion_inbox_epochs(environment,source_generation,initialized_at)VALUES('dev',$1,$2)`, generation, initialized); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO appview_jetstream_checkpoints(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,last_staged_seq,replay_state,replay_sealed_seq)VALUES('dev',$1,'jetstream.example','stream','fingerprint','jetstream_v2_seq',1,'replaying',1)`, generation); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO wire_publication_signal_recovery_jobs(environment,source_generation,inbox_initialized_at,maximum_source_seq)VALUES('dev',$1,$2,1)`, generation, initialized); err != nil {
		t.Fatal(err)
	}
	recovery := PublicationSignalRecovery{DB: db, Hasher: hasher, Scope: InboxScope{Environment: "dev", Generations: []string{generation}}}
	if count, err := recovery.RunBatch(ctx, initialized, 1); err != nil || count != 1 {
		t.Fatalf("batch %d %v", count, err)
	}
	if count, err := recovery.RunBatch(ctx, initialized, 1); err != nil || count != 0 {
		t.Fatalf("completion %d %v", count, err)
	}
	var complete, replay sql.NullTime
	if err := db.QueryRow(`SELECT completed_at,replay_completed_at FROM wire_publication_signal_recovery_jobs WHERE source_generation=$1`, generation).Scan(&complete, &replay); err != nil {
		t.Fatal(err)
	}
	if !complete.Valid || replay.Valid {
		t.Fatalf("replay incorrectly completed %#v %#v", complete, replay)
	}
	if _, err := db.Exec(`UPDATE appview_jetstream_checkpoints SET replay_state='live' WHERE source_generation=$1`, generation); err != nil {
		t.Fatal(err)
	}
	if _, err := recovery.RunBatch(ctx, initialized, 1); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := db.QueryRow(`SELECT count(*)FROM wire_signal_events WHERE source_uri=$1`, event.SourceURI()).Scan(&count); err != nil || count != 1 {
		t.Fatalf("signal %d %v", count, err)
	}
	if err := db.QueryRow(`SELECT replay_completed_at FROM wire_publication_signal_recovery_jobs WHERE source_generation=$1`, generation).Scan(&replay); err != nil || !replay.Valid {
		t.Fatalf("live completion %#v %v", replay, err)
	}
}
