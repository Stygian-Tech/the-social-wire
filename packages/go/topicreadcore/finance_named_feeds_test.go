package topicreadcore

import (
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"reflect"
	"testing"
)

func TestGlobalFinanceLookupMatchesPublicDefinition(t *testing.T) {
	catalogs := [][]financecore.Instrument{nil, {}, {{ID: "inactive", Kind: "stock", IsActive: false}}, financecore.ReviewedInstruments()}
	for _, catalog := range catalogs {
		definition, ok := financeDefinition("finance", catalog)
		public := FinanceDefinitions(catalog)
		if !ok || len(public) == 0 || !reflect.DeepEqual(definition, public[0]) {
			t.Fatal(definition, public, ok)
		}
		if definition.InstrumentIDs == nil || definition.SectorIDs == nil {
			t.Fatal("global collections must remain empty arrays")
		}
	}
}

func TestFinanceDefinitionLookupRetainsNamedCatalogAndUnknownBehavior(t *testing.T) {
	catalog := financecore.ReviewedInstruments()
	for _, definition := range FinanceDefinitions(catalog) {
		got, ok := financeDefinition(definition.ID, catalog)
		if !ok || !reflect.DeepEqual(got, definition) {
			t.Fatal(definition.ID, got, ok)
		}
	}
	if _, ok := financeDefinition("unknown", catalog); ok {
		t.Fatal("unknown feed accepted")
	}
}

func BenchmarkGlobalFinanceDefinitionLookup(b *testing.B) {
	catalog := make([]financecore.Instrument, 5000)
	for i := range catalog {
		catalog[i] = financecore.Instrument{ID: fmt.Sprintf("fixture-%d", i), Name: "Fixture", Symbol: fmt.Sprintf("F%d", i), Kind: "stock", IsActive: true, SectorIDs: []string{"technology"}}
	}
	b.Run("PublicDefinitionsScan", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			for _, definition := range FinanceDefinitions(catalog) {
				if definition.ID == "finance" {
					break
				}
			}
		}
	})
	b.Run("DirectGlobalLookup", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			definition, ok := financeDefinition("finance", catalog)
			if !ok || definition.ID != "finance" {
				b.Fatal(definition, ok)
			}
		}
	})
}
