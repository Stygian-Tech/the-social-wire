package topicworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func topicDB(t *testing.T) *sql.DB {
	t.Helper()
	url := os.Getenv("SOCIALWIRE_GO_TOPICS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set isolated SOCIALWIRE_GO_TOPICS_TEST_DATABASE_URL")
	}
	db, err := sql.Open("pgx", url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := db.Ping(); err != nil {
		t.Fatal(err)
	}
	return db
}
func exec(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatal(err)
	}
}
func TestTopicPostgresProjectionGenerationAndFences(t *testing.T) {
	db := topicDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	env := map[string]string{"FINANCE_FEED_MODE": "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true", "SPORTS_FEED_MODE": "visible", "FINANCE_OPENFIGI_IDS": ""}
	worker, err := NewWorker(db, env)
	if err != nil {
		t.Fatal(err)
	}
	store := operationscore.PostgresRoleLeaseStore{DB: db, Environment: "dev"}
	lease, err := store.Acquire(ctx, "indexing.wire-materializer", "topic-test", 30*time.Second)
	if err != nil || lease == nil {
		t.Fatalf("lease %v", err)
	}
	t.Cleanup(func() { store.Release(ctx, lease.RoleLeaseAuthority) })
	exec(t, db, `DELETE FROM finance_article_analysis`)
	exec(t, db, `DELETE FROM sports_article_analysis`)
	exec(t, db, `DELETE FROM finance_generations`)
	exec(t, db, `DELETE FROM sports_generations`)
	exec(t, db, `DELETE FROM finance_catalog_snapshots`)
	exec(t, db, `DELETE FROM sports_catalog_snapshots`)
	exec(t, db, `DELETE FROM finance_instruments`)
	exec(t, db, `DELETE FROM sports_entities`)
	exec(t, db, `DELETE FROM wire_items WHERE canonical_key LIKE 'topic-test:%'`)
	if err := worker.Materialize(ctx, &lease.RoleLeaseAuthority, now); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ key, title string }{{"finance", "Technology industry semiconductor supply and revenue rise"}, {"sports", "Los Angeles Lakers win NBA championship"}, {"unrelated", "Beautiful holiday celebrates music and architecture"}}
	for _, entry := range cases {
		key := "topic-test:" + entry.key
		exec(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,language_code,provenance,published_at,first_seen_at,last_seen_at,source_confidence,eligible,expires_at,updated_at,target_kind,commercial_class,commercial_score)VALUES($1,$2,'example.test','Publisher',$3,'en','["standard_site"]'::jsonb,$4,$4,$4,.9,TRUE,$5,$4,'standard_site_document','normal',0)`, key, "https://example.test/"+entry.key, entry.title, now.Add(-time.Hour), now.Add(48*time.Hour))
	}
	if err := worker.Project(ctx, now); err != nil {
		t.Fatal(err)
	}
	var financePayload, sportsPayload []byte
	if err := db.QueryRow(`SELECT payload FROM finance_article_analysis WHERE canonical_key='topic-test:finance'`).Scan(&financePayload); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT payload FROM sports_article_analysis WHERE canonical_key='topic-test:sports'`).Scan(&sportsPayload); err != nil {
		t.Fatal(err)
	}
	var finance financecore.ArticleAnalysis
	var sports sportscore.ArticleAnalysis
	if err := json.Unmarshal(financePayload, &finance); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(sportsPayload, &sports); err != nil {
		t.Fatal(err)
	}
	if !finance.Eligible || !sports.Eligible {
		t.Fatalf("eligibility finance=%v sports=%v", finance.Eligible, sports.Eligible)
	}
	if err := worker.Materialize(ctx, &lease.RoleLeaseAuthority, now); err != nil {
		t.Fatal(err)
	}
	for _, topic := range []string{"finance", "sports"} {
		var count int
		if err := db.QueryRow(`SELECT count(*) FROM ` + topic + `_generations WHERE is_active=TRUE AND language='en'`).Scan(&count); err != nil || count != 1 {
			t.Fatalf("%s active count %d err %v", topic, count, err)
		}
		var payload []byte
		if err := db.QueryRow(`SELECT payload FROM ` + topic + `_generations WHERE is_active=TRUE AND language='en'`).Scan(&payload); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(payload), "topic-test:"+topic) {
			t.Fatalf("missing generated %s story %s", topic, payload)
		}
	}
	stale := lease.RoleLeaseAuthority
	stale.FencingToken++
	if err := worker.materializeFinance(ctx, &stale, now); err == nil {
		t.Fatal("stale publication accepted")
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM finance_generations WHERE is_active=TRUE`).Scan(&count); err != nil || count != 1 {
		t.Fatal("stale publication changed pointer")
	}
	exec(t, db, `UPDATE wire_items SET title='A changed unrelated travel headline',updated_at=$1 WHERE canonical_key='topic-test:sports'`, now.Add(time.Second))
	if err := worker.Project(ctx, now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	var eligible bool
	if err := db.QueryRow(`SELECT (payload->>'eligible')::boolean FROM sports_article_analysis WHERE canonical_key='topic-test:sports'`).Scan(&eligible); err != nil || eligible {
		t.Fatalf("stale eligibility retained: %v %v", eligible, err)
	}
}

func TestTopicProjectorFingerprintCatalogAndAdvisoryFences(t *testing.T) {
	db := topicDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	worker, _ := NewWorker(db, map[string]string{"SPORTS_FEED_MODE": "visible"})
	catalog, err := worker.sportsCatalog(ctx)
	if err != nil || catalog == nil {
		t.Fatalf("catalog required: %v", err)
	}
	key := "topic-test:fingerprint"
	exec(t, db, `DELETE FROM wire_items WHERE canonical_key=$1`, key)
	exec(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,language_code,provenance,published_at,first_seen_at,last_seen_at,source_confidence,eligible,expires_at,updated_at,target_kind,commercial_class,commercial_score)VALUES($1,'https://example.test/fingerprint','example.test','Publisher','Los Angeles Lakers win NBA championship','en','["standard_site"]'::jsonb,$2,$2,$2,.9,TRUE,$3,$2,'standard_site_document','normal',0)`, key, now, now.Add(48*time.Hour))
	_, _, err = projectWindow(ctx, db, "sports", sportsQuality, now, catalog.Version, sportscore.ResolverVersion, nil, 25, func(a article) (any, error) {
		exec(t, db, `UPDATE wire_items SET title=title||' changed' WHERE canonical_key=$1`, a.Key)
		return sportscore.Analyze(a.Title, a.Summary.String, catalog.Entities), nil
	}, catalog.Version, "")
	if err != nil {
		t.Fatal(err)
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM sports_article_analysis WHERE canonical_key=$1`, key).Scan(&count); err != nil || count != 0 {
		t.Fatalf("stale source published %d %v", count, err)
	}
	lock, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback()
	if _, err := lock.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('socialwire:sports-article-projection',0))`); err != nil {
		t.Fatal(err)
	}
	if err := worker.Project(ctx, now); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT count(*) FROM sports_article_analysis WHERE canonical_key=$1`, key).Scan(&count); err != nil || count != 0 {
		t.Fatal("projected through another owner advisory lock")
	}
	lock.Rollback()
	if err := worker.Project(ctx, now); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT count(*) FROM sports_article_analysis WHERE canonical_key=$1`, key).Scan(&count); err != nil || count != 1 {
		t.Fatal("projector did not resume after advisory release")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	before := worker.sportsCursor
	if err := worker.Project(cancelled, now); err == nil {
		t.Fatal("cancelled cycle succeeded")
	}
	if worker.sportsCursor != before {
		t.Fatal("cancelled cycle advanced sweep")
	}
}

