package wireworkercore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func generationDatabase(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set SOCIALWIRE_GO_WIRE_TEST_DATABASE_URL to a disposable, canonically migrated PostgreSQL database")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}
func seedGenerationItems(t *testing.T, db *sql.DB, at time.Time) []wirecore.Candidate {
	t.Helper()
	id, err := newGenerationID()
	if err != nil {
		t.Fatal(err)
	}
	result := []wirecore.Candidate{}
	for i := range 6 {
		key := "url:go-fixture-" + id + fmt.Sprint(i)
		uri := "https://" + id + fmt.Sprint(i) + ".example/story"
		domain := id + fmt.Sprint(i) + ".example"
		if _, err := db.Exec(`INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,language_code,provenance,published_at,first_seen_at,last_seen_at,last_signal_at,source_confidence,expires_at) VALUES($1,$2,$3,'Fixture','Fixture story','en','["standard_site"]'::jsonb,$4,$4,$4,$4,1,$5)`, key, uri, domain, at, at.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`INSERT INTO wire_signal_rollups(canonical_key,shares_24h,baseline_shares_24h) VALUES($1,10,5)`, key); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key) })
		c := wirecore.NewCandidate(key, uri, domain, at)
		yes := true
		c.IsStandardSite = &yes
		c.SourceConfidence = 1
		c.Shares24h = 5
		result = append(result, c)
	}
	return result
}
func TestGenerationCandidateProjectionMatchesOriginal(t *testing.T) {
	db := generationDatabase(t)
	at := time.Now().UTC()
	items := seedGenerationItems(t, db, at)
	store := PostgresGenerationStore{DB: db}
	ranking := wirecore.DefaultRankingConfig()
	plain, err := store.LoadCandidates(context.Background(), "und", 5000, ranking, at)
	if err != nil {
		t.Fatal(err)
	}
	store.GlobalCandidateProjectionEnabled = true
	projected, err := store.LoadCandidates(context.Background(), "und", 5000, ranking, at)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(plain, projected) {
		t.Fatal("metadata projection changed candidate snapshot")
	}
	found := false
	for _, c := range plain {
		if c.CanonicalKey == items[0].CanonicalKey {
			found = true
			if c.Shares24h != 5 {
				t.Fatal("baseline included external shares")
			}
		}
	}
	if !found {
		t.Fatal("missing candidate")
	}
	external, err := store.LoadCandidates(context.Background(), "en", 5000, wirecore.ExternalSignalsV11(), at)
	if err != nil {
		t.Fatal(err)
	}
	found = false
	for _, c := range external {
		if c.CanonicalKey == items[0].CanonicalKey {
			found = true
			if c.Shares24h != 10 {
				t.Fatal("external plan omitted shares")
			}
		}
	}
	if !found {
		t.Fatal("missing external candidate")
	}
	languages, err := store.EligibleLanguageBuckets(context.Background(), 12, 1, ranking, at)
	if err != nil {
		t.Fatal(err)
	}
	if len(languages) == 0 || languages[0] != "en" {
		t.Fatal("locale discovery", languages)
	}
}
func TestGenerationPublicationAndStaleFenceRollback(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	at := time.Now().UTC()
	candidates := seedGenerationItems(t, db, at)
	id, err := newGenerationID()
	if err != nil {
		t.Fatal(err)
	}
	feed := "go-fixture-" + id
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM wire_feed_state WHERE feed_key=$1`, feed)
		_, _ = db.Exec(`DELETE FROM wire_rank_generations WHERE feed_key=$1`, feed)
	})
	leaseStore := operationscore.PostgresRoleLeaseStore{DB: db, Environment: "go-test"}
	lease, err := leaseStore.Acquire(ctx, "materializer-"+id, "owner", time.Minute)
	if err != nil || lease == nil {
		t.Fatal(err)
	}
	store := PostgresGenerationStore{DB: db, Authority: &lease.RoleLeaseAuthority}
	result, err := wirecore.Rank(candidates, at, wirecore.DefaultRankingConfig())
	if err != nil {
		t.Fatal(err)
	}
	generation := GenerationCommit{id, feed, "und", wirecore.BaselineVersion, at, at.Add(time.Hour), true, result}
	if err := store.Commit(ctx, generation); err != nil {
		t.Fatal(err)
	}
	var active string
	if err := db.QueryRow(`SELECT active_generation_id FROM wire_feed_state WHERE feed_key=$1 AND language_bucket='und'`, feed).Scan(&active); err != nil || active != id {
		t.Fatal("active generation", active, err)
	}
	var variants int
	if err := db.QueryRow(`SELECT COUNT(DISTINCT(position>=1000)) FROM wire_edition_modules WHERE generation_id=$1`, id).Scan(&variants); err != nil || variants != 2 {
		t.Fatal("missing edition variants", variants, err)
	}
	if err := leaseStore.Release(ctx, lease.RoleLeaseAuthority); err != nil {
		t.Fatal(err)
	}
	successor, err := leaseStore.Acquire(ctx, lease.Role, "successor", time.Minute)
	if err != nil || successor == nil {
		t.Fatal(err)
	}
	staleID, err := newGenerationID()
	if err != nil {
		t.Fatal(err)
	}
	generation.GenerationID = staleID
	if err := store.Commit(ctx, generation); !errors.Is(err, operationscore.ErrLeaseConflict) {
		t.Fatalf("stale publication: %v", err)
	}
	var exists bool
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM wire_rank_generations WHERE generation_id=$1)`, staleID).Scan(&exists); err != nil || exists {
		t.Fatal("stale generation survived rollback", err)
	}
	if err := db.QueryRow(`SELECT active_generation_id FROM wire_feed_state WHERE feed_key=$1 AND language_bucket='und'`, feed).Scan(&active); err != nil || active != id {
		t.Fatal("stale owner replaced active generation", active, err)
	}
	store.Authority = &successor.RoleLeaseAuthority
	shadowID, err := newGenerationID()
	if err != nil {
		t.Fatal(err)
	}
	generation.GenerationID = shadowID
	generation.Activate = false
	if err := store.Commit(ctx, generation); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT active_generation_id FROM wire_feed_state WHERE feed_key=$1 AND language_bucket='und'`, feed).Scan(&active); err != nil || active != id {
		t.Fatal("shadow changed active pointer", active, err)
	}
	if err := store.RecordCycleDuration(ctx, 42, shadowID); err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteExpired(ctx, at.Add(2*time.Hour), 10); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM wire_rank_generations WHERE generation_id=$1)`, shadowID).Scan(&exists); err != nil || exists {
		t.Fatal("expired shadow retained", err)
	}
	if err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM wire_rank_generations WHERE generation_id=$1)`, id).Scan(&exists); err != nil || !exists {
		t.Fatal("active generation removed", err)
	}
}
