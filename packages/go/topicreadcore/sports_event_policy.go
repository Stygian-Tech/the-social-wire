package topicreadcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"math"
	"sort"
	"time"
)

func sportsSet(ids []string) map[string]bool {
	out := map[string]bool{}
	for _, id := range ids {
		out[id] = true
	}
	return out
}
func sportsKeys(set map[string]bool) []string {
	out := []string{}
	for id := range set {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}
func sportsIntersects(ids []string, set map[string]bool) bool {
	for _, id := range ids {
		if set[id] {
			return true
		}
	}
	return false
}
func sportsTeamKind(kind string) bool {
	return kind == "team" || kind == "ncaa-team" || kind == "national-side"
}
func sportsPersonalKind(kind string) bool {
	return sportsTeamKind(kind) || kind == "athlete" || kind == "driver"
}
func sportsRelated(d SportsDefinition, catalog []sportscore.Entity) (map[string]bool, map[string]bool) {
	selected := sportsSet(corpuscore.SportsDescendants(d.EntityIDs, catalog))
	related := map[string]bool{}
	for _, e := range catalog {
		if selected[e.ID] || (e.SportID != nil && selected[*e.SportID]) {
			for _, id := range e.CompetitionIDs {
				related[id] = true
			}
			if e.Kind == "competition" {
				related[e.ID] = true
			}
		}
	}
	for id := range selected {
		related[id] = true
	}
	return selected, related
}
func sportsOrder(events []sportscore.Event, now time.Time, preferred []string, catalog []sportscore.Entity, zone *time.Location) []sportscore.Event {
	prefs := sportsSet(preferred)
	sports := sportsSet(corpuscore.SportsDescendants(preferred, catalog))
	byID := map[string]sportscore.Entity{}
	for _, e := range catalog {
		byID[e.ID] = e
	}
	memberships := corpuscore.SportsPreferenceMemberships(preferred, catalog)
	tier := func(e sportscore.Event) int {
		if len(prefs) == 0 {
			return 3
		}
		for _, id := range e.EntityIDs {
			entity := byID[id]
			if prefs[id] && entity.Active && sportsPersonalKind(entity.Kind) {
				return 0
			}
		}
		for _, m := range memberships {
			if m.Includes(e.StartsAt) && sportsIntersects(e.EntityIDs, map[string]bool{m.EntityID: true}) {
				return 0
			}
		}
		if prefs[e.CompetitionID] {
			return 1
		}
		if competition := byID[e.CompetitionID]; competition.SportID != nil && sports[*competition.SportID] {
			return 2
		}
		for _, id := range e.EntityIDs {
			if entity := byID[id]; entity.SportID != nil && sports[*entity.SportID] {
				return 2
			}
		}
		return 3
	}
	priority := func(e sportscore.Event) int {
		if e.Status == "in-progress" {
			return 0
		}
		local := now.In(zone)
		starts := e.StartsAt.In(zone)
		if e.Status == "finished" && !e.StartsAt.After(now) && local.Year() == starts.Year() && local.YearDay() == starts.YearDay() {
			return 1
		}
		if (e.Status == "scheduled" || e.Status == "postponed") && !e.StartsAt.Before(now) {
			return 2
		}
		return 3
	}
	tiers := map[string]int{}
	for _, e := range events {
		tiers[e.ID] = tier(e)
	}
	sort.SliceStable(events, func(i, j int) bool {
		a, b := events[i], events[j]
		if priority(a) != priority(b) {
			return priority(a) < priority(b)
		}
		if tiers[a.ID] != tiers[b.ID] {
			return tiers[a.ID] < tiers[b.ID]
		}
		da, db := math.Abs(a.StartsAt.Sub(now).Seconds()), math.Abs(b.StartsAt.Sub(now).Seconds())
		if da != db {
			return da < db
		}
		if !a.StartsAt.Equal(b.StartsAt) {
			return a.StartsAt.Before(b.StartsAt)
		}
		return a.ID < b.ID
	})
	return events
}

type SportsBracketSource struct {
	ID            string    `json:"id"`
	CompetitionID string    `json:"competitionID"`
	Season        string    `json:"season"`
	Title         string    `json:"title"`
	URL           string    `json:"url"`
	ReviewedAt    time.Time `json:"reviewedAt"`
	Mode          string    `json:"mode"`
}

func sportsBrackets(d SportsDefinition, catalog []sportscore.Entity, teams, preferred []string, now time.Time) []SportsBracketSource {
	if teams != nil && len(teams) == 0 {
		return []SportsBracketSource{}
	}
	selected, related := sportsRelated(d, catalog)
	teamCompetitions := map[string]bool{}
	teamSet := sportsSet(teams)
	for _, e := range catalog {
		if sportsIntersects(e.CompetitionIDs, selected) {
			for _, id := range e.CompetitionIDs {
				related[id] = true
			}
			if e.Kind == "competition" {
				related[e.ID] = true
			}
		}
		if teamSet[e.ID] {
			for _, id := range e.CompetitionIDs {
				teamCompetitions[id] = true
			}
		}
	}
	scope := sportsSet(corpuscore.SportsCompetitionScope(preferred, catalog, now))
	records := [][4]string{{"nfl", "2025", "NFL 2025 Season Playoff Bracket", "https://www.nfl.com/playoffs/bracket/2025"}, {"nba", "2025-2026", "2026 NBA Playoff Bracket", "https://www.nba.com/playoffs/2026/bracket"}, {"nhl", "2025-2026", "2026 NHL Playoff Central", "https://www.nhl.com/playoffs/nhl-playoff-central"}, {"mlb", "2026", "2026 MLB Postseason Bracket", "https://www.mlb.com/postseason"}, {"ncaa-mens-basketball", "2026", "2026 NCAA Division I Men's Basketball Bracket", "https://www.ncaa.com/march-madness-live/bracket"}, {"ncaa-womens-basketball", "2026", "2026 NCAA Division I Women's Basketball Bracket", "https://www.ncaa.com/brackets/basketball-women/d1/2026"}}
	out := []SportsBracketSource{}
	for _, r := range records {
		id := sportscore.ReviewedID("competition:" + r[0])
		if (len(preferred) == 0 || scope[id]) && (d.ID == "sports" || related[id]) && (teams == nil || teamCompetitions[id]) {
			out = append(out, SportsBracketSource{"official:" + r[0] + ":" + r[1], id, r[1], r[2], r[3], time.Unix(1791072000, 0).UTC(), "external"})
		}
	}
	return out
}
