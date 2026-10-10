package topicreadcore

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func sourceGenerationDB(t *testing.T, domain string) *sql.DB {
	t.Helper()
	db := selectionDB(t)
	// Keep temporary fixtures and source queries on the same isolated connection.
	db.SetMaxOpenConns(1)
	_, err := db.Exec(`CREATE TEMP TABLE ` + domain + `_generations(generation_id uuid PRIMARY KEY,language text,generated_at timestamptz,expires_at timestamptz,payload jsonb,is_active boolean,serving_source text)`)
	if err != nil {
		t.Fatal(err)
	}
	return db
}

func insertSourceGeneration(t *testing.T, db *sql.DB, domain, id, language, payload string, active bool, generated, expires time.Time) {
	t.Helper()
	if _, err := db.Exec(`INSERT INTO `+domain+`_generations VALUES($1::uuid,$2,$3,$4,$5::jsonb,$6,'ranked')`, id, language, generated, expires, payload, active); err != nil {
		t.Fatal(err)
	}
}

func TestFinanceSourceSelectsActiveThenNewestUnexpiredLanguage(t *testing.T) {
	db := sourceGenerationDB(t, "finance")
	now := time.Now().UTC().Truncate(time.Second)
	active, newest := newID(), newID()
	insertSourceGeneration(t, db, "finance", active, "en", "[]", true, now.Add(-time.Hour), now.Add(time.Hour))
	insertSourceGeneration(t, db, "finance", newest, "en", "[]", false, now, now.Add(time.Hour))
	// Invalid payloads must never be decoded when their identities are excluded.
	insertSourceGeneration(t, db, "finance", newID(), "en", "{}", true, now.Add(time.Hour), now)
	insertSourceGeneration(t, db, "finance", newID(), "fr", "{}", true, now.Add(time.Hour), now.Add(time.Hour))
	store := &FinanceStore{DB: db}
	value, err := store.source(context.Background(), "en", now)
	if err != nil || value.GenerationID != active {
		t.Fatal("active generation must precede newer retained generation", value, err)
	}
	if _, err = db.Exec(`UPDATE finance_generations SET is_active=FALSE WHERE generation_id=$1::uuid`, active); err != nil {
		t.Fatal(err)
	}
	value, err = store.source(context.Background(), "en", now)
	if err != nil || value.GenerationID != newest {
		t.Fatal("newest unexpired generation must win without an active generation", value, err)
	}
}

func TestSportsSourcePreservesPriorityAndCurrentResolverScan(t *testing.T) {
	db := sourceGenerationDB(t, "sports")
	now := time.Now().UTC().Truncate(time.Second)
	current := sourceSportsPayload(t, sportscore.ResolverVersion)
	active, newest := newID(), newID()
	insertSourceGeneration(t, db, "sports", active, "en", current, true, now.Add(-time.Hour), now.Add(time.Hour))
	insertSourceGeneration(t, db, "sports", newest, "en", current, false, now, now.Add(time.Hour))
	insertSourceGeneration(t, db, "sports", newID(), "en", "{}", true, now.Add(time.Hour), now)
	insertSourceGeneration(t, db, "sports", newID(), "fr", "{}", true, now.Add(time.Hour), now.Add(time.Hour))
	store := &SportsStore{DB: db}
	value, err := store.source(context.Background(), "en", now)
	if err != nil || value.GenerationID != active {
		t.Fatal("active generation must remain first after primary-key join", value, err)
	}
	if _, err = db.Exec(`UPDATE sports_generations SET payload=$2::jsonb WHERE generation_id=$1::uuid`, active, sourceSportsPayload(t, "obsolete")); err != nil {
		t.Fatal(err)
	}
	value, err = store.source(context.Background(), "en", now)
	if err != nil || value.GenerationID != newest {
		t.Fatal("obsolete active generation must yield to current retained generation", value, err)
	}
}

func sourceSportsPayload(t *testing.T, version string) string {
	t.Helper()
	payload, err := corpuscore.MarshalHTTP([]sportscore.RankCandidate{{Item: topicItem("source-fixture"), Analysis: sportscore.ArticleAnalysis{ResolverVersion: version, Eligible: true, Materiality: "championship", Associations: []sportscore.Association{}, SportIDs: []string{}, CompetitionIDs: []string{}}, BaseScore: 1}})
	if err != nil {
		t.Fatal(err)
	}
	return string(payload)
}

type sourceFallbackCorpus struct {
	corpuscore.Store
	calls int
}

func (c *sourceFallbackCorpus) Feed(context.Context, corpuscore.FeedQuery, time.Time) (corpuscore.Page, error) {
	c.calls++
	return corpuscore.Page{}, corpuscore.ErrUnavailable
}

func TestSportsSourceBoundsResolverScanToTenGenerations(t *testing.T) {
	db := sourceGenerationDB(t, "sports")
	if _, err := db.Exec(`CREATE TEMP TABLE sports_entities(entity_id text,payload jsonb)`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	for index := 0; index < 11; index++ {
		version := "obsolete"
		if index == 10 {
			version = sportscore.ResolverVersion
		}
		insertSourceGeneration(t, db, "sports", newID(), "en", sourceSportsPayload(t, version), false, now.Add(-time.Duration(index)*time.Minute), now.Add(time.Hour))
	}
	corpus := &sourceFallbackCorpus{}
	wire, err := NewWireStore(corpus, strings.Repeat("s", 32), "visible", &ModerationCache{})
	if err != nil {
		t.Fatal(err)
	}
	store := &SportsStore{DB: db, Wire: wire}
	_, err = store.source(context.Background(), "en", now)
	if !errors.Is(err, ErrUnavailable) || corpus.calls != 1 {
		t.Fatal("eleventh generation must stay outside retained scan before fallback", corpus.calls, err)
	}
}
