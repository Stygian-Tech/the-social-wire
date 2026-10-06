package sportscore

import (
	"strings"
	"unicode"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

func Normalize(text string) string {
	text = norm.NFD.String(cases.Fold().String(text))
	text = strings.Map(func(r rune) rune {
		if unicode.Is(unicode.Mn, r) {
			return -1
		}
		return r
	}, text)
	return strings.Join(strings.FieldsFunc(text, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }), " ")
}
func set(values []string) map[string]bool {
	result := map[string]bool{}
	for _, v := range values {
		result[v] = true
	}
	return result
}
func intersects(a, b map[string]bool) bool {
	for k := range a {
		if b[k] {
			return true
		}
	}
	return false
}
func ParentIDs(catalog []Entity) map[string]map[string]bool {
	sports := map[string]bool{}
	for _, e := range catalog {
		if e.Kind == "sport" && e.Active {
			sports[e.ID] = true
		}
	}
	parents := map[string]map[string]bool{}
	for _, e := range catalog {
		if sports[e.ID] && e.SportID != nil && sports[*e.SportID] {
			if parents[e.ID] == nil {
				parents[e.ID] = map[string]bool{}
			}
			parents[e.ID][*e.SportID] = true
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
func Descendants(ids map[string]bool, catalog []Entity) map[string]bool {
	result := set(nil)
	for id := range ids {
		result[id] = true
	}
	parents := ParentIDs(catalog)
	for changed := true; changed; {
		changed = false
		for _, e := range catalog {
			if e.Active && e.Kind == "sport" && !result[e.ID] && intersects(parents[e.ID], result) {
				result[e.ID] = true
				changed = true
			}
		}
	}
	return result
}
