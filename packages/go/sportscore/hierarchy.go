package sportscore

// Normalizes names with Unicode case folding and accent removal, builds active sport-
// parent relationships, and computes ancestor/descendant closure. Visited sets make
// traversal terminate even if input contains a cycle.

import (
	"strings"
	"unicode"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

// Normalize case-folds text, removes combining accents, and joins letter/number tokens for
// evidence matching.
func Normalize(text string) string {
	text = norm.NFD.String(cases.Fold().String(text))
	text = strings.Map(func(character rune) rune {
		if unicode.Is(unicode.Mn, character) {
			return -1
		}
		return character
	}, text)
	return strings.Join(strings.FieldsFunc(text, func(character rune) bool { return !unicode.IsLetter(character) && !unicode.IsNumber(character) }), " ")
}
func set(values []string) map[string]bool {
	result := map[string]bool{}
	for _, value := range values {
		result[value] = true
	}
	return result
}
func intersects(leftSet, rightSet map[string]bool) bool {
	for key := range leftSet {
		if rightSet[key] {
			return true
		}
	}
	return false
}

// ParentIDs builds active sport parent sets, including the reviewed ice-hockey/winter-
// sports relationship.
func ParentIDs(catalog []Entity) map[string]map[string]bool {
	sports := map[string]bool{}
	for _, entity := range catalog {
		if entity.Kind == "sport" && entity.Active {
			sports[entity.ID] = true
		}
	}
	parents := map[string]map[string]bool{}
	for _, entity := range catalog {
		if sports[entity.ID] && entity.SportID != nil && sports[*entity.SportID] {
			if parents[entity.ID] == nil {
				parents[entity.ID] = map[string]bool{}
			}
			parents[entity.ID][*entity.SportID] = true
		}
	}
	ice, winter := EntityID("sport:ice-hockey"), EntityID("sport:winter-sports")
	if sports[ice] && sports[winter] {
		if parents[ice] == nil {
			parents[ice] = map[string]bool{}
		}
		parents[ice][winter] = true
	}
	return parents
}

// Ancestors includes starting IDs and all reachable parents with cycle-safe traversal.
func Ancestors(ids map[string]bool, parents map[string]map[string]bool) map[string]bool {
	result := map[string]bool{}
	pending := []string{}
	for id := range ids {
		result[id] = true
		pending = append(pending, id)
	}
	for len(pending) > 0 {
		id := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		for parent := range parents[id] {
			if !result[parent] {
				result[parent] = true
				pending = append(pending, parent)
			}
		}
	}
	return result
}

// Descendants includes starting IDs and reachable active sport children from the supplied
// catalog.
func Descendants(ids map[string]bool, catalog []Entity) map[string]bool {
	result := set(nil)
	for id := range ids {
		result[id] = true
	}
	parents := ParentIDs(catalog)
	for changed := true; changed; {
		changed = false
		for _, entity := range catalog {
			if entity.Active && entity.Kind == "sport" && !result[entity.ID] && intersects(parents[entity.ID], result) {
				result[entity.ID] = true
				changed = true
			}
		}
	}
	return result
}
