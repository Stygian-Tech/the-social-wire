package corpuscore

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWireLastGoodServingPreservesSixHourBoundaryAndCurrentModeration(t *testing.T) {
	db := corpusDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	generated := now.Add(-2 * time.Hour)
	id := "bcb217b1-7d19-4120-a8af-f2bd2c5f7777"
	labeler := "did:example:stale-serving"
	keys := []string{"stale-serving-first", "stale-serving-second"}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM wire_feed_state WHERE active_generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_rank_generations WHERE generation_id=$1::uuid`, id)
		for _, key := range keys {
			db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key)
		}
		db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, labeler)
	})
	execFixture(t, db, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current) VALUES($1,'labels.example',$2,$2,0,0,TRUE)`, labeler, now)
	execFixture(t, db, `INSERT INTO wire_rank_generations(generation_id,feed_key,language_bucket,status,is_active,config_version,generated_at,committed_at,expires_at,candidate_count,ranked_count) VALUES($1::uuid,'wire','zz','committed',TRUE,'wire-v10',$2,$2,$3,2,2)`, id, generated, now.Add(-time.Hour))
	execFixture(t, db, `INSERT INTO wire_feed_state(feed_key,language_bucket,active_generation_id,updated_at) VALUES('wire','zz',$1::uuid,$2)`, id, generated)
	execFixture(t, db, `INSERT INTO wire_edition_generations(generation_id,language_bucket,continuation_ordinal) VALUES($1::uuid,'zz',2)`, id)
	execFixture(t, db, `INSERT INTO wire_edition_modules(generation_id,module_key,module_kind,position) VALUES($1::uuid,'top','top_stories',0)`, id)
	for index, key := range keys {
		execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code,author_key) VALUES($1,'https://example.com/'||$1,'example.com','Example','Story',$2,$2,$3,'zz','did:example:author')`, key, generated, now.Add(24*time.Hour))
		execFixture(t, db, `INSERT INTO wire_ranked_items(generation_id,position,canonical_key,score) VALUES($1::uuid,$2,$3,1)`, id, index, key)
		execFixture(t, db, `INSERT INTO wire_edition_module_items(generation_id,module_key,position,canonical_key) VALUES($1::uuid,'top',$2,$3)`, id, index, key)
	}
	store := &PostgreSQLStore{DB: db, Cache: redisCache(t)}
	for range 2 {
		page, err := store.Feed(ctx, FeedQuery{Language: "zz", Limit: 1}, now)
		if err != nil || page.GenerationID != id || page.Source != "stale_generation" || !page.Degraded || len(page.Rows) != 1 || !page.GeneratedAt.Equal(generated) {
			t.Fatalf("last-good page: %+v %v", page, err)
		}
		continuation, err := store.Feed(ctx, FeedQuery{Language: "zz", GenerationID: &id, StartOrdinal: 1, Limit: 1}, now)
		if err != nil || len(continuation.Rows) != 1 || continuation.Rows[0].Item.ItemID != keys[1] {
			t.Fatalf("last-good continuation: %+v %v", continuation, err)
		}
		edition, err := store.Edition(ctx, EditionQuery{Language: "zz"}, now)
		if err != nil || edition.Edition.Source != "stale_generation" || !edition.Edition.Degraded || len(edition.LeadStories) != 2 || !edition.GeneratedAt.Equal(generated) {
			t.Fatalf("last-good edition: %+v %v", edition, err)
		}
		catalog, err := store.Catalog(ctx, now)
		if err != nil || !catalog.Available || catalog.LatestGenerationID == nil || *catalog.LatestGenerationID != id {
			t.Fatalf("last-good catalog: %+v %v", catalog, err)
		}
	}
	if store.Cache.Statistics()["feed_hit"] < 2 || store.Cache.Statistics()["edition_hit"] != 1 {
		t.Fatalf("last-good pages were not cached: %+v", store.Cache.Statistics())
	}
	// Cached last-good output must still exclude a newly blocked or expired item.
	execFixture(t, db, `INSERT INTO wire_labels(canonical_key,label_key,label_value,source,applied_at,expires_at) VALUES($1,'moderation','block','test',$2,$3)`, keys[0], now, now.Add(time.Hour))
	execFixture(t, db, `UPDATE wire_items SET expires_at=$2 WHERE canonical_key=$1`, keys[1], now.Add(-time.Second))
	page, err := store.Feed(ctx, FeedQuery{Language: "zz", GenerationID: &id, Limit: 10}, now)
	if err != nil || len(page.Rows) != 0 {
		t.Fatalf("last-good retained unsafe items: %+v %v", page, err)
	}
	edition, err := store.Edition(ctx, EditionQuery{Language: "zz"}, now)
	if err != nil || len(edition.LeadStories) != 0 {
		t.Fatalf("last-good edition retained unsafe items: %+v %v", edition, err)
	}
	// The ceiling is measured from generation time, regardless of expires_at.
	execFixture(t, db, `UPDATE wire_rank_generations SET generated_at=$2,expires_at=$3 WHERE generation_id=$1::uuid`, id, now.Add(-MaximumWireGenerationAge), now.Add(time.Hour))
	if _, err := store.Feed(ctx, FeedQuery{Language: "zz", GenerationID: &id, Limit: 1}, now); !errors.Is(err, ErrCursorExpired) {
		t.Fatalf("six-hour cursor ceiling: %v", err)
	}
	if gen, err := store.activeGeneration(ctx, "zz", now); err != nil || gen != nil {
		t.Fatalf("six-hour active ceiling: %+v %v", gen, err)
	}
	catalog, err := store.loadCatalog(ctx, now)
	if err != nil || catalog.Value.LatestGenerationID != nil && *catalog.Value.LatestGenerationID == id {
		t.Fatalf("six-hour catalog ceiling: %+v %v", catalog, err)
	}
	// A last-good edition never extends baseline moderation freshness.
	execFixture(t, db, `UPDATE wire_label_refresh_state SET last_successful_at=$2 WHERE source_did=$1`, labeler, now.Add(-31*time.Minute))
	if _, err := store.Catalog(ctx, now); !errors.Is(err, ErrModerationUnavailable) {
		t.Fatalf("last-good moderation freshness: %v", err)
	}
}
