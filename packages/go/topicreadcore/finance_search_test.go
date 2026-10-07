package topicreadcore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type financeProviderFixture struct {
	calls int
	items []financecore.Instrument
}

func (p *financeProviderFixture) Search(context.Context, string) ([]financecore.Instrument, error) {
	p.calls++
	return p.items, nil
}
func TestFinanceSearchOpaqueReferencesBudgetAndMetadataRetention(t *testing.T) {
	db := selectionDB(t)
	ctx := context.Background()
	now := time.Now().UTC()
	provider := &financeProviderFixture{items: []financecore.Instrument{{ID: "fin_topic_provider", ProviderID: "topic-provider", Name: "Topic Fixture Corporation", Symbol: "TOPIC", Kind: "equity", IsActive: true, Aliases: []string{}, SectorIDs: []string{}}}}
	config := FinanceConfig{Mode: "visible", Rights: true, Policy: financecore.NewProviderPolicy(nil)}
	first := &FinanceStore{DB: db, Config: config, Provider: provider, searchCache: map[string]financeSearchEntry{}}
	second := &FinanceStore{DB: db, Config: config, Provider: provider, searchCache: map[string]financeSearchEntry{}}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM finance_instruments WHERE provider_key='topic-provider'`)
		db.Exec(`DELETE FROM finance_provider_request_budget WHERE provider_key='openfigi-search'`)
	})
	db.Exec(`DELETE FROM finance_provider_request_budget WHERE provider_key='openfigi-search'`)
	if values, err := first.Instruments(ctx, "fin_missing_opaque", now); err != nil || len(values) != 0 || provider.calls != 0 {
		t.Fatal(values, err, provider.calls)
	}
	values, err := first.Instruments(ctx, "Topic Fixture", now)
	if err != nil || len(values) != 1 || provider.calls != 1 {
		t.Fatal(values, err, provider.calls)
	}
	if _, err = second.Instruments(ctx, "other fixture", now.Add(time.Second)); err != nil || provider.calls != 1 {
		t.Fatal("cross-replica provider budget bypass", err, provider.calls)
	}
	stored := provider.items[0]
	stored.Aliases = []string{"reviewed alias"}
	stored.SectorIDs = []string{"technology"}
	symbol := "EXCHANGE:TOPIC"
	stored.TradingViewSymbol = &symbol
	raw, _ := json.Marshal(stored)
	if _, err = db.Exec(`UPDATE finance_instruments SET payload=$1::jsonb WHERE provider_key='topic-provider'`, raw); err != nil {
		t.Fatal(err)
	}
	provider.items[0].Symbol = "CHANGED"
	provider.items[0].Aliases = []string{"provider alias"}
	if _, err = second.Instruments(ctx, "new provider query", now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	var payload []byte
	if err = db.QueryRow(`SELECT payload::text FROM finance_instruments WHERE provider_key='topic-provider'`).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var actual financecore.Instrument
	if json.Unmarshal(payload, &actual) != nil || len(actual.Aliases) != 1 || actual.Aliases[0] != "reviewed alias" || actual.TradingViewSymbol != nil || len(actual.SectorIDs) != 1 {
		t.Fatal(string(payload))
	}
}
func TestOpenFIGISearchRetriesBoundsAndIdentity(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != "POST" || r.Header.Get("X-OPENFIGI-APIKEY") != "private-key" {
			t.Error("provider request contract")
		}
		var body map[string]string
		if json.NewDecoder(r.Body).Decode(&body) != nil || body["query"] != "Apple" {
			t.Error("query contract")
		}
		if calls < 3 {
			w.WriteHeader(503)
			return
		}
		w.Write([]byte(`{"data":[{"figi":"BBG_TEST","name":"Apple","ticker":"AAPL","securityType2":"Common Stock","exchCode":"US"}]}`))
	}))
	defer server.Close()
	key := "private-key"
	provider := NewOpenFIGISearch(&key, server.Client())
	provider.URL = server.URL
	items, err := provider.Search(context.Background(), "Apple")
	if err != nil || calls != 3 || len(items) != 1 || items[0].ID != financecore.InstrumentID("openfigi", "BBG_TEST") || !items[0].IsActive {
		t.Fatal(items, err, calls)
	}
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{"error":null,"data":[]}`)) }))
	defer bad.Close()
	provider.URL = bad.URL
	if _, err = provider.Search(context.Background(), strings.Repeat("x", 5)); err == nil {
		t.Fatal("provider error envelope accepted")
	}
}
