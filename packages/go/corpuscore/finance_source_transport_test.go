package corpuscore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func financeSourceFixture() FinanceSourceResponse {
	now := time.Now().UTC().Truncate(time.Second)
	id := "22222222-1111-1111-1111-111111111111"
	resolver := financecore.ResolverVersion
	item := wirecore.FeedItem{ItemID: "finance", CanonicalURL: "https://example.com/finance", Title: "Finance", Source: wirecore.ItemSource{Name: "Example", Domain: "example.com"}, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}
	generation := FinanceGeneration{GenerationID: id, GeneratedAt: now, ExpiresAt: now.Add(time.Hour), Language: "en", Candidates: []financecore.RankCandidate{{Item: item, Analysis: financecore.ArticleAnalysis{ResolverVersion: &resolver, Eligible: true, Materiality: "earnings", Associations: []financecore.Association{{InstrumentID: "instrument", ResolverVersion: resolver, Evidence: []string{"fixture"}}}, SectorIDs: []string{}}, BaseScore: 1}}, Instruments: []financecore.Instrument{{ID: "instrument", Name: "Instrument", Symbol: "INSTR", Kind: "equity", ProviderID: "provider", Aliases: []string{"alias"}, SectorIDs: []string{}, IsActive: true}}}
	return FinanceSourceResponse{GenerationID: id, GenerationRevision: strings.Repeat("a", 64), GeneratedAt: now, ExpiresAt: generation.ExpiresAt, Language: "en", Generation: &generation}
}
func TestFinanceSourceRemoteConditionalsMutationAndIsolation(t *testing.T) {
	fixture := financeSourceFixture()
	calls := 0
	remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != FinanceSourcePath || r.Method != "POST" {
			t.Fatal(r.URL)
		}
		var q FinanceSourceRequest
		if json.NewDecoder(r.Body).Decode(&q) != nil {
			t.Fatal("input")
		}
		out := fixture
		if calls == 2 {
			if q.KnownGenerationID != fixture.GenerationID || q.KnownGenerationRevision != fixture.GenerationRevision {
				t.Fatal(q)
			}
			out.GenerationUnchanged = true
			out.Generation = nil
		}
		if calls == 3 {
			out.GenerationRevision = strings.Repeat("b", 64)
			gen := cloneFinanceGeneration(*fixture.Generation)
			gen.Candidates = []financecore.RankCandidate{}
			out.Generation = &gen
		}
		data, _ := MarshalHTTP(out)
		return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": {"3"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
	})})
	phases := map[string]int{}
	ctx := WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { phases[phase]++ })
	first, err := remote.Finance(ctx, "en", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	first.Candidates[0].Item.Title = "caller"
	first.Candidates[0].Analysis.Associations[0].Evidence[0] = "caller"
	first.Instruments[0].Aliases[0] = "caller"
	second, err := remote.Finance(ctx, "en", time.Now())
	if err != nil || second.Candidates[0].Item.Title != "Finance" || second.Candidates[0].Analysis.Associations[0].Evidence[0] != "fixture" || second.Instruments[0].Aliases[0] != "alias" {
		t.Fatal(second, err)
	}
	third, err := remote.Finance(ctx, "en", time.Now())
	if err != nil || len(third.Candidates) != 0 {
		t.Fatal(third, err)
	}
	if phases["source-generation-cache-hit"] != 1 || phases["source-generation-cache-miss"] != 2 {
		t.Fatal("conditional telemetry", phases)
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := remote.Finance(cancelled, "en", time.Now()); !errors.Is(err, context.Canceled) || calls != 3 {
		t.Fatal("cancelled cache request", err, calls)
	}
}
func TestFinanceSourceMissingBodyRetryAndMalformedResponse(t *testing.T) {
	fixture := financeSourceFixture()
	for _, malformed := range []bool{false, true} {
		calls := 0
		remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(r *http.Request) (*http.Response, error) {
			calls++
			var q FinanceSourceRequest
			json.NewDecoder(r.Body).Decode(&q)
			out := fixture
			if calls == 1 || malformed {
				out.GenerationUnchanged = true
				out.Generation = nil
			} else if q.KnownGenerationID != "" || q.KnownGenerationRevision != "" {
				t.Fatal("retry retained conditionals", q)
			}
			data, _ := MarshalHTTP(out)
			return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": {"3"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
		})})
		out, err := remote.FinanceSource(context.Background(), FinanceSourceRequest{Language: "en", KnownGenerationID: fixture.GenerationID, KnownGenerationRevision: fixture.GenerationRevision}, time.Now())
		if calls != 2 || (malformed && !errors.Is(err, ErrContractMismatch)) || (!malformed && (err != nil || out.Generation == nil)) {
			t.Fatal(calls, out, err)
		}
	}
}
func TestPostgresFinanceSourceCurrentEligibilityAndInstrumentRevision(t *testing.T) {
	db := corpusDB(t)
	now := time.Now().UTC().Truncate(time.Second)
	id := "33333333-2222-2222-2222-222222222222"
	key := "finance-source-current"
	labeler := "did:example:finance-source"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM finance_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key)
		db.Exec(`DELETE FROM finance_instruments WHERE instrument_id=$1`, "finance-source-instrument")
		db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, labeler)
	})
	execFixture(t, db, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current)VALUES($1,'labels.example',$2,$2,0,0,TRUE)`, labeler, now)
	execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code)VALUES($1,'https://example.com/finance','example.com','Example','Finance',$2,$2,$3,'en')`, key, now, now.Add(time.Hour))
	fixture := financeSourceFixture()
	fixture.Generation.Candidates[0].Item.ItemID = key
	fixture.Generation.Candidates[0].Analysis.Associations[0].InstrumentID = "finance-source-instrument"
	instrument := fixture.Generation.Instruments[0]
	instrument.ID = "finance-source-instrument"
	raw, _ := json.Marshal(instrument)
	execFixture(t, db, `INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)VALUES($1,'finance-source-provider',$2::jsonb,$3)`, instrument.ID, string(raw), now)
	raw, _ = json.Marshal(fixture.Generation.Candidates)
	execFixture(t, db, `INSERT INTO finance_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','fixture',$2,$3,$4::jsonb,TRUE)`, id, now, now.Add(time.Hour), string(raw))
	phases := map[string]int{}
	ctx := WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { phases[phase]++ })
	store := &PostgreSQLStore{DB: db}
	first, err := store.FinanceSource(ctx, FinanceSourceRequest{Language: "en"}, now)
	if err != nil || len(first.Generation.Candidates) != 1 || len(first.Generation.Instruments) != 1 {
		t.Fatal(first, err)
	}
	q := FinanceSourceRequest{Language: "en", KnownGenerationID: id, KnownGenerationRevision: first.GenerationRevision}
	phases = map[string]int{}
	warm, err := store.FinanceSource(ctx, q, now)
	if err != nil || !warm.GenerationUnchanged || warm.Generation != nil || phases["db-query"] != 2 || phases["source-generation-cache-hit"] != 1 {
		t.Fatal("warm metadata", warm, err, phases)
	}
	first.Generation.Candidates[0].Item.Title = "caller"
	first.Generation.Instruments[0].Aliases[0] = "caller"
	full, err := store.FinanceSource(ctx, FinanceSourceRequest{Language: "en"}, now)
	if err != nil || full.Generation.Candidates[0].Item.Title != "Finance" || full.Generation.Instruments[0].Aliases[0] != "alias" {
		t.Fatal("caller mutation", full, err)
	}
	instrument.Name = "Changed"
	raw, _ = json.Marshal(instrument)
	execFixture(t, db, `UPDATE finance_instruments SET payload=$2::jsonb WHERE instrument_id=$1`, instrument.ID, string(raw))
	changed, err := store.FinanceSource(ctx, q, now)
	if err != nil || changed.GenerationUnchanged || changed.GenerationRevision == first.GenerationRevision || changed.Generation.Instruments[0].Name != "Changed" {
		t.Fatal("instrument change under immutable ID", changed, err)
	}
	execFixture(t, db, `UPDATE wire_items SET expires_at=$2 WHERE canonical_key=$1`, key, now.Add(-time.Second))
	removed, err := store.FinanceSource(ctx, q, now)
	if err != nil || removed.GenerationUnchanged || len(removed.Generation.Candidates) != 0 {
		t.Fatal("current eligibility", removed, err)
	}
	execFixture(t, db, `UPDATE wire_items SET expires_at=$2 WHERE canonical_key=$1`, key, now.Add(time.Hour))
	execFixture(t, db, `UPDATE finance_generations SET payload=payload #- '{0,item,title}' WHERE generation_id=$1::uuid`, id)
	metadata, err := store.query(ctx, financeSourceProjection+`SELECT revision FROM current_source`, "en", now)
	if err != nil {
		t.Fatal(err)
	}
	q.KnownGenerationRevision = metadata[0].String(0)
	if _, err := store.FinanceSource(ctx, q, now); !errors.Is(err, ErrContractMismatch) {
		t.Fatal("forged malformed revision bypassed strict decoder", err)
	}
	execFixture(t, db, `UPDATE wire_label_refresh_state SET is_current=FALSE WHERE source_did=$1`, labeler)
	if _, err := store.FinanceSource(ctx, q, now); !errors.Is(err, ErrModerationUnavailable) {
		t.Fatal("baseline weakened", err)
	}
}

