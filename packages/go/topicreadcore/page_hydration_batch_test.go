package topicreadcore

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type hydrationBatchRecorder struct {
	corpuscore.Store
	items    map[string]wirecore.FeedItem
	calls    [][]string
	rejected map[string]bool
}

func (f *hydrationBatchRecorder) Items(_ context.Context, ids []string, _ time.Time) ([]corpuscore.Item, error) {
	f.calls = append(f.calls, append([]string{}, ids...))
	if len(ids) > corpuscore.MaximumBatchItems {
		return nil, fmt.Errorf("oversized hydration batch: %d", len(ids))
	}
	out := []corpuscore.Item{}
	// Provider order is deliberately different from snapshot order.
	for index := len(ids) - 1; index >= 0; index-- {
		if !f.rejected[ids[index]] {
			out = append(out, corpuscore.Item{Item: f.items[ids[index]]})
		}
	}
	return out, nil
}

func TestPostgresPageSizedHydrationAndBoundedRefill(t *testing.T) {
	for _, domain := range []string{"finance", "sports"} {
		for _, test := range []struct {
			name            string
			limit, rejected int
			wantBatches     []int
		}{
			{"first page avoids unused tail", 30, 0, []int{30}},
			{"rejected first batch refills fully", 30, 30, []int{30, 100}},
			{"large page respects transport cap", 150, 0, []int{100, 100}},
		} {
			t.Run(domain+"/"+test.name, func(t *testing.T) {
				db := selectionDB(t)
				now := time.Now().UTC().Truncate(time.Second)
				generation := "dddddddd-5555-5555-5555-555555555555"
				recorder := &hydrationBatchRecorder{items: map[string]wirecore.FeedItem{}, rejected: map[string]bool{}}
				ids := []string{}
				financeCandidates := []financecore.RankCandidate{}
				sportsCandidates := []sportscore.RankCandidate{}
				instrument := financecore.ApplyReviewedMetadata(financecore.ReviewedInstruments()[0])
				entity := sportscore.Entity{ID: "batch-fixture-team", Name: "Fixture Football Club", Kind: "team", Active: true, Aliases: []string{}, CompetitionIDs: []string{}, ProviderIDs: map[string]string{}}
				for index := 0; index < 260; index++ {
					id := fmt.Sprintf("batch-story-%03d", index)
					ids = append(ids, id)
					item := topicItem(id)
					item.CanonicalURL = fmt.Sprintf("https://publisher-%03d.example/story", index)
					item.Source.Name = "Publisher"
					item.Source.Domain = fmt.Sprintf("publisher-%03d.example", index)
					item.Title = fmt.Sprintf("Fixture Football Club wins championship item %03d", index)
					if domain == "finance" {
						item.Title = fmt.Sprintf("Company reports record quarterly earnings item %03d", index)
					}
					recorder.items[id] = item
					if index < test.rejected {
						recorder.rejected[id] = true
					}
					resolver := financecore.ResolverVersion
					financeCandidates = append(financeCandidates, financecore.RankCandidate{Item: item, BaseScore: float64(1000 - index), Analysis: financecore.ArticleAnalysis{ResolverVersion: &resolver, Eligible: true, Materiality: "earnings", Associations: []financecore.Association{{InstrumentID: instrument.ID, Confidence: 1, Evidence: []string{}, ResolverVersion: resolver}}, SectorIDs: []string{}}})
					sportsCandidates = append(sportsCandidates, sportscore.RankCandidate{Item: item, BaseScore: float64(1000 - index), Analysis: sportscore.ArticleAnalysis{ResolverVersion: sportscore.ResolverVersion, Eligible: true, Materiality: "championship", Associations: []sportscore.Association{{EntityID: entity.ID, Confidence: 1, Evidence: []string{}, ResolverVersion: sportscore.ResolverVersion}}, SportIDs: []string{}, CompetitionIDs: []string{}}})
				}
				t.Cleanup(func() {
					db.Exec(`DELETE FROM `+domain+`_generations WHERE generation_id=$1::uuid`, generation)
					if domain == "finance" {
						db.Exec(`DELETE FROM finance_instruments WHERE provider_key='batch-fixture-provider'`)
					} else {
						db.Exec(`DELETE FROM sports_entities WHERE entity_id=$1`, entity.ID)
					}
				})
				var payload []byte
				if domain == "finance" {
					raw, _ := json.Marshal(instrument)
					if _, err := db.Exec(`INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)VALUES($1,'batch-fixture-provider',$2::jsonb,$3)`, instrument.ID, string(raw), now); err != nil {
						t.Fatal(err)
					}
					payload, _ = corpuscore.MarshalHTTP(financeCandidates)
				} else {
					raw, _ := json.Marshal(entity)
					if _, err := db.Exec(`INSERT INTO sports_entities(entity_id,payload,updated_at)VALUES($1,$2::jsonb,$3)`, entity.ID, string(raw), now); err != nil {
						t.Fatal(err)
					}
					payload, _ = corpuscore.MarshalHTTP(sportsCandidates)
				}
				if _, err := db.Exec(`INSERT INTO `+domain+`_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','fixture',$2,$3,$4::jsonb,TRUE)`, generation, now, now.Add(time.Hour), string(payload)); err != nil {
					t.Fatal(err)
				}
				wire, err := NewWireStore(recorder, strings.Repeat("w", 32), "visible", NewModerationService(nil, nil).Cache)
				if err != nil {
					t.Fatal(err)
				}
				var page func(string, int) ([]string, *string, string, error)
				var cursorCodec *TopicCursorCodec
				var scope string
				if domain == "finance" {
					store, err := NewFinanceStore(db, wire, &SelectionProjection{DB: db}, map[string]string{"FINANCE_FEED_MODE": "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("s", 32)})
					if err != nil {
						t.Fatal(err)
					}
					cursorCodec = store.Cursor
					scope = mustHash(t, store.Hasher, "anonymous-finance")
					page = func(cursor string, limit int) ([]string, *string, string, error) {
						value, err := store.Page(context.Background(), cursor, limit, "en", "", false, now, "finance", false)
						out := []string{}
						for _, row := range value.Items {
							out = append(out, row.Story.ItemID)
						}
						return out, value.Cursor, value.PreferenceRevision, err
					}
				} else {
					store, err := NewSportsStore(db, wire, &SelectionProjection{DB: db}, map[string]string{"SPORTS_FEED_MODE": "visible", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("s", 32)})
					if err != nil {
						t.Fatal(err)
					}
					cursorCodec = store.Cursor
					scope = mustHash(t, store.Hasher, "anonymous-sports")
					page = func(cursor string, limit int) ([]string, *string, string, error) {
						value, err := store.Page(context.Background(), cursor, limit, "en", "", false, now, "sports", nil)
						out := []string{}
						for _, row := range value.Items {
							out = append(out, row.Story.ItemID)
						}
						return out, value.Cursor, value.PreferenceRevision, err
					}
				}
				got, cursor, revision, err := page("", test.limit)
				if err != nil || !reflect.DeepEqual(got, ids[test.rejected:test.rejected+test.limit]) || cursor == nil {
					t.Fatal("page order/content", got, err)
				}
				counts := []int{}
				for _, call := range recorder.calls {
					counts = append(counts, len(call))
				}
				if !reflect.DeepEqual(counts, test.wantBatches) {
					t.Fatal("unnecessary hydration tail or unbounded refill", counts, test.wantBatches)
				}
				decoded, err := cursorCodec.Decode(*cursor, "en", revision, scope, domain, now)
				if err != nil || decoded.NextOrdinal != test.rejected+test.limit {
					t.Fatal("cursor advanced over unconsumed hydrated tail", decoded, err)
				}
				next, _, _, err := page(*cursor, 30)
				if err != nil || !reflect.DeepEqual(next, ids[test.rejected+test.limit:test.rejected+test.limit+30]) || len(recorder.calls[len(recorder.calls)-1]) != 30 {
					t.Fatal("continuation changed order or first-batch size", next, err)
				}
			})
		}
	}
}
