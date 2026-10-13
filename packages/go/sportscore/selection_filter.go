package sportscore

import "math"

// SelectionFilter owns one immutable catalog/hierarchy index for a page's live
// eligibility checks. It does not rerank, reorder or suppress page candidates.
type SelectionFilter struct {
	byID           map[string]Entity
	parents        map[string]map[string]bool
	follows, mutes map[string]bool
}

func NewSelectionFilter(selections []Selection, catalog []Entity) *SelectionFilter {
	follows, mutes := set(nil), set(nil)
	for _, selection := range selections {
		if selection.Action == "follow" {
			follows[selection.Reference] = true
		}
		if selection.Action == "mute" {
			mutes[selection.Reference] = true
		}
	}
	return newSelectionFilter(follows, mutes, catalog)
}

func newSelectionFilter(follows, mutes map[string]bool, entities []Entity) *SelectionFilter {
	byID := map[string]Entity{}
	for _, entity := range entities {
		if _, ok := byID[entity.ID]; !ok {
			byID[entity.ID] = entity
		}
	}
	parents := ParentIDs(entities)
	return &SelectionFilter{byID: byID, parents: parents, follows: follows, mutes: mutes}
}

func (f *SelectionFilter) Allows(candidate RankCandidate) bool {
	return candidate.Analysis.Eligible && candidate.Analysis.ResolverVersion == ResolverVersion && !math.IsNaN(candidate.BaseScore) && !math.IsInf(candidate.BaseScore, 0) && candidate.BaseScore >= 0 && f.permitted(candidate)
}

func (f *SelectionFilter) direct(candidate RankCandidate) map[string]bool {
	ids := set(nil)
	for _, association := range candidate.Analysis.Associations {
		if association.Confidence >= .9 && association.ResolverVersion == ResolverVersion {
			ids[association.EntityID] = true
		}
	}
	return ids
}

func (f *SelectionFilter) broad(candidate RankCandidate) map[string]bool {
	ids := Ancestors(set(candidate.Analysis.SportIDs), f.parents)
	for _, id := range candidate.Analysis.CompetitionIDs {
		ids[id] = true
	}
	for id := range f.direct(candidate) {
		if f.byID[id].Kind == "classification" {
			ids[id] = true
		}
	}
	return ids
}

func (f *SelectionFilter) personal(id string) bool {
	switch f.byID[id].Kind {
	case "team", "national-side", "athlete", "driver", "ncaa-team":
		return true
	}
	return false
}

func (f *SelectionFilter) permitted(candidate RankCandidate) bool {
	ids := f.direct(candidate)
	for id := range ids {
		if f.mutes[id] && f.personal(id) {
			return false
		}
	}
	if !intersects(f.broad(candidate), f.mutes) && !intersects(ids, f.mutes) {
		return true
	}
	for id := range ids {
		if f.follows[id] && !f.mutes[id] && f.personal(id) {
			return true
		}
	}
	return false
}
