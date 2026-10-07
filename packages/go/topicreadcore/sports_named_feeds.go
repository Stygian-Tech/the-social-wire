package topicreadcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"sort"
)

const SportsNamedVersion = "sports-named-feeds-v2"

type SportsDefinition struct {
	ID          string    `json:"id"`
	Title       string    `json:"title"`
	Kind        string    `json:"kind"`
	EntityIDs   []string  `json:"entityIDs"`
	Description string    `json:"description"`
	GroupPath   *[]string `json:"groupPath,omitempty"`
}

func SportsSelectable(e sportscore.Entity) bool {
	if !e.Active {
		return false
	}
	switch e.Kind {
	case "sport", "competition", "classification", "team", "national-side", "ncaa-team", "athlete", "driver":
		return true
	}
	return false
}
func SportsDefinitions(catalog []sportscore.Entity) []SportsDefinition {
	active := []sportscore.Entity{}
	for _, e := range catalog {
		if SportsSelectable(e) {
			active = append(active, e)
		}
	}
	sort.SliceStable(active, func(i, j int) bool { return active[i].Name < active[j].Name })
	out := []SportsDefinition{{ID: "sports", Title: "Sports", Kind: "global", EntityIDs: []string{}, Description: "Global sports news, personalized to your interests."}}
	for _, e := range active {
		d := SportsDefinition{ID: "entity:" + e.ID, Title: e.Name, Kind: e.Kind, EntityIDs: []string{e.ID}, Description: "Stories matching " + e.Name + "."}
		if e.GroupPath != nil {
			groups := append([]string{}, e.GroupPath...)
			d.GroupPath = &groups
		}
		out = append(out, d)
	}
	return out
}
func (d SportsDefinition) Matches(a sportscore.ArticleAnalysis) bool {
	if !a.Eligible || a.ResolverVersion != sportscore.ResolverVersion {
		return false
	}
	if d.ID == "sports" {
		return true
	}
	refs := map[string]bool{}
	for _, id := range d.EntityIDs {
		refs[id] = true
	}
	for _, v := range a.Associations {
		if refs[v.EntityID] && v.Confidence >= .9 && v.ResolverVersion == sportscore.ResolverVersion {
			return true
		}
	}
	for _, id := range append(append([]string{}, a.SportIDs...), a.CompetitionIDs...) {
		if refs[id] {
			return true
		}
	}
	return false
}
func sportsDefinition(feed string, catalog []sportscore.Entity) (SportsDefinition, bool) {
	for _, d := range SportsDefinitions(catalog) {
		if d.ID == feed {
			return d, true
		}
	}
	return SportsDefinition{}, false
}
func sportsCurrent(candidates []sportscore.RankCandidate) bool {
	for _, c := range candidates {
		if c.Analysis.ResolverVersion != sportscore.ResolverVersion {
			return false
		}
		for _, a := range c.Analysis.Associations {
			if a.ResolverVersion != sportscore.ResolverVersion {
				return false
			}
		}
	}
	return true
}
