package financecore

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestResolverActualSwiftFixtures(t *testing.T) {
	data, err := os.ReadFile("resolver_fixtures.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Catalog []Instrument `json:"catalog"`
		Cases   []struct {
			Title    string          `json:"title"`
			Summary  *string         `json:"summary"`
			Expected json.RawMessage `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, entry := range fixture.Cases {
		t.Run(entry.Title, func(t *testing.T) {
			summary := ""
			if entry.Summary != nil {
				summary = *entry.Summary
			}
			actual, err := json.Marshal(Analyze(entry.Title, summary, nil, nil, fixture.Catalog))
			if err != nil {
				t.Fatal(err)
			}
			var a, b any
			if err := json.Unmarshal(actual, &a); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(entry.Expected, &b); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(a, b) {
				t.Fatalf("actual %s\nexpected %s", actual, entry.Expected)
			}
		})
	}
}
func TestRightsPolicyAndReviewedMetadata(t *testing.T) {
	policy := NewProviderPolicy(map[string]string{})
	for _, i := range ReviewedInstruments() {
		if i.Kind == "crypto" && policy.Permits(i) {
			t.Fatal("crypto activated without rights policy")
		}
	}
	entries := ReviewedEntries()
	if len(entries) < 16 {
		t.Fatal("incomplete metadata")
	}
	entry := entries[0]
	i := Instrument{ID: entry.InstrumentID, Name: "fund", Symbol: entry.ExpectedSymbol, ProviderID: entry.ExpectedProviderID, Kind: "equity", Aliases: []string{}, SectorIDs: []string{}, IsActive: true}
	mapped := ApplyReviewedMetadata(i)
	if mapped.Kind != "etf" || mapped.TradingViewSymbol != nil {
		t.Fatalf("wrong reviewed ETF metadata %+v", mapped)
	}
	i.IsActive = false
	i.TradingViewSymbol = &i.Symbol
	if ApplyReviewedMetadata(i).TradingViewSymbol != nil {
		t.Fatal("inactive listing kept display mapping")
	}
}
