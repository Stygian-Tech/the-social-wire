package topicreadcore

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func TestSportsCatalogIndexesRequireExactImmutableCatalog(t *testing.T) {
	original := []sportscore.Entity{{ID: "team", Name: "Original", Kind: "team", Active: true}}
	store := &SportsStore{catalogCache: &sportsPageCatalogCache{revision: "r1", entities: original}}
	first, err := store.pageCatalogIndexes(context.Background(), original)
	if err != nil {
		t.Fatal(err)
	}
	again, err := store.pageCatalogIndexes(context.Background(), original)
	if err != nil || first != again {
		t.Fatal("same catalog rebuilt", err)
	}
	changed := []sportscore.Entity{{ID: "team", Name: "Changed", Kind: "team", Active: true}}
	// Equal length and entity ID do not authorize reusing a different catalog.
	uncached, err := store.pageCatalogIndexes(context.Background(), changed)
	if err != nil || uncached == first || uncached.byID["team"].Name != "Changed" {
		t.Fatal("different slice reused", err)
	}
	store.catalogMu.Lock()
	store.catalogCache = &sportsPageCatalogCache{revision: "r2", entities: changed}
	store.catalogMu.Unlock()
	updated, err := store.pageCatalogIndexes(context.Background(), changed)
	if err != nil || updated == first || updated.byID["team"].Name != "Changed" {
		t.Fatal("changed revision reused", err)
	}
	if first.byID["team"].Name != "Original" {
		t.Fatal("in-flight old catalog changed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.pageCatalogIndexes(ctx, changed); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestSportsCatalogIndexesConcurrentViewerPreferencesStayIsolated(t *testing.T) {
	catalog := []sportscore.Entity{{ID: "team", Name: "Team", Kind: "team", Active: true}}
	store := &SportsStore{catalogCache: &sportsPageCatalogCache{revision: "r1", entities: catalog}}
	candidate := sportscore.RankCandidate{BaseScore: 1, Analysis: sportscore.ArticleAnalysis{Eligible: true, ResolverVersion: sportscore.ResolverVersion, Associations: []sportscore.Association{{EntityID: "team", Confidence: 1, ResolverVersion: sportscore.ResolverVersion}}}}
	indexes, err := store.pageCatalogIndexes(context.Background(), catalog)
	if err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	for viewer := 0; viewer < 100; viewer++ {
		group.Add(1)
		go func(viewer int) {
			defer group.Done()
			shared, err := store.pageCatalogIndexes(context.Background(), catalog)
			if err != nil || shared != indexes {
				t.Error("catalog indexes not shared", err)
				return
			}
			selections := []sportscore.Selection{{Reference: "team", Action: "follow"}}
			if viewer%2 == 0 {
				selections = []sportscore.Selection{{Reference: "team", Action: "mute"}}
			}
			filter := shared.selections.WithSelections(selections)
			selections[0].Action = "mute" // The filter owns independent preference maps.
			if got := filter.Allows(candidate); got != (viewer%2 != 0) {
				t.Errorf("viewer %d eligibility=%t", viewer, got)
			}
			if !shared.selections.Allows(candidate) {
				t.Error("viewer changed catalog's preference-free filter")
			}
		}(viewer)
	}
	group.Wait()
}

func BenchmarkSportsPageCatalogIndexes(b *testing.B) {
	catalog := make([]sportscore.Entity, 27828)
	for i := range catalog {
		catalog[i] = sportscore.Entity{ID: string(rune(i + 1)), Name: "Fixture", Kind: "athlete", Active: true}
	}
	store := &SportsStore{catalogCache: &sportsPageCatalogCache{revision: "fixture", entities: catalog}}
	store.pageCatalogIndexes(context.Background(), catalog)
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		indexes, _ := store.pageCatalogIndexes(context.Background(), catalog)
		indexes.selections.WithSelections([]sportscore.Selection{{Reference: "fixture", Action: "mute"}})
	}
}
