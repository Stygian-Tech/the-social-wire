package financecore

// Filters ineligible/nonfinite candidates, applies materiality and capped preference
// boosts, breaks ties by item ID, and suppresses duplicate URLs and six-hour
// headline/entity coverage. Optional global slots are filled from remaining candidates by
// base score.

import (
	"math"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Rank orders eligible articles by materiality and preference boosts, deduplicates
// coverage, and optionally reserves every fifth slot for major global news.
func Rank(candidates []RankCandidate, instrumentIDs, sectorIDs map[string]bool, reserveGlobal bool) []RankCandidate {
	score := func(candidate RankCandidate) float64 {
		instrument, sector := false, false
		for _, association := range candidate.Analysis.Associations {
			instrument = instrument || instrumentIDs[association.InstrumentID]
		}
		for _, id := range candidate.Analysis.SectorIDs {
			sector = sector || sectorIDs[id]
		}
		boost := 0.0
		if instrument {
			boost += .25
		}
		if sector {
			boost += .1
		}
		materiality := 1.0
		switch candidate.Analysis.Materiality {
		case "earnings", "merger":
			materiality = 1.2
		case "filing", "regulation":
			materiality = 1.15
		case "leadership", "announcement":
			materiality = 1.1
		case "price-chatter":
			materiality = .5
		}
		return candidate.BaseScore * materiality * (1 + min(.35, boost))
	}
	sorted := []RankCandidate{}
	for _, candidate := range candidates {
		if candidate.Analysis.Eligible && !math.IsNaN(candidate.BaseScore) && !math.IsInf(candidate.BaseScore, 0) && candidate.BaseScore >= 0 {
			sorted = append(sorted, candidate)
		}
	}
	sort.SliceStable(sorted, func(itemIndex, comparisonIndex int) bool {
		leftScore, rightScore := score(sorted[itemIndex]), score(sorted[comparisonIndex])
		if leftScore == rightScore {
			return sorted[itemIndex].Item.ItemID < sorted[comparisonIndex].Item.ItemID
		}
		return leftScore > rightScore
	})
	seenIDs, seenURLs := map[string]bool{}, map[string]bool{}
	coverageDates := map[string]time.Time{}
	remaining := []RankCandidate{}
	for _, candidate := range sorted {
		if seenIDs[candidate.Item.ItemID] || seenURLs[candidate.Item.CanonicalURL] {
			continue
		}
		headline := strings.Join(strings.FieldsFunc(strings.ToLower(candidate.Item.Title), func(character rune) bool { return !unicode.IsLetter(character) && !unicode.IsNumber(character) }), " ")
		entities := []string{}
		for _, association := range candidate.Analysis.Associations {
			entities = append(entities, association.InstrumentID)
		}
		sort.Strings(entities)
		coverage := headline + "|" + strings.Join(entities, ",")
		if utf8.RuneCountInString(headline) >= 20 && candidate.Item.PublishedAt != nil {
			if previous, ok := coverageDates[coverage]; ok {
				delta := candidate.Item.PublishedAt.Sub(previous)
				if delta >= -6*time.Hour && delta <= 6*time.Hour {
					continue
				}
			}
			coverageDates[coverage] = *candidate.Item.PublishedAt
		}
		seenIDs[candidate.Item.ItemID], seenURLs[candidate.Item.CanonicalURL] = true, true
		remaining = append(remaining, candidate)
	}
	result := make([]RankCandidate, 0, len(remaining))
	for len(remaining) > 0 {
		index := 0
		if reserveGlobal && len(result)%5 == 4 {
			best := -1
			for itemIndex, candidate := range remaining {
				if candidate.MajorGlobal && (best < 0 || candidate.BaseScore > remaining[best].BaseScore) {
					best = itemIndex
				}
			}
			if best >= 0 {
				index = best
			}
		}
		result = append(result, remaining[index])
		remaining = append(remaining[:index], remaining[index+1:]...)
	}
	return result
}
