package financecore

import (
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func financialCandidate(id string, score float64) RankCandidate {
	return RankCandidate{Item: wirecore.FeedItem{ItemID: id, CanonicalURL: "https://example.com/" + id, Title: id}, Analysis: ArticleAnalysis{Eligible: true, Materiality: "reporting", Associations: []Association{}, SectorIDs: []string{}}, BaseScore: score}
}
func TestFinanceReservesGlobalSlotAfterPersonalization(t *testing.T) {
	candidates := []RankCandidate{}
	for _, id := range []string{"a", "b", "c", "d", "e", "f"} {
		candidates = append(candidates, financialCandidate(id, 1))
	}
	candidates[5].BaseScore = .1
	candidates[5].MajorGlobal = true
	ranked := Rank(candidates, nil, nil, true)
	if ranked[4].Item.ItemID != "f" {
		t.Fatal("lost global reserve", ranked)
	}
}
func TestFinanceCoverageSuppressionDoesNotReserveDroppedIdentity(t *testing.T) {
	now := time.Unix(1000, 0)
	a := financialCandidate("a", 3)
	a.Item.Title = "An earnings report with substantive coverage"
	a.Item.PublishedAt = &now
	b := a
	b.Item.ItemID = "b"
	b.Item.CanonicalURL = "https://example.com/b"
	b.BaseScore = 2
	c := b
	c.BaseScore = 1
	c.Item.Title = "A different story"
	ranked := Rank([]RankCandidate{a, b, c}, nil, nil, false)
	if len(ranked) != 2 || ranked[1].Item.ItemID != "b" {
		t.Fatal("dropped coverage incorrectly reserved identity", ranked)
	}
}
func TestFinanceIdentityExcludesMutablePresentation(t *testing.T) {
	if len(InstrumentID("openfigi", "BBG000B9Y5X2")) != 36 {
		t.Fatal("identity size")
	}
	if PreferenceFingerprint([]string{"b", "a", "a"}, []string{"s"}) != PreferenceFingerprint([]string{"a", "b"}, []string{"s"}) {
		t.Fatal("fingerprint depends on order")
	}
}
