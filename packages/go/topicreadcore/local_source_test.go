package topicreadcore

import (
	"context"
	"database/sql"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func TestLocalSourceRequiresSamePostgresAuthority(t *testing.T) {
	db, other := new(sql.DB), new(sql.DB)
	local := &corpuscore.PostgreSQLStore{DB: db}
	if localSourceStore(&WireStore{Corpus: local}, db) != local {
		t.Fatal("same local authority was not selected")
	}
	for _, wire := range []*WireStore{nil, {Corpus: (*corpuscore.PostgreSQLStore)(nil)}, {Corpus: local}, {Corpus: &corpusFixture{}}} {
		if localSourceStore(wire, other) != nil {
			t.Fatal("different authority selected")
		}
	}
}

type localSourceFixture struct {
	db                   *sql.DB
	now                  time.Time
	id, catalog, labeler string
	keys                 []string
	items                map[string]wirecore.FeedItem
	entity               sportscore.Entity
	instrument           financecore.Instrument
	corpus               *corpuscore.PostgreSQLStore
	wire                 *WireStore
}

func newLocalSourceFixture(t *testing.T, sports bool) *localSourceFixture {
	t.Helper()
	f := &localSourceFixture{db: selectionDB(t), now: time.Now().UTC().Truncate(time.Second), id: newID(), catalog: newID(), items: map[string]wirecore.FeedItem{}}
	f.labeler = "did:example:local-source-" + f.id
	domain := "finance"
	if sports {
		domain = "sports"
	}
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := f.db.Exec(query, args...); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		f.db.Exec(`DELETE FROM `+domain+`_generations WHERE generation_id=$1::uuid`, f.id)
		f.db.Exec(`DELETE FROM wire_items WHERE canonical_key=ANY($1::text[])`, f.keys)
		f.db.Exec(`DELETE FROM wire_label_refresh_state WHERE source_did=$1`, f.labeler)
		if sports {
			f.db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, f.catalog)
			f.db.Exec(`DELETE FROM sports_entities WHERE entity_id=$1`, f.entity.ID)
		} else {
			f.db.Exec(`DELETE FROM finance_instruments WHERE instrument_id=$1`, f.instrument.ID)
		}
	})
	exec(`INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current)VALUES($1,'labels.test',$2,$2,0,0,TRUE)`, f.labeler, f.now)
	f.entity = sportscore.Entity{ID: "local-team-" + f.id, Name: "Fixture Football Club", Kind: "team", Active: true, CompetitionIDs: []string{}, Aliases: []string{}, ProviderIDs: map[string]string{}, Memberships: []sportscore.Membership{}}
	f.instrument = financecore.Instrument{ID: "local-stock-" + f.id, Name: "Local Finance Company", Symbol: "LOCAL", Kind: "stock", ProviderID: f.id, Aliases: []string{"Local Finance Company"}, SectorIDs: []string{}, IsActive: true}
	if sports {
		raw, _ := corpuscore.MarshalHTTP(f.entity)
		exec(`INSERT INTO sports_entities(entity_id,payload,updated_at)VALUES($1,$2::jsonb,$3)`, f.entity.ID, raw, f.now)
		raw, _ = corpuscore.MarshalHTTP(map[string]any{"entities": []sportscore.Entity{f.entity}})
		exec(`INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)VALUES($1::uuid,$2,$3,$4::jsonb,TRUE)`, f.catalog, f.id, f.now, raw)
	} else {
		raw, _ := corpuscore.MarshalHTTP(f.instrument)
		exec(`INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)VALUES($1,$2,$3::jsonb,$4)`, f.instrument.ID, f.id, raw, f.now)
	}
	var sportsCandidates []sportscore.RankCandidate
	var financeCandidates []financecore.RankCandidate
	for index := range 3 {
		key := "local-source-" + f.id + "-" + string(rune('a'+index))
		f.keys = append(f.keys, key)
		item := topicItem(key)
		item.Title = []string{"Local Finance Company reports record earnings and revenue", "Local Finance Company announces semiconductor investment deal", "Local Finance Company publishes quarterly financial regulation filing"}[index]
		if sports {
			item.Title = "Fixture Football Club wins championship " + key
		}
		item.Source.Domain = key + ".example"
		published := f.now.Add(-time.Hour)
		item.PublishedAt = &published
		item.Provenance = []string{"standard_site"}
		f.items[key] = item
		exec(`INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code,published_at,provenance,target_kind,source_confidence)VALUES($1,$2,$3,$4,$5,$6,$6,$7,'zz',$8,'["standard_site"]','standard_site_document',.9)`, key, item.CanonicalURL, item.Source.Domain, item.Source.Name, item.Title, f.now, f.now.Add(time.Hour), published)
		exec(`INSERT INTO wire_signal_rollups(canonical_key,shares_24h,baseline_last_signal_at,baseline_shares_1h,baseline_shares_24h,baseline_distinct_actors_1h,baseline_distinct_actors_24h,baseline_distinct_actors_7d,baseline_signals_1h,baseline_signals_24h,baseline_signals_7d,updated_at)VALUES($1,5,$2,5,5,5,5,5,5,5,5,$2)`, key, f.now)
		sportsCandidates = append(sportsCandidates, sportscore.RankCandidate{Item: item, BaseScore: float64(3 - index), MajorGlobal: true, Analysis: sportscore.ArticleAnalysis{ResolverVersion: sportscore.ResolverVersion, Eligible: true, Materiality: "championship", Associations: []sportscore.Association{{EntityID: f.entity.ID, Confidence: .99, Evidence: []string{"title"}, ResolverVersion: sportscore.ResolverVersion}}, SportIDs: []string{}, CompetitionIDs: []string{}}})
		analysis := financecore.Analyze(item.Title, "", []string{f.instrument.ID}, nil, []financecore.Instrument{f.instrument})
		if !analysis.Eligible {
			t.Fatal("Finance fixture is not eligible")
		}
		financeCandidates = append(financeCandidates, financecore.RankCandidate{Item: item, Analysis: analysis, BaseScore: float64(3 - index), MajorGlobal: true})
	}
	var payload []byte
	if sports {
		payload, _ = corpuscore.MarshalHTTP(append(sportsCandidates[:2:2], sportsCandidates[0], sportsCandidates[2]))
	} else {
		payload, _ = corpuscore.MarshalHTTP(append(financeCandidates[:2:2], financeCandidates[0], financeCandidates[2]))
	}
	exec(`INSERT INTO `+domain+`_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'zz','local-fixture',$2,$3,$4::jsonb,TRUE)`, f.id, f.now, f.now.Add(time.Hour), payload)
	f.corpus = &corpuscore.PostgreSQLStore{DB: f.db}
	var err error
	f.wire, err = NewWireStore(f.corpus, strings.Repeat("l", 32), "visible", NewModerationService(nil, nil).Cache)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func localStores(t *testing.T, f *localSourceFixture, legacy bool) (*SportsStore, *FinanceStore) {
	t.Helper()
	wire := f.wire
	secret := strings.Repeat("l", 32)
	if legacy {
		secret = strings.Repeat("p", 32)
		var err error
		wire, err = NewWireStore(&financeWireFixture{items: f.items}, secret, "visible", NewModerationService(nil, nil).Cache)
		if err != nil {
			t.Fatal(err)
		}
	}
	env := map[string]string{"WIRE_CURSOR_HMAC_SECRET": secret, "SPORTS_FEED_MODE": "visible", "FINANCE_FEED_MODE": "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true"}
	sports, err := NewSportsStore(f.db, wire, &SelectionProjection{DB: f.db}, env)
	if err != nil {
		t.Fatal(err)
	}
	finance, err := NewFinanceStore(f.db, wire, &SelectionProjection{DB: f.db}, env)
	if err != nil {
		t.Fatal(err)
	}
	return sports, finance
}

