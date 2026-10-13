package corpuscore

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func sportsSourceFixture(t *testing.T) SportsSourceResponse {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	entities := []sportscore.Entity{{ID: "team", Name: "Team", Kind: "team", Active: true}}
	revision, err := sportscore.ServingCatalogRevision(entities)
	if err != nil {
		t.Fatal(err)
	}

	candidates := []SportsSourceCandidate{{ItemID: "story", CanonicalURL: "https://example.com/story", Title: "Story", Domain: "example.com", PresentationFingerprint: sportscore.PresentationFingerprint(wirecore.FeedItem{Title: "Story", Source: wirecore.ItemSource{Domain: "example.com"}}), Analysis: sportscore.ArticleAnalysis{ResolverVersion: sportscore.ResolverVersion, Eligible: true, Materiality: "championship", Associations: []sportscore.Association{}, SportIDs: []string{}, CompetitionIDs: []string{}}, BaseScore: 1}}
	return SportsSourceResponse{GenerationID: "11111111-1111-1111-1111-111111111111", GenerationRevision: strings.Repeat("a", 64), GeneratedAt: now, ExpiresAt: now.Add(time.Hour), Language: "en", ResolverVersion: sportscore.ResolverVersion, CatalogRevision: revision, ServingCatalogRevision: revision, CatalogVersion: "version", CatalogGeneratedAt: now.Format(time.RFC3339Nano), Candidates: &candidates}
}

func TestSportsSourceConditionalsAndMutation(t *testing.T) {
	fixture := sportsSourceFixture(t)
	calls := 0
	remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != SportsSourcePath || r.Method != "POST" {
			t.Fatal(r.URL)
		}
		var q SportsSourceRequest
		if json.NewDecoder(r.Body).Decode(&q) != nil {
			t.Fatal("input")
		}
		out := fixture
		if calls == 2 {
			if q.KnownGenerationRevision != fixture.GenerationRevision {
				t.Fatal(q)
			}
			out.GenerationUnchanged = true
			out.Candidates = nil
		}
		if calls == 3 {
			out.GenerationRevision = strings.Repeat("b", 64)
			empty := []SportsSourceCandidate{}
			out.Candidates = &empty
		}
		data, err := MarshalHTTP(out)
		if err != nil {
			t.Fatal(err)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": {"3"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
	})})
	phases := map[string]int{}
	ctx := WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { phases[phase]++ })
	for i := 0; i < 3; i++ {
		out, err := remote.SportsSource(ctx, SportsSourceRequest{Language: "en"}, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		expected := 1
		if i == 2 {
			expected = 0
		}
		if len(*out.Candidates) != expected {
			t.Fatal(out)
		}
	}
	if phases["source-generation-cache-hit"] != 1 || phases["source-generation-cache-miss"] != 2 {
		t.Fatal(phases)
	}
}

func TestSportsSourceMissingCacheRetriesOnlyOnce(t *testing.T) {
	fixture := sportsSourceFixture(t)
	calls := 0
	remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(*http.Request) (*http.Response, error) {
		calls++
		out := fixture
		out.GenerationUnchanged = true

		out.Candidates = nil

		data, _ := MarshalHTTP(out)
		return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": {"3"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
	})})
	_, err := remote.SportsSource(context.Background(), SportsSourceRequest{Language: "en", KnownGenerationID: fixture.GenerationID, KnownGenerationRevision: fixture.GenerationRevision}, time.Now())
	if !errors.Is(err, ErrContractMismatch) || calls != 2 {
		t.Fatal(calls, err)
	}
}

