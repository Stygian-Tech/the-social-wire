package sportscore

import (
	"testing"
	"time"
)

func TestServingCatalogRevisionSwiftISOFixture(t *testing.T) {
	entity := Entity{ID: "team", Name: "T/Club", Kind: "team", CompetitionIDs: []string{"b", "a"}, Aliases: []string{"Z", "A"}, ProviderIDs: map[string]string{}, Memberships: []Membership{{EntityID: "league", ValidFrom: time.Unix(1791342121, 765000000).UTC()}}, Active: true}
	revision, err := ServingCatalogRevision([]Entity{entity})
	if err != nil || revision != "390128d56abebd437f2de10da8a940a515fc1251bc140a2f0677fe924e1bf8ce" {
		t.Fatal(revision, err)
	}
	worker, err := CatalogRevision([]Entity{entity})
	if err != nil || worker == revision {
		t.Fatal("worker and serving revisions conflated", worker, err)
	}
}
