package corpuscore

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPostgresFallbackCircleAndViewOnlyRole(t *testing.T) {
	db := corpusDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	labeler := "did:example:corpus-fallback"
	prefix := "corpus-fallback-"
	actor := "h1:" + strings.Repeat("a", 64)
	role := "corpus_go_view_reader"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM wire_items WHERE canonical_key LIKE $1`, prefix+"%")
		db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, labeler)
		db.Exec(`DROP OWNED BY corpus_go_view_reader`)
		db.Exec(`DROP ROLE IF EXISTS corpus_go_view_reader`)
	})
	execFixture(t, db, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current) VALUES($1,'labels.example',$2,$2,0,0,TRUE)`, labeler, now)
	expectedCandidates := []wirecore.Candidate{}
	for index := 0; index < 60; index++ {
		key := fmt.Sprintf("%s%02d", prefix, index)
		domain := fmt.Sprintf("source-%d.example", index)
		published := now.Add(-time.Hour)
		kind := "standard_site_document"
		commercial := "normal"
		baseline := 5
		if index >= 4 {
			commercial = "probable_ad"
		}
		if index == 3 {
			baseline = 1
		}
		confidence := 0.9
		execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,last_signal_at,published_at,expires_at,language_code,provenance,target_kind,commercial_class,source_confidence,eligible) VALUES($1,$2,$3,'Example',$1,$4,$5,$5,$4,$6,'en','["standard_site"]'::jsonb,$7,$8,$9,TRUE)`, key, "https://"+domain+"/article", domain, published, now, now.Add(time.Hour), kind, commercial, confidence)
		execFixture(t, db, `INSERT INTO wire_signal_rollups(canonical_key,shares_24h,baseline_last_signal_at,baseline_shares_1h,baseline_shares_24h,baseline_distinct_actors_1h,baseline_distinct_actors_24h,baseline_distinct_actors_7d,baseline_signals_1h,baseline_signals_24h,baseline_signals_7d,updated_at) VALUES($1,10000,$2,$3,$3,$3,$3,$3,$3,$3,$3,$2)`, key, now, baseline)
		if index < 4 {
			flag := true
			expectedCandidates = append(expectedCandidates, wirecore.Candidate{CanonicalKey: key, CanonicalURL: "https://" + domain + "/article", SourceDomain: domain, PublishedAt: &published, FirstSeenAt: published, LastSignalAt: &now, SourceConfidence: confidence, IsStandardSite: &flag, TargetKind: wirecore.StandardSiteDocument, CommercialClass: wirecore.Normal, DistinctActors1h: baseline, DistinctActors24h: baseline, DistinctActors7d: baseline, Signals1h: baseline, Signals24h: baseline, Signals7d: baseline, Shares1h: baseline, Shares24h: baseline, TopicKeys: []string{}})
		}
	}
	execFixture(t, db, `INSERT INTO wire_signal_events(event_key,canonical_key,signal_kind,actor_key_hash,source_uri,occurred_at,expires_at,source_collection,source_action) VALUES('corpus-share',$1,'share',$2,'at://did:example:actor/app.bsky.feed.post/test',$3,$4,'app.bsky.feed.post','create')`, prefix+"00", actor, now, now.Add(time.Hour))
	execFixture(t, db, `CREATE ROLE corpus_go_view_reader LOGIN`)
	execFixture(t, db, `GRANT USAGE ON SCHEMA wire_serving TO corpus_go_view_reader`)
	execFixture(t, db, `GRANT SELECT ON ALL TABLES IN SCHEMA wire_serving TO corpus_go_view_reader`)
	config, err := pgx.ParseConfig(os.Getenv("SOCIALWIRE_GO_CORPUS_TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	config.User = role
	reader := stdlib.OpenDB(*config)
	reader.SetMaxOpenConns(1)
	defer reader.Close()
	if _, err := reader.Exec(`SELECT canonical_key FROM public.wire_items LIMIT 1`); err == nil {
		t.Fatal("serving role read raw corpus")
	}
	if _, err := reader.Exec(`UPDATE public.wire_items SET title='bad'`); err == nil {
		t.Fatal("serving role wrote raw corpus")
	}
	store := &PostgreSQLStore{DB: reader}
	if err := store.Ping(ctx); err != nil {
		t.Fatal(err)
	}
	page, err := store.Feed(ctx, FeedQuery{Language: "en", Limit: 20}, now)
	if err != nil {
		t.Fatal(err)
	}
	expected, err := wirecore.Rank(expectedCandidates, now, wirecore.DefaultRankingConfig())
	if err != nil || len(expected.Items) != 4 {
		t.Fatal("fixture rank", err, len(expected.Items))
	}
	if page.Source != "simplified_fallback" || !page.Degraded || len(page.Rows) != 4 {
		t.Fatalf("fallback %+v", page)
	}
	for i, r := range page.Rows {
		if r.Item.ItemID != expected.Items[i].Candidate.CanonicalKey {
			t.Fatalf("rank parity %d %s", i, r.Item.ItemID)
		}
	}
	limit := 5000
	edition, err := store.Edition(ctx, EditionQuery{Language: "en", FallbackLimit: &limit}, now)
	if err != nil || len(edition.FallbackRows) != 4 {
		t.Fatal("fallback edition", err, len(edition.FallbackRows))
	}
	catalog, err := store.Catalog(ctx, now)
	if err != nil || catalog.Available {
		t.Fatal("catalog minimum candidate contract", catalog, err)
	}
	facts, err := store.CircleCandidates(ctx, CandidateRequest{ActorHashes: []string{actor}, Language: "en", Since: now.Add(-time.Hour), Limit: 5}, now)
	if err != nil || len(facts.Stories) != 1 || len(facts.Stories[0].Facts) != 1 || facts.Stories[0].Facts[0].Kind != "share" {
		t.Fatalf("Circle %+v %v", facts, err)
	}
	for _, method := range []func() error{func() error { _, e := store.SportsSchedules(ctx, now); return e }, func() error { _, e := store.SportsStandings(ctx, nil, now); return e }, func() error { _, e := store.SportsEvents(ctx, EventsQuery{Global: true}, now); return e }} {
		if err := method(); err != nil {
			t.Fatal("serving view permissions", err)
		}
	}
}
