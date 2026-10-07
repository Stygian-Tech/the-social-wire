package corpuscore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/alicebob/miniredis/v2"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"os"
	"strings"
	"testing"
	"time"
)

func corpusDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires explicitly disposable migrated PostgreSQL")
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if config.Host != "127.0.0.1" || !strings.Contains(config.Database, "test") {
		t.Fatal("requires disposable loopback database")
	}
	db := stdlib.OpenDB(*config)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { db.Close() })
	return db
}
func execFixture(t *testing.T, db *sql.DB, sql string, args ...any) {
	t.Helper()
	if _, err := db.Exec(sql, args...); err != nil {
		t.Fatal(err)
	}
}
func redisCache(t *testing.T) *PayloadCache {
	t.Helper()
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr(), MaxRetries: 0})
	t.Cleanup(func() { client.Close() })
	return NewPayloadCache(socialwireredis.RedisCommands{Client: client}, "test", "")
}
func TestPostgresAuthoritativeCacheAndCursor(t *testing.T) {
	db := corpusDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	id := "bcb217b1-7d19-4120-a8af-f2bd2c5f1111"
	key := "corpus-cache-fixture"
	labeler := "did:example:corpus-cache"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM wire_feed_state WHERE active_generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_rank_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key)
		db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, labeler)
	})
	execFixture(t, db, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current) VALUES($1,'labels.example',$2,$2,0,0,TRUE)`, labeler, now)
	execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code,author_key) VALUES($1,'https://example.com/fixture','example.com','Example','Before',$2,$2,$3,'en','did:example:original')`, key, now, now.Add(time.Hour))
	execFixture(t, db, `INSERT INTO wire_rank_generations(generation_id,feed_key,language_bucket,status,is_active,config_version,generated_at,committed_at,expires_at,candidate_count,ranked_count) VALUES($1::uuid,'wire','en','committed',TRUE,'wire-v1',$2,$2,$3,1,1)`, id, now, now.Add(time.Hour))
	execFixture(t, db, `INSERT INTO wire_feed_state(feed_key,language_bucket,active_generation_id,updated_at) VALUES('wire','en',$1::uuid,$2)`, id, now)
	execFixture(t, db, `INSERT INTO wire_ranked_items(generation_id,position,canonical_key,score) VALUES($1::uuid,0,$2,1)`, id, key)
	execFixture(t, db, `INSERT INTO wire_edition_generations(generation_id,language_bucket,continuation_ordinal) VALUES($1::uuid,'en',1)`, id)
	execFixture(t, db, `INSERT INTO wire_edition_modules(generation_id,module_key,module_kind,position) VALUES($1::uuid,'top','top_stories',0)`, id)
	execFixture(t, db, `INSERT INTO wire_edition_module_items(generation_id,module_key,position,canonical_key) VALUES($1::uuid,'top',0,$2)`, id, key)
	store := &PostgreSQLStore{DB: db, Cache: redisCache(t)}
	if err := store.Ping(ctx); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		page, err := store.Feed(ctx, FeedQuery{Language: "en", GenerationID: &id, Limit: 10}, now)
		if err != nil || len(page.Rows) != 1 || page.Rows[0].Item.Title != "Before" {
			t.Fatalf("feed %+v %v", page, err)
		}
		edition, err := store.Edition(ctx, EditionQuery{Language: "en"}, now)
		if err != nil || len(edition.LeadStories) != 1 || edition.SourceActorKeysByItemID[key] != "did:example:original" {
			t.Fatalf("edition %+v %v", edition, err)
		}
		item, err := store.Item(ctx, key, now)
		if err != nil || item == nil || item.Item.Title != "Before" {
			t.Fatalf("item %v %v", item, err)
		}
	}
	if store.Cache.Statistics()["feed_hit"] != 1 || store.Cache.Statistics()["edition_hit"] != 1 || store.Cache.Statistics()["item_hit"] != 1 {
		t.Fatal(store.Cache.Statistics())
	}
	execFixture(t, db, `UPDATE wire_items SET title='After',author_key='did:example:changed' WHERE canonical_key=$1`, key)
	item, err := store.Item(ctx, key, now)
	if err != nil || item == nil || item.Item.Title != "After" {
		t.Fatalf("edited item %v %v", item, err)
	}
	edition, err := store.Edition(ctx, EditionQuery{Language: "en"}, now)
	if err != nil || edition.SourceActorKeysByItemID[key] != "did:example:changed" || edition.LeadStories[0].Title != "After" {
		t.Fatalf("edited edition %+v %v", edition, err)
	}
	execFixture(t, db, `INSERT INTO wire_labels(canonical_key,label_key,label_value,source,applied_at,expires_at) VALUES($1,'block','block','test',$2,$3)`, key, now, now.Add(time.Hour))
	if item, err := store.Item(ctx, key, now); err != nil || item != nil {
		t.Fatalf("blocked item %v %v", item, err)
	}
	page, err := store.Feed(ctx, FeedQuery{Language: "en", GenerationID: &id, Limit: 10}, now)
	if err != nil || len(page.Rows) != 0 {
		t.Fatalf("blocked feed %+v %v", page, err)
	}
	edition, err = store.Edition(ctx, EditionQuery{Language: "en"}, now)
	if err != nil || len(edition.LeadStories) != 0 {
		t.Fatalf("blocked edition %+v %v", edition, err)
	}
	execFixture(t, db, `UPDATE wire_rank_generations SET expires_at=$2 WHERE generation_id=$1::uuid`, id, now.Add(-time.Second))
	if _, err := store.Feed(ctx, FeedQuery{Language: "en", GenerationID: &id, Limit: 10}, now); !errors.Is(err, ErrCursorExpired) {
		t.Fatal("expired cursor", err)
	}
	execFixture(t, db, `UPDATE wire_label_refresh_state SET last_successful_at=$2 WHERE source_did=$1`, labeler, now.Add(-31*time.Minute))
	if _, err := store.Catalog(ctx, now); !errors.Is(err, ErrModerationUnavailable) {
		t.Fatal("stale moderation", err)
	}
}
func TestPostgresSportsScopeAndOrdering(t *testing.T) {
	db := corpusDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	id := "bcb217b1-7d19-4120-a8af-f2bd2c5f2222"
	hockey := sportscore.ReviewedID("sport:hockey")
	ice := sportscore.ReviewedID("sport:ice-hockey")
	winter := sportscore.ReviewedID("sport:winter-sports")
	field := "corpus-sport-field"
	nhl := "corpus-comp-nhl"
	fih := "corpus-comp-fih"
	team := "corpus-team"
	athlete := "corpus-athlete"
	until := now.Add(time.Hour)
	ptr := func(s string) *string { return &s }
	catalog := []sportscore.Entity{{ID: hockey, Kind: "sport", Active: true}, {ID: ice, Kind: "sport", SportID: &hockey, Active: true}, {ID: winter, Kind: "sport", Active: true}, {ID: field, Kind: "sport", SportID: &hockey, Active: true}, {ID: nhl, Kind: "competition", SportID: &ice, Active: true}, {ID: fih, Kind: "competition", SportID: &field, Active: true}, {ID: team, Name: "Reviewed Team", Kind: "team", CompetitionIDs: []string{nhl}, Aliases: []string{"Alias Team"}, Abbreviation: ptr("RT"), ProviderIDs: map[string]string{"thesportsdb": "123"}, Active: true}, {ID: athlete, Kind: "athlete", Memberships: []sportscore.Membership{{EntityID: team, ValidFrom: now.Add(-24 * time.Hour), ValidUntil: &until}}, Active: true}}
	for i := range catalog {
		if catalog[i].CompetitionIDs == nil {
			catalog[i].CompetitionIDs = []string{}
		}
		if catalog[i].Aliases == nil {
			catalog[i].Aliases = []string{}
		}
		if catalog[i].ProviderIDs == nil {
			catalog[i].ProviderIDs = map[string]string{}
		}
	}
	payload, _ := json.Marshal(map[string]any{"entities": catalog})
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_events WHERE competition_id IN($1,$2)`, nhl, fih)
		db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, id)
	})
	execFixture(t, db, `INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active) VALUES($1::uuid,'corpus-fixture',$2,$3::jsonb,TRUE)`, id, now, string(payload))
	for _, e := range []sportscore.Event{{ID: "corpus-live", CompetitionID: nhl, Title: "Live", StartsAt: now.Add(-2 * time.Hour), Status: "in-progress", EntityIDs: []string{}, HomeName: ptr("Alias Team"), UpdatedAt: now}, {ID: "corpus-field", CompetitionID: fih, Title: "Field", StartsAt: now.Add(time.Minute), Status: "scheduled", EntityIDs: []string{}, UpdatedAt: now}, {ID: "corpus-past-membership", CompetitionID: nhl, Title: "Later", StartsAt: now.Add(2 * time.Hour), Status: "scheduled", EntityIDs: []string{team}, UpdatedAt: now}} {
		payload, _ := json.Marshal(e)
		execFixture(t, db, `INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) VALUES($1,$2,$3::jsonb,$4,$5)`, e.ID, e.CompetitionID, string(payload), now, now.Add(24*time.Hour))
	}
	store := &PostgreSQLStore{DB: db}
	events, err := store.SportsEvents(ctx, EventsQuery{Global: true, PreferredIDs: []string{winter}}, now)
	if err != nil || len(events) != 2 || events[0].ID != "corpus-live" || !stringSet(events[0].EntityIDs)[team] || events[0].HomeAbbreviation == nil || *events[0].HomeAbbreviation != "RT" {
		t.Fatalf("winter hydration %+v %v", events, err)
	}
	events, err = store.SportsEvents(ctx, EventsQuery{Global: true, PreferredIDs: []string{athlete}}, now)
	if err != nil || len(events) != 1 || events[0].ID != "corpus-live" {
		t.Fatalf("membership interval %+v %v", events, err)
	}
	events, err = store.SportsEvents(ctx, EventsQuery{Global: true, TeamIDs: []string{}}, now)
	if err != nil || len(events) != 0 {
		t.Fatalf("explicit empty teams %+v %v", events, err)
	}
	execFixture(t, db, `INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at) SELECT 'corpus-upcoming-'||n,$1,jsonb_build_object('id','corpus-upcoming-'||n,'competitionID',$1::text,'entityIDs','[]'::jsonb,'title','Future','startsAt',$2::timestamptz+n*INTERVAL '1 minute','status','scheduled','updatedAt',$2::timestamptz),$2,$3 FROM generate_series(1,600)n`, nhl, now, now.Add(24*time.Hour))
	events, err = store.SportsEvents(ctx, EventsQuery{CompetitionIDs: []string{nhl}, Global: false}, now)
	if err != nil || len(events) != 500 || events[0].ID != "corpus-live" {
		t.Fatalf("prelimit ordering count %d %v", len(events), err)
	}
}
