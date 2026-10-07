package corpuscore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"sort"
	"strings"
	"time"
)

type preferenceMembership struct {
	EntityID   string     `json:"entityID"`
	ValidFrom  time.Time  `json:"validFrom"`
	ValidUntil *time.Time `json:"validUntil,omitempty"`
}

func (m preferenceMembership) includes(at time.Time) bool {
	return !at.Before(m.ValidFrom) && (m.ValidUntil == nil || at.Before(*m.ValidUntil))
}
func stringSet(values []string) map[string]bool {
	result := map[string]bool{}
	for _, value := range values {
		result[value] = true
	}
	return result
}
func sortedKeys(values map[string]bool) []string {
	result := []string{}
	for value := range values {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
func personalKind(kind string) bool {
	switch kind {
	case "team", "ncaa-team", "national-side", "athlete", "driver":
		return true
	}
	return false
}
func teamKind(kind string) bool {
	return kind == "team" || kind == "ncaa-team" || kind == "national-side"
}
func preferenceMemberships(preferred map[string]bool, catalog []sportscore.Entity) []preferenceMembership {
	teams := map[string]bool{}
	for _, e := range catalog {
		if e.Active && teamKind(e.Kind) {
			teams[e.ID] = true
		}
	}
	result := []preferenceMembership{}
	for _, e := range catalog {
		if e.Active && preferred[e.ID] && (e.Kind == "athlete" || e.Kind == "driver") {
			for _, m := range e.Memberships {
				if teams[m.EntityID] {
					result = append(result, preferenceMembership{m.EntityID, m.ValidFrom, m.ValidUntil})
				}
			}
		}
	}
	return result
}
func sportsDescendants(selected map[string]bool, catalog []sportscore.Entity) map[string]bool {
	result := stringSet(sortedKeys(selected))
	sports := map[string]bool{}
	for _, e := range catalog {
		if e.Active && e.Kind == "sport" {
			sports[e.ID] = true
		}
	}
	changed := true
	for changed {
		changed = false
		for _, e := range catalog {
			if !sports[e.ID] || result[e.ID] {
				continue
			}
			parent := ""
			if e.SportID != nil {
				parent = *e.SportID
			}
			if (sports[parent] && result[parent]) || (e.ID == sportscore.ReviewedID("sport:ice-hockey") && sports[sportscore.ReviewedID("sport:winter-sports")] && result[sportscore.ReviewedID("sport:winter-sports")]) {
				result[e.ID] = true
				changed = true
			}
		}
	}
	return result
}
func competitionScope(preferred map[string]bool, catalog []sportscore.Entity, now time.Time) []string {
	selected := stringSet(sortedKeys(preferred))
	for _, m := range preferenceMemberships(preferred, catalog) {
		if m.includes(now) {
			selected[m.EntityID] = true
		}
	}
	sports := map[string]bool{}
	competitions := map[string]bool{}
	for _, e := range catalog {
		if !e.Active || !selected[e.ID] {
			continue
		}
		if e.Kind == "sport" {
			sports[e.ID] = true
		}
		if e.Kind == "competition" {
			competitions[e.ID] = true
		} else {
			for _, id := range e.CompetitionIDs {
				competitions[id] = true
			}
		}
	}
	sports = sportsDescendants(sports, catalog)
	for _, e := range catalog {
		if e.Active && e.Kind == "competition" && e.SportID != nil && sports[*e.SportID] {
			competitions[e.ID] = true
		}
	}
	changed := true
	for changed {
		changed = false
		for _, e := range catalog {
			if !e.Active || e.Kind != "competition" || competitions[e.ID] {
				continue
			}
			for _, id := range e.CompetitionIDs {
				if competitions[id] {
					competitions[e.ID] = true
					changed = true
					break
				}
			}
		}
	}
	return sortedKeys(competitions)
}

type teamBinding struct {
	CompetitionID string `json:"competitionID"`
	Name          string `json:"name"`
	EntityID      string `json:"entityID"`
}
type teamIdentity struct {
	bindings        []teamBinding
	identity, codes map[string]string
}

func newTeamIdentity(catalog []sportscore.Entity, now time.Time) teamIdentity {
	owners := map[string]map[string]bool{}
	codeOwners := map[string]map[string]bool{}
	providerCodes := map[string]string{}
	components := map[string]teamBinding{}
	reviewed := reviewedAbbreviations()
	for _, e := range catalog {
		if !e.Active || !teamKind(e.Kind) {
			continue
		}
		competitions := stringSet(e.CompetitionIDs)
		for _, m := range e.Memberships {
			if m.Includes(now) {
				competitions[m.EntityID] = true
			}
		}
		provider := (*string)(nil)
		if e.Abbreviation != nil {
			provider = sportscore.ProviderAbbreviation(*e.Abbreviation, e.ProviderIDs["thesportsdb"])
		}
		for competition := range competitions {
			for _, code := range []string{reviewed[e.ID], func() string {
				if provider != nil {
					return *provider
				}
				return ""
			}()} {
				if code != "" {
					key := competition + "\x00" + code
					if codeOwners[key] == nil {
						codeOwners[key] = map[string]bool{}
					}
					codeOwners[key][e.ID] = true
				}
			}
			if provider != nil {
				providerCodes[competition+"\x00"+e.ID] = *provider
			}
			for _, name := range append([]string{e.Name}, e.Aliases...) {
				name = strings.ToLower(strings.TrimSpace(name))
				if name == "" {
					continue
				}
				key := competition + "\x00" + name
				if owners[key] == nil {
					owners[key] = map[string]bool{}
				}
				owners[key][e.ID] = true
				components[key] = teamBinding{competition, name, e.ID}
			}
		}
	}
	result := teamIdentity{bindings: []teamBinding{}, identity: map[string]string{}, codes: map[string]string{}}
	keys := []string{}
	for key := range owners {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if len(owners[key]) == 1 {
			binding := components[key]
			result.bindings = append(result.bindings, binding)
			result.identity[key] = binding.EntityID
		}
	}
	for context, code := range providerCodes {
		competition := strings.Split(context, "\x00")[0]
		if len(codeOwners[competition+"\x00"+code]) == 1 {
			result.codes[context] = code
		}
	}
	for key, id := range result.identity {
		competition := strings.Split(key, "\x00")[0]
		if code := reviewed[id]; code != "" {
			result.codes[competition+"\x00"+id] = code
		}
	}
	return result
}
func (t teamIdentity) hydrate(e sportscore.Event) sportscore.Event {
	ids := stringSet(e.EntityIDs)
	resolve := func(name *string) *string {
		if name == nil {
			return nil
		}
		id := t.identity[e.CompetitionID+"\x00"+strings.ToLower(strings.TrimSpace(*name))]
		if id == "" {
			return nil
		}
		ids[id] = true
		code := t.codes[e.CompetitionID+"\x00"+id]
		if code == "" {
			return nil
		}
		return &code
	}
	e.HomeAbbreviation = resolve(e.HomeName)
	e.AwayAbbreviation = resolve(e.AwayName)
	e.EntityIDs = sortedKeys(ids)
	return e
}
