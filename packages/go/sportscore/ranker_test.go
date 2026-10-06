package sportscore

import (
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func sportsCandidate(id string, associated ...string) RankCandidate {
	associations := []Association{}
	for _, entity := range associated {
		associations = append(associations, Association{EntityID: entity, Confidence: 1, ResolverVersion: ResolverVersion})
	}
	return RankCandidate{Item: wirecore.FeedItem{ItemID: id, CanonicalURL: "https://example.com/" + id, Title: id, Source: wirecore.ItemSource{Domain: "same"}}, Analysis: ArticleAnalysis{ResolverVersion: ResolverVersion, Eligible: true, Materiality: "reporting", Associations: associations, SportIDs: []string{"sport"}}, BaseScore: 1}
}
func TestPersonalFollowOverridesBroadMuteOnly(t *testing.T) {
	catalog := []Entity{{ID: "sport", Kind: "sport", Active: true}, {ID: "team", Kind: "team", Active: true}}
	candidate := sportsCandidate("a", "team")
	if got := Rank([]RankCandidate{candidate}, map[string]bool{"team": true}, map[string]bool{"sport": true}, catalog, false); len(got) != 1 {
		t.Fatal("team follow did not override sport mute")
	}
	if got := Rank([]RankCandidate{candidate}, map[string]bool{"team": true}, map[string]bool{"team": true}, catalog, false); len(got) != 0 {
		t.Fatal("follow overrode explicit team mute")
	}
}
func TestSportsRejectsStaleResolverEvidence(t *testing.T) {
	c := sportsCandidate("a")
	c.Analysis.ResolverVersion = "old"
	if len(Rank([]RankCandidate{c}, nil, nil, nil, false)) != 0 {
		t.Fatal("accepted old resolver")
	}
}
func TestSportsHierarchyCycleTerminates(t *testing.T) {
	a, b := "a", "b"
	catalog := []Entity{{ID: a, Kind: "sport", SportID: &b, Active: true}, {ID: b, Kind: "sport", SportID: &a, Active: true}}
	ancestors := Ancestors(map[string]bool{a: true}, ParentIDs(catalog))
	if len(ancestors) != 2 {
		t.Fatal(ancestors)
	}
}
func TestSportsPreferenceAndSelectionIdentity(t *testing.T) {
	if PreferenceFingerprint([]Selection{{"team", "follow"}, {"sport", "mute"}, {"team", "follow"}}) != PreferenceFingerprint([]Selection{{"sport", "mute"}, {"team", "follow"}}) {
		t.Fatal("fingerprint mismatch")
	}
	if Normalize("MÜNCHEN -- wins!") != "munchen wins" {
		t.Fatal("normalize mismatch")
	}
}
