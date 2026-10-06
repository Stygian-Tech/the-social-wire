package financecore

import (
	"math"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

func Rank(candidates []RankCandidate, instrumentIDs, sectorIDs map[string]bool, reserveGlobal bool) []RankCandidate {
	score := func(c RankCandidate) float64 {
		instrument, sector := false, false
		for _, a := range c.Analysis.Associations {
			instrument = instrument || instrumentIDs[a.InstrumentID]
		}
		for _, id := range c.Analysis.SectorIDs {
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
		switch c.Analysis.Materiality {
		case "earnings", "merger":
			materiality = 1.2
		case "filing", "regulation":
			materiality = 1.15
		case "leadership", "announcement":
			materiality = 1.1
		case "price-chatter":
			materiality = .5
		}
		return c.BaseScore * materiality * (1 + min(.35, boost))
	}
	sorted := []RankCandidate{}
	for _, c := range candidates {
		if c.Analysis.Eligible && !math.IsNaN(c.BaseScore) && !math.IsInf(c.BaseScore, 0) && c.BaseScore >= 0 {
			sorted = append(sorted, c)
		}
	}
	sort.SliceStable(sorted, func(i, j int) bool {
		a, b := score(sorted[i]), score(sorted[j])
		if a == b {
			return sorted[i].Item.ItemID < sorted[j].Item.ItemID
		}
		return a > b
	})
	seenIDs, seenURLs := map[string]bool{}, map[string]bool{}
	coverageDates := map[string]time.Time{}
	remaining := []RankCandidate{}
	for _, c := range sorted {
		if seenIDs[c.Item.ItemID] || seenURLs[c.Item.CanonicalURL] {
			continue
		}
		headline := strings.Join(strings.FieldsFunc(strings.ToLower(c.Item.Title), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }), " ")
		entities := []string{}
		for _, a := range c.Analysis.Associations {
			entities = append(entities, a.InstrumentID)
		}
		sort.Strings(entities)
		coverage := headline + "|" + strings.Join(entities, ",")
		if utf8.RuneCountInString(headline) >= 20 && c.Item.PublishedAt != nil {
			if previous, ok := coverageDates[coverage]; ok {
				delta := c.Item.PublishedAt.Sub(previous)
				if delta >= -6*time.Hour && delta <= 6*time.Hour {
					continue
				}
			}
			coverageDates[coverage] = *c.Item.PublishedAt
		}
		seenIDs[c.Item.ItemID], seenURLs[c.Item.CanonicalURL] = true, true
		remaining = append(remaining, c)
	}
	result := make([]RankCandidate, 0, len(remaining))
	for len(remaining) > 0 {
		index := 0
		if reserveGlobal && len(result)%5 == 4 {
			best := -1
			for i, c := range remaining {
				if c.MajorGlobal && (best < 0 || c.BaseScore > remaining[best].BaseScore) {
					best = i
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
