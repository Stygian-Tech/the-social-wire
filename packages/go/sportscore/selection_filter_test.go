package sportscore

import (
	"fmt"
	"math"
	"reflect"
	"testing"
	"time"
)

func selectionFilterCatalog(size int) []Entity {
	catalog := []Entity{{ID: "sport", Kind: "sport", Active: true}, {ID: "team", Kind: "team", Active: true}, {ID: "classification", Kind: "classification", Active: true}}
	for i := len(catalog); i < size; i++ {
		catalog = append(catalog, Entity{ID: fmt.Sprintf("other-%d", i), Kind: "team", Active: true})
	}
	return catalog
}

func TestRankSelectionsKeepsOrderAndCandidateFields(t *testing.T) {
	candidates := []RankCandidate{}
	for i, id := range []string{"a", "b", "c", "d", "e", "f"} {
		candidate := sportsCandidate(id)
		candidate.BaseScore = []float64{10, 9, 8, 7, 1, 6}[i]
		if id == "d" {
			candidate.Item.Source.Domain = "other"
			candidate.Analysis.SportIDs = []string{"other-sport"}
		}
		if id == "e" {
			candidate.MajorGlobal = true
		}
		candidates = append(candidates, candidate)
	}
	at := time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC)
	candidates[0].Item.Title = "A sufficiently long same event headline"
	candidates[0].Item.PublishedAt = &at
	duplicate := candidates[0]
	duplicate.Item.ItemID = "duplicate"
	duplicate.Item.CanonicalURL = "https://example.com/duplicate"
	duplicate.BaseScore = .5
	later := at.Add(time.Hour)
	duplicate.Item.PublishedAt = &later
	candidates = append(candidates, duplicate, candidates[0])
	got := RankSelections(candidates, nil, selectionFilterCatalog(100), true)
	expected := []RankCandidate{candidates[0], candidates[1], candidates[3], candidates[2], candidates[4], candidates[5]}
	if !reflect.DeepEqual(got, expected) {
		t.Fatal("ranking changed order, coverage suppression, global reserve or candidate fields", got)
	}
}

func TestSelectionFilterMatchesSingleCandidateRanking(t *testing.T) {
	catalog := selectionFilterCatalog(100)
	type eligibilityCase struct {
		name       string
		selections []Selection
		candidate  RankCandidate
		want       bool
	}
	cases := []eligibilityCase{
		{"no interests", nil, sportsCandidate("a", "team"), true},
		{"personal mute", []Selection{{"team", "mute"}}, sportsCandidate("a", "team"), false},
		{"broad mute", []Selection{{"sport", "mute"}}, sportsCandidate("a", "team"), false},
		{"personal follow overrides broad mute", []Selection{{"sport", "mute"}, {"team", "follow"}}, sportsCandidate("a", "team"), true},
		{"personal mute still wins", []Selection{{"sport", "mute"}, {"team", "follow"}, {"team", "mute"}}, sportsCandidate("a", "team"), false},
		{"classification mute", []Selection{{"classification", "mute"}}, sportsCandidate("a", "classification"), false},
	}
	stale := sportsCandidate("stale", "team")
	stale.Analysis.ResolverVersion = "old"
	ineligible := sportsCandidate("ineligible")
	ineligible.Analysis.Eligible = false
	invalidScore := sportsCandidate("invalid")
	invalidScore.BaseScore = math.NaN()
	cases = append(cases, eligibilityCase{"stale resolver", nil, stale, false}, eligibilityCase{"ineligible", nil, ineligible, false}, eligibilityCase{"nonfinite score", nil, invalidScore, false})
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			filter := NewSelectionFilter(test.selections, catalog)
			if got := filter.Allows(test.candidate); got != test.want {
				t.Fatal(got, test.want)
			}
			if filter.Allows(test.candidate) != (len(RankSelections([]RankCandidate{test.candidate}, test.selections, catalog, false)) != 0) {
				t.Fatal("single-candidate parity")
			}
		})
	}
}

func TestSelectionFilterPerItemAllocationsDoNotScaleWithCatalog(t *testing.T) {
	candidate := sportsCandidate("a", "team")
	selections := []Selection{{"sport", "mute"}, {"team", "follow"}}
	small := NewSelectionFilter(selections, selectionFilterCatalog(10))
	large := NewSelectionFilter(selections, selectionFilterCatalog(50000))
	measure := func(filter *SelectionFilter) float64 {
		return testing.AllocsPerRun(100, func() {
			if !filter.Allows(candidate) {
				panic("expected allowed")
			}
		})
	}
	smallAllocations, largeAllocations := measure(small), measure(large)
	if largeAllocations > smallAllocations+1 {
		t.Fatal("per-item eligibility rebuilt catalog index", smallAllocations, largeAllocations)
	}
}

func BenchmarkSportsPageSelectionEligibility(b *testing.B) {
	catalog := selectionFilterCatalog(5000)
	selections := []Selection{{"sport", "mute"}, {"team", "follow"}}
	candidate := sportsCandidate("a", "team")
	b.Run("RankPerItem", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			for range 50 {
				RankSelections([]RankCandidate{candidate}, selections, catalog, false)
			}
		}
	})
	b.Run("FilterPerPage", func(b *testing.B) {
		b.ReportAllocs()
		for i := 0; i < b.N; i++ {
			filter := NewSelectionFilter(selections, catalog)
			for range 50 {
				filter.Allows(candidate)
			}
		}
	})
}