func TestPostgresSportsSourceCurrentEligibilityAndResolver(t *testing.T) {
	db := corpusDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	queryPhases := map[string]int{}
	ctx := WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { queryPhases[phase]++ })
	id := "bcb217b1-7d19-4120-a8af-f2bd2c5f8888"
	key := "sports-lean-current"
	labeler := "did:example:sports-lean"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key)
		db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, labeler)
	})
	execFixture(t, db, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current)VALUES($1,'labels.example',$2,$2,0,0,TRUE)`, labeler, now)
	execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code)VALUES($1,'https://example.com/lean','example.com','Example','Lean',$2,$2,$3,'en')`, key, now, now.Add(time.Hour))
	entity := sportscore.Entity{ID: "team", Name: "Team", Kind: "team", CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Active: true}
	catalog, _ := json.Marshal(map[string]any{"entities": []sportscore.Entity{entity}})
	execFixture(t, db, `INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)VALUES($1::uuid,'lean-v1',$2,$3::jsonb,TRUE)`, id, now, string(catalog))
	summary := "Héllo 世界"
	published := now
	candidate := sportscore.RankCandidate{Item: wirecore.FeedItem{ItemID: key, CanonicalURL: "https://example.com/lean", Title: "Héllo 世界", Summary: &summary, PublishedAt: &published, Source: wirecore.ItemSource{Name: "Example", Domain: "example.com"}, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}, Analysis: sportscore.ArticleAnalysis{ResolverVersion: sportscore.ResolverVersion, Eligible: true, Materiality: "championship", Associations: []sportscore.Association{}, SportIDs: []string{}, CompetitionIDs: []string{}}, BaseScore: 1}
	payload, _ := json.Marshal([]sportscore.RankCandidate{candidate})
	execFixture(t, db, `INSERT INTO sports_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','fixture',$2,$3,$4::jsonb,TRUE)`, id, now, now.Add(time.Hour), string(payload))
	store := &PostgreSQLStore{DB: db}
	first, err := store.SportsSource(ctx, SportsSourceRequest{Language: "en"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(*first.Candidates) != 1 || (*first.Candidates)[0].PresentationFingerprint != sportscore.PresentationFingerprint(candidate.Item) {
		t.Fatal("SQL/Go fingerprint mismatch", first)
	}
	if queryPhases["db-query"] != 3 {
		t.Fatal("cold source should read baseline,current lean projection,catalog once", queryPhases)
	}
	queryPhases = map[string]int{}
	q := SportsSourceRequest{Language: "en", KnownGenerationID: first.GenerationID, KnownGenerationRevision: first.GenerationRevision}
	warm, err := store.SportsSource(ctx, q, now)
	if err != nil || !warm.GenerationUnchanged || warm.Candidates != nil {
		t.Fatal(warm, err)
	}
	if queryPhases["db-query"] != 2 {
		t.Fatal("warm source must read exactly baseline and current eligible lean source", queryPhases)
	}
	execFixture(t, db, `UPDATE wire_items SET expires_at=$2 WHERE canonical_key=$1`, key, now.Add(-time.Second))
	removed, err := store.SportsSource(ctx, q, now)
	if err != nil || removed.GenerationUnchanged || len(*removed.Candidates) != 0 || removed.GenerationRevision == first.GenerationRevision {
		t.Fatal("same ID skipped current eligibility", removed, err)
	}
	execFixture(t, db, `UPDATE wire_items SET expires_at=$2 WHERE canonical_key=$1`, key, now.Add(time.Hour))
	candidate.Analysis.ResolverVersion = "obsolete"
	payload, _ = json.Marshal([]sportscore.RankCandidate{candidate})
	execFixture(t, db, `UPDATE sports_generations SET payload=$2::jsonb WHERE generation_id=$1::uuid`, id, string(payload))
	if _, err := store.SportsSource(ctx, q, now); !errors.Is(err, ErrUnavailable) {
		t.Fatal("same ID skipped resolver change", err)
	}
	candidate.Analysis.ResolverVersion = sportscore.ResolverVersion
	payload, _ = json.Marshal([]sportscore.RankCandidate{candidate})
	execFixture(t, db, `UPDATE sports_generations SET payload=($2::jsonb #- '{0,item,title}') WHERE generation_id=$1::uuid`, id, string(payload))
	if _, err := store.SportsSource(ctx, q, now); !errors.Is(err, ErrContractMismatch) {
		t.Fatal("missing required title became empty string", err)
	}
	execFixture(t, db, `UPDATE wire_label_refresh_state SET is_current=FALSE WHERE source_did=$1`, labeler)
	queryPhases = map[string]int{}
	if _, err := store.SportsSource(ctx, q, now); !errors.Is(err, ErrModerationUnavailable) || queryPhases["db-query"] != 1 {
		t.Fatal("stale baseline must reject before source query", err, queryPhases)
	}
	execFixture(t, db, `UPDATE wire_label_refresh_state SET is_current=TRUE WHERE source_did=$1`, labeler)
	execFixture(t, db, `UPDATE sports_generations SET expires_at=$2 WHERE generation_id=$1::uuid`, id, now.Add(-time.Second))
	if _, err := store.SportsSource(ctx, q, now); !errors.Is(err, ErrUnavailable) {
		t.Fatal("expired generation", err)
	}
}
