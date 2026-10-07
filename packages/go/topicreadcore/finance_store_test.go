package topicreadcore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"testing"
	"time"
)

type financeWireFixture struct {
	corpuscore.Store
	items map[string]wirecore.FeedItem
}

func (f *financeWireFixture) Item(_ context.Context, id string, _ time.Time) (*corpuscore.Item, error) {
	item, ok := f.items[id]
	if !ok {
		return nil, nil
	}
	return &corpuscore.Item{Item: item}, nil
}
func TestFinancePostgresContinuationLiveEditsAndViewerBinding(t *testing.T) {
	db := selectionDB(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	generation := "77777777-1111-1111-1111-111111111111"
	instrument := financecore.ReviewedInstruments()[0]
	instrument = financecore.ApplyReviewedMetadata(instrument)
	raw, _ := json.Marshal(instrument)
	if _, err := db.Exec(`INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)VALUES($1,$2,$3::jsonb,$4)`, instrument.ID, "topic-fixture-finance", raw, now); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM finance_generations WHERE generation_id=$1::uuid`, generation)
		db.Exec(`DELETE FROM finance_instruments WHERE provider_key='topic-fixture-finance'`)
	})
	fixture := &financeWireFixture{items: map[string]wirecore.FeedItem{}}
	candidates := []financecore.RankCandidate{}
	for index, title := range []string{"Apple reports record earnings and revenue", "Apple announces semiconductor investment deal", "Apple publishes quarterly financial regulation filing"} {
		id := string(rune('a' + index))
		item := topicItem(id)
		item.Title = title
		item.Source.Domain = "apple.com"
		fixture.items[id] = item
		analysis := financecore.Analyze(title, "", []string{instrument.ID}, nil, []financecore.Instrument{instrument})
		if !analysis.Eligible {
			t.Fatal("invalid fixture analysis", analysis)
		}
		candidates = append(candidates, financecore.RankCandidate{Item: item, Analysis: analysis, BaseScore: float64(3 - index)})
	}
	payload, _ := corpuscore.MarshalHTTP(candidates)
	if _, err := db.Exec(`INSERT INTO finance_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','finance-v1',$2,$3,$4::jsonb,TRUE)`, generation, now, now.Add(time.Hour), payload); err != nil {
		t.Fatal(err)
	}
	moderation := NewModerationService(nil, nil)
	wire, err := NewWireStore(fixture, strings.Repeat("a", 32), "visible", moderation.Cache)
	if err != nil {
		t.Fatal(err)
	}
	store, err := NewFinanceStore(db, wire, &SelectionProjection{DB: db}, map[string]string{"FINANCE_FEED_MODE": "visible", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true", "WIRE_CURSOR_HMAC_SECRET": strings.Repeat("b", 32)})
	if err != nil {
		t.Fatal(err)
	}
	page, err := store.Page(ctx, "", 1, "en", "", false, now, "finance", false)
	if err != nil || len(page.Items) != 1 || page.Cursor == nil {
		t.Fatal(page, err)
	}
	decoded, err := store.Cursor.Decode(*page.Cursor, "en", page.PreferenceRevision, mustHash(t, store.Hasher, "anonymous-finance"), "finance", now)
	if err != nil || decoded.NextOrdinal != 1 || decoded.ExpiresAt != topicExpiry(now.Add(time.Hour)) {
		t.Fatal(decoded, err)
	}
	second := fixture.items["b"]
	second.Title = "Cooking oil recipe for tonight"
	second.Source.Domain = "recipes.example"
	fixture.items["b"] = second
	next, err := store.Page(ctx, *page.Cursor, 1, "en", "", false, now, "finance", false)
	if err != nil || len(next.Items) != 1 || next.Items[0].Story.ItemID != "c" || next.Cursor != nil {
		t.Fatal(next, err)
	}
	if _, err = store.Page(ctx, *page.Cursor, 1, "en", "different-viewer", false, now, "finance", false); !errors.Is(err, ErrInvalidCursor) {
		t.Fatal("cross viewer cursor accepted", err)
	}
	if _, err = store.Page(ctx, *page.Cursor, 1, "en", "", false, now.Add(2*time.Hour), "finance", false); !errors.Is(err, ErrCursorExpired) {
		t.Fatal(err)
	}
}
func mustHash(t *testing.T, h *wirecore.ActorHasher, value string) string {
	t.Helper()
	hash, err := h.Hash(value)
	if err != nil {
		t.Fatal(err)
	}
	return hash
}
func TestFinanceNamedFeedContextAndCryptoBoundary(t *testing.T) {
	catalog := financecore.ReviewedInstruments()
	for index, i := range catalog {
		catalog[index] = financecore.ApplyReviewedMetadata(i)
	}
	for _, test := range []struct {
		feed, title string
		expected    bool
	}{{"industry:oil-gas", "Oil industry companies report record revenue", true}, {"industry:oil-gas", "Cooking oil companies report revenue", false}, {"industry:mining", "Bitcoin mining revenue surges", false}, {"industry:software", "Software company earnings rise", true}, {"industry:software", "New phone includes software and accessories", false}} {
		definition, ok := financeDefinition(test.feed, catalog)
		if !ok {
			t.Fatal(test.feed)
		}
		analysis := financecore.Analyze(test.title, "", nil, nil, catalog)
		if got := definition.Matches(analysis, test.title, nil); got != test.expected {
			t.Fatal(test, analysis, got)
		}
	}
	analysis := financecore.Analyze("Bitcoin earnings and cryptocurrency investment", "", nil, nil, catalog)
	if !financeCryptoStory("Bitcoin earnings and cryptocurrency investment", nil, analysis, catalog) {
		t.Fatal("crypto boundary missing")
	}
	if len(FinanceSectors()) != 10 {
		t.Fatal("taxonomy drift")
	}
	if _, ok := financeDefinition("group:mag7", catalog); ok {
		t.Fatal("partial Mag7 group published")
	}
	for _, entry := range financecore.ReviewedEntries() {
		catalog = append(catalog, financecore.Instrument{ID: entry.InstrumentID, ProviderID: entry.ExpectedProviderID, Symbol: entry.ExpectedSymbol, Name: entry.ExpectedSymbol, Kind: "equity", IsActive: true, Aliases: []string{}, SectorIDs: []string{}})
	}
	if _, ok := financeDefinition("group:mag7", catalog); !ok {
		t.Fatal("complete reviewed Mag7 identities unavailable")
	}

}