func TestFinanceSourceRemoteRejectsMalformedContracts(t *testing.T) {
	for _, mutate := range []func(*FinanceSourceResponse){
		func(r *FinanceSourceResponse) { r.Generation = nil },
		func(r *FinanceSourceResponse) { r.GenerationUnchanged = true },
		func(r *FinanceSourceResponse) { r.Generation.GenerationID = "wrong" },
		func(r *FinanceSourceResponse) { r.Generation.Candidates[0].Item.Reasons = nil },
		func(r *FinanceSourceResponse) { r.Generation.Instruments[0].Aliases = nil },
		func(r *FinanceSourceResponse) { r.ExpiresAt = time.Time{} },
		func(r *FinanceSourceResponse) { r.GenerationRevision = "invalid" },
		func(r *FinanceSourceResponse) { r.Generation.Candidates[0].BaseScore = -1 },
		func(r *FinanceSourceResponse) { r.Generation.Candidates[0].Analysis.Associations[0].Confidence = 1.1 },
	} {
		fixture := financeSourceFixture()
		mutate(&fixture)
		data, _ := MarshalHTTP(fixture)
		remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": {"3"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
		})})
		if _, err := remote.Finance(context.Background(), "en", time.Now()); !errors.Is(err, ErrContractMismatch) {
			t.Fatal("malformed Finance source accepted", err)
		}
	}
}

func TestFinanceSourceCancellationBeforeCachePublication(t *testing.T) {
	fixture := financeSourceFixture()
	data, _ := MarshalHTTP(fixture)
	remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": {"3"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
	})})
	ctx, cancel := context.WithCancel(context.Background())
	observed := WithQueryObserver(ctx, func(phase string, _ time.Duration) {
		if phase == "source-generation-cache-miss" {
			cancel()
		}
	})
	if _, err := remote.FinanceSource(observed, FinanceSourceRequest{Language: "en"}, time.Now()); !errors.Is(err, context.Canceled) || remote.financeCached != nil {
		t.Fatal("cancelled source published cache", err)
	}
}