func TestPostgresLocalSourcePageParityCacheOwnershipAndRecovery(t *testing.T) {
	for _, sports := range []bool{true, false} {
		name := "finance"
		if sports {
			name = "sports"
		}
		t.Run(name, func(t *testing.T) {
			f := newLocalSourceFixture(t, sports)
			store, finance := localStores(t, f, false)
			legacy, oldFinance := localStores(t, f, true)
			var mu sync.Mutex
			phases := map[string]int{}
			ctx := WithFeedPhaseObserver(context.Background(), func(phase string, _ time.Duration) { mu.Lock(); phases[phase]++; mu.Unlock() })
			source := func() ([]string, *string, error) {
				ids := []string{}
				if sports {
					value, err := store.source(ctx, "zz", f.now)
					for _, c := range value.Candidates {
						ids = append(ids, c.Item.ItemID)
						if c.Analysis.Associations[0].Evidence[0] == "caller mutation" {
							t.Fatal("caller poisoned Sports cache")
						}
					}
					if len(value.Candidates) > 0 {
						value.Candidates[0].Analysis.Associations[0].Evidence[0] = "caller mutation"
					}
					return ids, value.Source, err
				}
				value, err := finance.source(ctx, "zz", f.now)
				for _, c := range value.Candidates {
					ids = append(ids, c.Item.ItemID)
					if c.Analysis.Associations[0].Evidence[0] == "caller mutation" {
						t.Fatal("caller poisoned Finance cache")
					}
				}
				if len(value.Candidates) > 0 {
					value.Candidates[0].Analysis.Associations[0].Evidence[0] = "caller mutation"
				}
				for i := range value.Instruments {
					if value.Instruments[i].Aliases[0] == "caller mutation" {
						t.Fatal("caller poisoned Finance instrument cache")
					}
					value.Instruments[i].Aliases[0] = "caller mutation"
				}
				return ids, value.Source, err
			}
			for range 2 {
				ids, provenance, err := source()
				if err != nil || !reflect.DeepEqual(ids, []string{f.keys[0], f.keys[1], f.keys[0], f.keys[2]}) || provenance == nil || *provenance != "ranked" {
					t.Fatal("source order/provenance", ids, provenance, err)
				}
			}
			if phases["source-generation-cache-hit"] == 0 || phases["source-generation-cache-miss"] == 0 || (sports && (phases["source-catalog-cache-hit"] == 0 || phases["source-catalog-cache-miss"] == 0)) {
				t.Fatal("missing local cache markers", phases)
			}
			cancelled, cancel := context.WithCancel(context.Background())
			cancel()
			var cancelErr error
			if sports {
				_, cancelErr = store.source(cancelled, "zz", f.now)
			} else {
				_, cancelErr = finance.source(cancelled, "zz", f.now)
			}
			if !errors.Is(cancelErr, context.Canceled) {
				t.Fatal("cancelled local source entered retained fallback", cancelErr)
			}
			if sports {
				first, err := store.Page(ctx, "", 1, "zz", "", false, f.now, "sports", nil)
				old, oldErr := legacy.Page(ctx, "", 1, "zz", "", false, f.now, "sports", nil)
				if err != nil || oldErr != nil || len(first.Items) != 1 || len(old.Items) != 1 || first.Items[0].Story.ItemID != old.Items[0].Story.ItemID || first.Cursor == nil {
					t.Fatal("local Sports page parity", first, old, err, oldErr)
				}
				warm, err := store.Page(ctx, "", 1, "zz", "", false, f.now, "sports", nil)
				if err != nil || warm.GenerationID != first.GenerationID {
					t.Fatal("local snapshot reuse", warm, err)
				}
				next, err := store.Page(ctx, *first.Cursor, 1, "zz", "", false, f.now, "sports", nil)
				if err != nil || len(next.Items) != 1 || next.Items[0].Story.ItemID != f.keys[1] {
					t.Fatal("Sports cursor order", next, err)
				}
			} else {
				first, err := finance.Page(ctx, "", 1, "zz", "", false, f.now, "finance", false)
				old, oldErr := oldFinance.Page(ctx, "", 1, "zz", "", false, f.now, "finance", false)
				if err != nil || oldErr != nil || len(first.Items) != 1 || len(old.Items) != 1 || first.Items[0].Story.ItemID != old.Items[0].Story.ItemID || first.Cursor == nil {
					t.Fatal("local Finance page parity", first, old, err, oldErr)
				}
				warm, err := finance.Page(ctx, "", 1, "zz", "", false, f.now, "finance", false)
				if err != nil || warm.GenerationID != first.GenerationID {
					t.Fatal("local Finance snapshot reuse", warm, err)
				}
				next, err := finance.Page(ctx, *first.Cursor, 1, "zz", "", false, f.now, "finance", false)
				if err != nil || len(next.Items) != 1 || next.Items[0].Story.ItemID != f.keys[1] {
					t.Fatal("Finance cursor order", next, err)
				}
			}
			if _, err := f.db.Exec(`UPDATE wire_items SET eligible=FALSE WHERE canonical_key=$1`, f.keys[1]); err != nil {
				t.Fatal(err)
			}
			ids, _, err := source()
			if err != nil || !reflect.DeepEqual(ids, []string{f.keys[0], f.keys[0], f.keys[2]}) {
				t.Fatal("current eligibility was cached", ids, err)
			}
			if _, err := f.db.Exec(`UPDATE wire_label_refresh_state SET last_successful_at=$2 WHERE source_did=$1`, f.labeler, f.now.Add(-time.Hour)); err != nil {
				t.Fatal(err)
			}
			if _, _, err := source(); !errors.Is(err, ErrModerationUnavailable) {
				t.Fatal("stale baseline entered retained fallback", err)
			}
			if _, err := f.db.Exec(`UPDATE wire_label_refresh_state SET last_successful_at=$2 WHERE source_did=$1`, f.labeler, f.now); err != nil {
				t.Fatal(err)
			}
			if _, err := f.db.Exec(`UPDATE `+name+`_generations SET is_active=FALSE,serving_source='simplified_fallback' WHERE generation_id=$1::uuid`, f.id); err != nil {
				t.Fatal(err)
			}
			ids, provenance, err := source()
			if err != nil || len(ids) != 4 || provenance == nil || *provenance != "simplified_fallback" {
				t.Fatal("retained source recovery/provenance", ids, provenance, err)
			}
			if sports {
				if _, err := f.db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, f.catalog); err != nil {
					t.Fatal(err)
				}
				catalog, err := store.Catalog(ctx)
				if err != nil || len(catalog) != 1 || catalog[0].ID != f.entity.ID || store.catalogCache != nil {
					t.Fatal("vanished local lease did not use current entity projection", catalog, err)
				}
			}
			if _, err := f.db.Exec(`UPDATE `+name+`_generations SET expires_at=$2 WHERE generation_id=$1::uuid`, f.id, f.now.Add(-time.Second)); err != nil {
				t.Fatal(err)
			}
			// A second handle intentionally selects the original local path while
			// retaining the same real Wire authority for its simplified fallback.
			// Expiring the retained source must not expose the validation cache's
			// old candidate payload or alter fallback admission/order/provenance.
			otherDB := selectionDB(t)
			if sports {
				old := &SportsStore{DB: otherDB, Wire: f.wire}
				actual, err := store.source(ctx, "zz", f.now)
				expected, oldErr := old.source(ctx, "zz", f.now)
				if err != nil || oldErr != nil || actual.Source == nil || *actual.Source != "simplified_fallback" || expected.Source == nil || *expected.Source != *actual.Source {
					t.Fatal("Sports simplified fallback parity", actual, expected, err, oldErr)
				}
				actualIDs, expectedIDs := []string{}, []string{}
				for _, c := range actual.Candidates {
					actualIDs = append(actualIDs, c.Item.ItemID)
				}
				for _, c := range expected.Candidates {
					expectedIDs = append(expectedIDs, c.Item.ItemID)
				}
				if !reflect.DeepEqual(actualIDs, expectedIDs) {
					t.Fatal("Sports simplified order changed", actualIDs, expectedIDs)
				}
			} else {
				old := &FinanceStore{DB: otherDB, Wire: f.wire, Config: finance.Config}
				actual, err := finance.source(ctx, "zz", f.now)
				expected, oldErr := old.source(ctx, "zz", f.now)
				if err != nil || oldErr != nil || actual.Source == nil || *actual.Source != "simplified_fallback" || expected.Source == nil || *expected.Source != *actual.Source {
					t.Fatal("Finance simplified fallback parity", actual, expected, err, oldErr)
				}
				actualIDs, expectedIDs := []string{}, []string{}
				for _, c := range actual.Candidates {
					actualIDs = append(actualIDs, c.Item.ItemID)
				}
				for _, c := range expected.Candidates {
					expectedIDs = append(expectedIDs, c.Item.ItemID)
				}
				if !reflect.DeepEqual(actualIDs, expectedIDs) {
					t.Fatal("Finance simplified order changed", actualIDs, expectedIDs)
				}
			}
		})
	}
}