func TestTopicProjectionFailureDoesNotSkipOtherDomain(t *testing.T) {
	db := topicDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	worker, _ := NewWorker(db, map[string]string{"FINANCE_FEED_MODE": "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true", "SPORTS_FEED_MODE": "visible"})
	// A syntactically valid JSON snapshot with the wrong model shape exercises
	// Finance failure without disturbing the independent Sports database tables.
	exec(t, db, `UPDATE finance_catalog_snapshots SET is_active=FALSE`)
	exec(t, db, `INSERT INTO finance_catalog_snapshots(snapshot_id,payload,generated_at,version,is_active) VALUES('00000000-0000-0000-0000-00000000f123','{"instruments":"invalid"}'::jsonb,$1,'fixture',TRUE) ON CONFLICT(snapshot_id) DO UPDATE SET payload=EXCLUDED.payload,is_active=TRUE`, now)
	defer exec(t, db, `DELETE FROM finance_catalog_snapshots WHERE snapshot_id='00000000-0000-0000-0000-00000000f123'`)
	key := "topic-test:independent-sports"
	exec(t, db, `DELETE FROM wire_items WHERE canonical_key=$1`, key)
	exec(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,language_code,provenance,published_at,first_seen_at,last_seen_at,source_confidence,eligible,expires_at,updated_at,target_kind,commercial_class,commercial_score) VALUES($1,'https://example.test/independent','example.test','Publisher','Liverpool wins Premier League championship','en','["standard_site"]'::jsonb,$2,$2,$2,.9,TRUE,$3,$2,'standard_site_document','normal',0)`, key, now, now.Add(48*time.Hour))
	if err := worker.Project(ctx, now); err == nil {
		t.Fatal("invalid Finance catalog accepted")
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM sports_article_analysis WHERE canonical_key=$1`, key).Scan(&count); err != nil || count != 1 {
		t.Fatalf("Sports skipped after Finance failure: %d %v", count, err)
	}
}
