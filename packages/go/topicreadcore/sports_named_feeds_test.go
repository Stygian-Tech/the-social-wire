package topicreadcore

import (
	"reflect"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func TestGlobalSportsDefinitionMatchesCatalogDefinition(t *testing.T) {
	catalog := []sportscore.Entity{{ID: "team", Name: "Team", Kind: "team", Active: true}}
	definition, ok := sportsDefinition("sports", catalog)
	if !ok || !reflect.DeepEqual(definition, SportsDefinitions(catalog)[0]) {
		t.Fatal("global lookup differs from public catalog definition")
	}
	if _, ok := sportsDefinition("missing", catalog); ok {
		t.Fatal("unknown named feed accepted")
	}
}

func BenchmarkGlobalSportsDefinition(b *testing.B) {
	catalog := make([]sportscore.Entity, 27828)
	for i := range catalog {
		catalog[i] = sportscore.Entity{ID: "team", Name: "Team", Kind: "team", Active: true}
	}
	b.ResetTimer()
	for range b.N {
		if _, ok := sportsDefinition("sports", catalog); !ok {
			b.Fatal("missing global feed")
		}
	}
}
