package sportscore

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func TestPresentationFingerprintPreservesUTF8FramingAndNullSummary(t *testing.T) {
	summary := "勝利"
	item := wirecore.FeedItem{Title: "Café", Summary: &summary, Source: wirecore.ItemSource{Domain: "example.test"}}
	// Byte lengths, not Unicode character counts: title=5, summary=6, domain=12.
	sum := sha256.Sum256([]byte("5:CaféS6:勝利12:example.test"))
	if got := PresentationFingerprint(item); got != hex.EncodeToString(sum[:]) {
		t.Fatal(got)
	}
	item.Summary = nil
	null := PresentationFingerprint(item)
	empty := ""
	item.Summary = &empty
	if PresentationFingerprint(item) == null {
		t.Fatal("null summary equals empty summary")
	}
}

func TestPresentationMatchesForcesReanalysisOnChanges(t *testing.T) {
	summary := "Original summary"
	item := wirecore.FeedItem{Title: "Original title", Summary: &summary, Source: wirecore.ItemSource{Domain: "example.test"}}
	for _, lean := range []bool{false, true} {
		candidate := RankCandidate{Item: item}
		if lean {
			candidate.PresentationFingerprint = PresentationFingerprint(item)
			candidate.Item.Summary = nil
		}
		if !candidate.PresentationMatches(item) {
			t.Fatal("unchanged presentation rejected", lean)
		}
		cases := []wirecore.FeedItem{item, item, item, item}
		cases[0].Title = "Edited title"
		changed := "Edited summary"
		cases[1].Summary = &changed
		cases[2].Source.Domain = "other.test"
		cases[3].Summary = nil
		for index, current := range cases {
			if candidate.PresentationMatches(current) {
				t.Fatal("edited presentation accepted", lean, index)
			}
		}
	}
}
