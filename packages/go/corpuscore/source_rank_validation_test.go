package corpuscore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"math"
	"strings"
	"testing"
)

func TestSourceRankValidationBounds(t *testing.T) {
	for _, value := range []float64{-1, math.NaN(), math.Inf(1), math.Inf(-1)} {
		candidate := (*sportsSourceFixture(t).Candidates)[0]
		candidate.BaseScore = value
		if validSportsSourceCandidate(candidate) {
			t.Fatal("invalid Sports score", value)
		}
		generation := *financeSourceFixture().Generation
		generation.Candidates[0].BaseScore = value
		if validFinanceGeneration(generation) {
			t.Fatal("invalid Finance score", value)
		}
	}
	for _, value := range []float64{-.01, 1.01, math.NaN(), math.Inf(1)} {
		candidate := (*sportsSourceFixture(t).Candidates)[0]
		candidate.Analysis.Associations = []sportscore.Association{{Confidence: value, Evidence: []string{}}}
		if validSportsSourceCandidate(candidate) {
			t.Fatal("invalid Sports confidence", value)
		}
		generation := *financeSourceFixture().Generation
		generation.Candidates[0].Analysis.Associations[0].Confidence = value
		if validFinanceGeneration(generation) {
			t.Fatal("invalid Finance confidence", value)
		}
	}
	for _, mutate := range []func(*SportsSourceCandidate){
		func(c *SportsSourceCandidate) { c.PresentationFingerprint = strings.Repeat("a", 65) },
		func(c *SportsSourceCandidate) { c.Analysis.Associations = make([]sportscore.Association, 101) },
		func(c *SportsSourceCandidate) {
			c.Analysis.Associations = []sportscore.Association{{Confidence: .95, Evidence: make([]string, 21)}}
		},
		func(c *SportsSourceCandidate) { c.ItemID = "" },
	} {
		candidate := (*sportsSourceFixture(t).Candidates)[0]
		mutate(&candidate)
		if validSportsSourceCandidate(candidate) {
			t.Fatal("unbounded Sports rank source accepted")
		}
	}
	generation := *financeSourceFixture().Generation
	generation.Candidates[0].Analysis.ResolverVersion = nil
	if !validFinanceGeneration(generation) {
		t.Fatal("changed legacy optional Finance resolver semantics")
	}
}
