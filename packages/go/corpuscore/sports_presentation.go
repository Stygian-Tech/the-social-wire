package corpuscore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"strings"
	"time"
)

type SportsPreferenceMembership = preferenceMembership

func (m preferenceMembership) Includes(at time.Time) bool { return m.includes(at) }
func SportsPreferenceMemberships(ids []string, catalog []sportscore.Entity) []SportsPreferenceMembership {
	return preferenceMemberships(stringSet(ids), catalog)
}
func SportsCompetitionScope(ids []string, catalog []sportscore.Entity, at time.Time) []string {
	return competitionScope(stringSet(ids), catalog, at)
}
func SportsDescendants(ids []string, catalog []sportscore.Entity) []string {
	return sortedKeys(sportsDescendants(stringSet(ids), catalog))
}

type SportsTeamBinding = teamBinding
type SportsTeamIdentity struct{ value teamIdentity }

func NewSportsTeamIdentity(catalog []sportscore.Entity, at time.Time) SportsTeamIdentity {
	return SportsTeamIdentity{newTeamIdentity(catalog, at)}
}
func (i SportsTeamIdentity) Bindings() []SportsTeamBinding {
	return append([]SportsTeamBinding{}, i.value.bindings...)
}
func (i SportsTeamIdentity) Hydrate(event sportscore.Event) sportscore.Event {
	return i.value.hydrate(event)
}
func (i SportsTeamIdentity) HydrateStandings(table sportscore.StandingSnapshot) sportscore.StandingSnapshot {
	table.Rows = append([]sportscore.StandingRow{}, table.Rows...)
	for index, row := range table.Rows {
		if row.EntityID == nil {
			if id := i.value.identity[table.CompetitionID+"\x00"+strings.ToLower(strings.TrimSpace(row.Name))]; id != "" {
				table.Rows[index].EntityID = &id
			}
		}
	}
	return table
}
