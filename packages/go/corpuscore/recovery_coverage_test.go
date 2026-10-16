package corpuscore

import (
	"context"
	"testing"
	"time"
)

func TestWireCachedPagesRecheckAutomaticAndLegacyRecoveryCoverage(t *testing.T) {
	db := corpusDB(t)
	ctx := context.Background()
	var initial bool
	if err := db.QueryRow(`SELECT recovering FROM wire_publication_recovery_health`).Scan(&initial); err != nil {
		t.Fatal(err)
	}
	if initial {
		t.Skip("requires a disposable corpus without unrelated unresolved recovery")
	}
	now := time.Now().UTC().Truncate(time.Second)
	id := "bcb217b1-7d19-4120-a8af-f2bd2c5f8888"
	key, generation, labeler := "coverage-cached-item", "coverage-cached-source", "did:example:coverage-cached"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM wire_feed_state WHERE active_generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_rank_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key)
		db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, labeler)
		db.Exec(`DELETE FROM ingestion_poison_records WHERE source_generation=$1`, generation)
		db.Exec(`DELETE FROM ingestion_recovery_jobs WHERE source_generation=$1`, generation)
		db.Exec(`DELETE FROM ingestion_recovery_controllers WHERE source_generation=$1`, generation)
		db.Exec(`DELETE FROM wire_publication_signal_recovery_jobs WHERE source_generation=$1`, generation)
	})
	execFixture(t, db, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current)VALUES($1,'fixture.invalid',$2,$2,0,0,TRUE)`, labeler, now)
	execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code,author_key)VALUES($1,'https://fixture.invalid/coverage','fixture.invalid','Fixture','Story',$2,$2,$3,'qq','did:example:fixture')`, key, now, now.Add(time.Hour))
	execFixture(t, db, `INSERT INTO wire_rank_generations(generation_id,feed_key,language_bucket,status,is_active,config_version,generated_at,committed_at,expires_at,candidate_count,ranked_count)VALUES($1::uuid,'wire','qq','committed',TRUE,'wire-v10',$2,$2,$3,1,1)`, id, now, now.Add(time.Hour))
	execFixture(t, db, `INSERT INTO wire_feed_state(feed_key,language_bucket,active_generation_id,updated_at)VALUES('wire','qq',$1::uuid,$2)`, id, now)
	execFixture(t, db, `INSERT INTO wire_ranked_items(generation_id,position,canonical_key,score)VALUES($1::uuid,0,$2,1)`, id, key)
	execFixture(t, db, `INSERT INTO wire_edition_generations(generation_id,language_bucket,continuation_ordinal)VALUES($1::uuid,'qq',1)`, id)
	execFixture(t, db, `INSERT INTO wire_edition_modules(generation_id,module_key,module_kind,position)VALUES($1::uuid,'top','top_stories',0)`, id)
	execFixture(t, db, `INSERT INTO wire_edition_module_items(generation_id,module_key,position,canonical_key)VALUES($1::uuid,'top',0,$2)`, id, key)
	store := &PostgreSQLStore{DB: db, Cache: redisCache(t)}
	check := func(want bool) {
		t.Helper()
		page, err := store.Feed(ctx, FeedQuery{Language: "qq", Limit: 1}, now)
		if err != nil || page.Degraded != want || len(page.Rows) != 1 {
			t.Fatalf("cached page coverage=%t want=%t err=%v rows=%d", page.Degraded, want, err, len(page.Rows))
		}
		edition, err := store.Edition(ctx, EditionQuery{Language: "qq"}, now)
		if err != nil || edition.Degraded != want || len(edition.LeadStories) != 1 {
			t.Fatalf("cached edition coverage=%t want=%t err=%v", edition.Degraded, want, err)
		}
	}
	check(false)
	execFixture(t, db, `INSERT INTO ingestion_recovery_controllers(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,status,gap_after_seq)VALUES('dev',$1,'fixture.invalid','fixture','fixture','jetstream_v2_seq','gap_pending',100)`, generation)
	check(true)
	execFixture(t, db, `UPDATE ingestion_recovery_controllers SET status='healthy',gap_after_seq=NULL WHERE source_generation=$1`, generation)
	check(false)
	execFixture(t, db, `INSERT INTO ingestion_recovery_jobs(environment,source_generation,id,source_host,stream_nsid,filter_fingerprint,cursor_kind,after_seq,before_seq,status)VALUES('dev',$1,'fixture','fixture.invalid','fixture','fixture','jetstream_v2_seq',100,200,'pending')`, generation)
	check(true)
	execFixture(t, db, `UPDATE ingestion_recovery_jobs SET status='complete',last_staged_seq=200 WHERE source_generation=$1`, generation)
	check(false)
	execFixture(t, db, `INSERT INTO ingestion_poison_records(environment,source_generation,seq,source_host,repo_did,payload_sha256,reason)VALUES('dev',$1,150,'fixture.invalid','did:example:fixture','fixture-sha','fixture')`, generation)
	check(true)
	execFixture(t, db, `UPDATE ingestion_poison_records SET status='repaired' WHERE source_generation=$1`, generation)
	check(false)
	execFixture(t, db, `INSERT INTO wire_publication_signal_recovery_jobs(environment,source_generation,inbox_initialized_at,maximum_source_seq)VALUES('dev',$1,$2,200)`, generation, now)
	check(true)
	execFixture(t, db, `UPDATE wire_publication_signal_recovery_jobs SET replay_completed_at=$2 WHERE source_generation=$1`, generation, now)
	check(false)
	if store.Cache.Statistics()["feed_hit"] < 8 || store.Cache.Statistics()["edition_hit"] < 8 {
		t.Fatalf("test did not exercise cached presentation: %+v", store.Cache.Statistics())
	}
}
