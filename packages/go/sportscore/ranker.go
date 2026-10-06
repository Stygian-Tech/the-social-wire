package sportscore

import (
	"math"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

func RankSelections(candidates []RankCandidate, selections []Selection, catalog []Entity, reserveGlobal bool) []RankCandidate {
	follows, mutes := set(nil), set(nil)
	for _, s := range selections {
		if s.Action == "follow" {
			follows[s.Reference] = true
		}
		if s.Action == "mute" {
			mutes[s.Reference] = true
		}
	}
	return Rank(candidates, follows, mutes, catalog, reserveGlobal)
}
func Rank(candidates []RankCandidate, follows, mutes map[string]bool, entities []Entity, reserveGlobal bool) []RankCandidate {
	byID := map[string]Entity{}
	for _, e := range entities {
		if _, ok := byID[e.ID]; !ok {
			byID[e.ID] = e
		}
	}
	parents := ParentIDs(entities)
	direct := func(c RankCandidate) map[string]bool {
		ids := set(nil)
		for _, a := range c.Analysis.Associations {
			if a.Confidence >= .9 && a.ResolverVersion == ResolverVersion {
				ids[a.EntityID] = true
			}
		}
		return ids
	}
	broad := func(c RankCandidate) map[string]bool {
		ids := Ancestors(set(c.Analysis.SportIDs), parents)
		for _, id := range c.Analysis.CompetitionIDs {
			ids[id] = true
		}
		for id := range direct(c) {
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
	permitted := func(c RankCandidate) bool {
		ids := direct(c)
		for id := range ids {
			if mutes[id] && personal(id) {
				return false
			}
		}
		if !intersects(broad(c), mutes) && !intersects(ids, mutes) {
			return true
		}
		for id := range ids {
			if follows[id] && !mutes[id] && personal(id) {
				return true
			}
		}
		return false
	}
	score := func(c RankCandidate) float64 {
		boost := 0.0
		for id := range direct(c) {
			if follows[id] && personal(id) {
				boost += .25
				break
			}
		}
		for id := range broad(c) {
			if byID[id].Kind != "sport" && follows[id] {
				boost += .1
				break
			}
		}
		if intersects(Ancestors(set(c.Analysis.SportIDs), parents), follows) {
			boost += .05
		}
		materiality := 1.0
		switch c.Analysis.Materiality {
		case "championship", "record":
			materiality = 1.2
		case "transfer", "injury", "disciplinary":
			materiality = 1.15
		case "organizational-change", "consequential-game":
			materiality = 1.1
		case "routine-chatter":
			materiality = .45
		}
		return c.BaseScore * materiality * (1 + min(.35, boost))
	}
	sorted := []RankCandidate{}
	for _, c := range candidates {
		if c.Analysis.Eligible && c.Analysis.ResolverVersion == ResolverVersion && !math.IsNaN(c.BaseScore) && !math.IsInf(c.BaseScore, 0) && c.BaseScore >= 0 && permitted(c) {
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
	seenIDs, seenURLs := set(nil), set(nil)
	dates := map[string]time.Time{}
	remaining := []RankCandidate{}
	for _, c := range sorted {
		// Swift inserts the ID before trying the URL, and reserves both before
		// coverage suppression. Preserve those duplicate-identity semantics.
		if seenIDs[c.Item.ItemID] {
			continue
		}
		seenIDs[c.Item.ItemID] = true
		if seenURLs[c.Item.CanonicalURL] {
			continue
		}
		seenURLs[c.Item.CanonicalURL] = true
		title := Normalize(c.Item.Title)
		ids := []string{}
		for id := range direct(c) {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		coverage := title + "|" + strings.Join(ids, ",")
		if utf8.RuneCountInString(title) >= 20 && c.Item.PublishedAt != nil {
			if old, ok := dates[coverage]; ok {
				delta := c.Item.PublishedAt.Sub(old)
				if delta >= -6*time.Hour && delta <= 6*time.Hour {
					continue
				}
			}
			dates[coverage] = *c.Item.PublishedAt
		}
		remaining = append(remaining, c)
	}
	result := make([]RankCandidate, 0, len(remaining))
	for len(remaining) > 0 {
		position, global := 0, -1
		if reserveGlobal && len(result)%5 == 4 {
			for i, c := range remaining {
				if c.MajorGlobal && (global < 0 || c.BaseScore > remaining[global].BaseScore) {
					global = i
				}
			}
		}
		if global >= 0 {
			position = global
		} else if len(result) >= 2 {
			recent := result[len(result)-2:]
			domains, sports := set(nil), set(nil)
			for _, c := range recent {
				domains[c.Item.Source.Domain] = true
				for _, id := range c.Analysis.SportIDs {
					sports[id] = true
				}
			}
			top := score(remaining[0])
			for i, c := range remaining {
				if score(c) >= top*.7 && (len(domains) != 1 || !domains[c.Item.Source.Domain]) && (len(sports) != 1 || !intersects(set(c.Analysis.SportIDs), sports)) {
					position = i
					break
				}
			}
		}
		result = append(result, remaining[position])
		remaining = append(remaining[:position], remaining[position+1:]...)
	}
	return result
}
