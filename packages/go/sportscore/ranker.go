package sportscore

// Requires current resolver evidence and finite eligible candidates. Explicit personal
// mutes win; a direct personal follow can override a broad mute. Materiality and capped
// follow boosts precede duplicate/coverage suppression, optional global slots, and bounded
// domain/sport diversification.

import (
	"math"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// RankSelections converts follow/mute selections to sets and delegates to Rank.
func RankSelections(candidates []RankCandidate, selections []Selection, catalog []Entity, reserveGlobal bool) []RankCandidate {
	follows, mutes := set(nil), set(nil)
	for _, selection := range selections {
		if selection.Action == "follow" {
			follows[selection.Reference] = true
		}
		if selection.Action == "mute" {
			mutes[selection.Reference] = true
		}
	}
	return Rank(candidates, follows, mutes, catalog, reserveGlobal)
}

// Rank applies current-evidence and mute precedence, personalization, duplicate
// suppression, global reserves, and domain/sport diversity.
func Rank(candidates []RankCandidate, follows, mutes map[string]bool, entities []Entity, reserveGlobal bool) []RankCandidate {
	byID := map[string]Entity{}
	for _, entity := range entities {
		if _, ok := byID[entity.ID]; !ok {
			byID[entity.ID] = entity
		}
	}
	parents := ParentIDs(entities)
	direct := func(candidate RankCandidate) map[string]bool {
		ids := set(nil)
		for _, association := range candidate.Analysis.Associations {
			if association.Confidence >= .9 && association.ResolverVersion == ResolverVersion {
				ids[association.EntityID] = true
			}
		}
		return ids
	}
	broad := func(candidate RankCandidate) map[string]bool {
		ids := Ancestors(set(candidate.Analysis.SportIDs), parents)
		for _, id := range candidate.Analysis.CompetitionIDs {
			ids[id] = true
		}
		for id := range direct(candidate) {
			if byID[id].Kind == "classification" {
				ids[id] = true
			}
		}
		return ids
	}
	personal := func(id string) bool {
		switch byID[id].Kind {
		case "team", "national-side", "athlete", "driver", "ncaa-team":
			return true
		}
		return false
	}
	permitted := func(candidate RankCandidate) bool {
		ids := direct(candidate)
		for id := range ids {
			if mutes[id] && personal(id) {
				return false
			}
		}
		if !intersects(broad(candidate), mutes) && !intersects(ids, mutes) {
			return true
		}
		for id := range ids {
			if follows[id] && !mutes[id] && personal(id) {
				return true
			}
		}
		return false
	}
	score := func(candidate RankCandidate) float64 {
		boost := 0.0
		for id := range direct(candidate) {
			if follows[id] && personal(id) {
				boost += .25
				break
			}
		}
		for id := range broad(candidate) {
			if byID[id].Kind != "sport" && follows[id] {
				boost += .1
				break
			}
		}
		if intersects(Ancestors(set(candidate.Analysis.SportIDs), parents), follows) {
			boost += .05
		}
		materiality := 1.0
		switch candidate.Analysis.Materiality {
		case "championship", "record":
			materiality = 1.2
		case "transfer", "injury", "disciplinary":
			materiality = 1.15
		case "organizational-change", "consequential-game":
			materiality = 1.1
		case "routine-chatter":
			materiality = .45
		}
		return candidate.BaseScore * materiality * (1 + min(.35, boost))
	}
	sorted := []RankCandidate{}
	for _, candidate := range candidates {
		if candidate.Analysis.Eligible && candidate.Analysis.ResolverVersion == ResolverVersion && !math.IsNaN(candidate.BaseScore) && !math.IsInf(candidate.BaseScore, 0) && candidate.BaseScore >= 0 && permitted(candidate) {
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
	seenIDs, seenURLs := set(nil), set(nil)
	dates := map[string]time.Time{}
	remaining := []RankCandidate{}
	for _, candidate := range sorted {
		// Swift inserts the ID before trying the URL, and reserves both before
		// coverage suppression. Preserve those duplicate-identity semantics.
		if seenIDs[candidate.Item.ItemID] {
			continue
		}
		seenIDs[candidate.Item.ItemID] = true
		if seenURLs[candidate.Item.CanonicalURL] {
			continue
		}
		seenURLs[candidate.Item.CanonicalURL] = true
		title := Normalize(candidate.Item.Title)
		ids := []string{}
		for id := range direct(candidate) {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		coverage := title + "|" + strings.Join(ids, ",")
		if utf8.RuneCountInString(title) >= 20 && candidate.Item.PublishedAt != nil {
			if old, ok := dates[coverage]; ok {
				delta := candidate.Item.PublishedAt.Sub(old)
				if delta >= -6*time.Hour && delta <= 6*time.Hour {
					continue
				}
			}
			dates[coverage] = *candidate.Item.PublishedAt
		}
		remaining = append(remaining, candidate)
	}
	result := make([]RankCandidate, 0, len(remaining))
	for len(remaining) > 0 {
		position, global := 0, -1
		if reserveGlobal && len(result)%5 == 4 {
			for itemIndex, candidate := range remaining {
				if candidate.MajorGlobal && (global < 0 || candidate.BaseScore > remaining[global].BaseScore) {
					global = itemIndex
				}
			}
		}
		if global >= 0 {
			position = global
		} else if len(result) >= 2 {
			recent := result[len(result)-2:]
			domains, sports := set(nil), set(nil)
			for _, candidate := range recent {
				domains[candidate.Item.Source.Domain] = true
				for _, id := range candidate.Analysis.SportIDs {
					sports[id] = true
				}
			}
			top := score(remaining[0])
			for itemIndex, candidate := range remaining {
				if score(candidate) >= top*.7 && (len(domains) != 1 || !domains[candidate.Item.Source.Domain]) && (len(sports) != 1 || !intersects(set(candidate.Analysis.SportIDs), sports)) {
					position = itemIndex
					break
				}
			}
		}
		result = append(result, remaining[position])
		remaining = append(remaining[:position], remaining[position+1:]...)
	}
	return result
}
