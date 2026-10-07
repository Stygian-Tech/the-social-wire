package topicworkercore

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func replaceEntity(entities []sportscore.Entity, value sportscore.Entity) []sportscore.Entity {
	result := []sportscore.Entity{}
	for _, entity := range entities {
		if entity.ID != value.ID {
			result = append(result, entity)
		}
	}
	return append(result, value)
}
func (w *Worker) refreshSportsReference(ctx context.Context, authority *operationscore.RoleLeaseAuthority, catalog *sportsSnapshot, resource sportsResource, at time.Time) error {
	var competition *sportscore.Entity
	for _, entity := range catalog.Entities {
		if entity.ID == resource.Competition {
			value := entity
			competition = &value
			break
		}
	}
	if competition == nil {
		return nil
	}
	entities := append([]sportscore.Entity{}, catalog.Entities...)
	if strings.HasPrefix(resource.Key, "reference:") {
		mapped := *competition
		mapped.ProviderIDs = map[string]string{}
		for k, v := range competition.ProviderIDs {
			mapped.ProviderIDs[k] = v
		}
		mapped.ProviderIDs["thesportsdb"] = resource.Native
		entities = replaceEntity(entities, mapped)
		records, err := w.sportsRows(ctx, "list/teams/"+resource.Native)
		if err != nil {
			return err
		}
		for _, record := range records {
			entity := sportscore.ImportTeam(record, *competition, entities, at, func() string { return "sp_" + strings.ReplaceAll(identifier(), "-", "") })
			if entity != nil {
				entities = replaceEntity(entities, *entity)
			}
		}
	} else {
		var team *sportscore.Entity
		for _, entity := range entities {
			if "roster:"+entity.ID == resource.Key {
				value := entity
				team = &value
				break
			}
		}
		if team == nil {
			return nil
		}
		players, err := w.sportsRows(ctx, "list/players/"+resource.Native)
		if err != nil {
			return err
		}
		returned := map[string]bool{}
		for _, player := range players {
			if id, ok := player["idPlayer"]; ok {
				returned[id] = true
			}
		}
		for i, person := range entities {
			native, ok := person.ProviderIDs["thesportsdb"]
			if !ok || !contains([]string{"athlete", "driver"}, person.Kind) || len(players) >= 100 || returned[native] {
				continue
			}
			person.Memberships = append([]sportscore.Membership{}, person.Memberships...)
			for j, membership := range person.Memberships {
				if membership.EntityID == team.ID && membership.ValidUntil == nil {
					ended := at
					person.Memberships[j].ValidUntil = &ended
				}
			}
			entities[i] = person
		}
		for _, player := range players {
			native, ok := player["idPlayer"]
			name, nameOK := player["strPlayer"]
			if !ok || !nameOK || len(strings.Fields(name)) < 2 {
				continue
			}
			var previous *sportscore.Entity
			for _, entity := range entities {
				if contains([]string{"athlete", "driver"}, entity.Kind) && entity.ProviderIDs["thesportsdb"] == native {
					value := entity
					previous = &value
					break
				}
			}
			if previous == nil {
				for _, entity := range entities {
					sameSport := entity.SportID == nil && competition.SportID == nil
					if entity.SportID != nil && competition.SportID != nil {
						sameSport = *entity.SportID == *competition.SportID
					}
					if contains([]string{"athlete", "driver"}, entity.Kind) && sameSport && entity.Name == name {
						value := entity
						previous = &value
						break
					}
				}
			}
			memberships := []sportscore.Membership{}
			identity := "sp_" + strings.ReplaceAll(identifier(), "-", "")
			aliases := []string{}
			providers := map[string]string{}
			var groups []string
			var abbreviation *string
			if previous != nil {
				identity = previous.ID
				memberships = append(memberships, previous.Memberships...)
				aliases = previous.Aliases
				for k, v := range previous.ProviderIDs {
					providers[k] = v
				}
				groups = previous.GroupPath
				abbreviation = previous.Abbreviation
			}
			active := false
			for _, m := range memberships {
				active = active || (m.EntityID == team.ID && m.ValidUntil == nil)
			}
			if !active {
				for i, m := range memberships {
					if m.ValidUntil == nil {
						ended := at
						memberships[i].ValidUntil = &ended
					}
				}
				memberships = append(memberships, sportscore.Membership{EntityID: team.ID, ValidFrom: at})
			}
			kind := "athlete"
			if competition.SportID != nil && *competition.SportID == sportscore.ReviewedID("sport:motorsport") {
				kind = "driver"
			}
			providers["thesportsdb"] = native
			person := sportscore.Entity{ID: identity, Name: name, Kind: kind, SportID: competition.SportID, CompetitionIDs: []string{competition.ID}, Aliases: aliases, ProviderIDs: providers, Memberships: memberships, GroupPath: groups, Abbreviation: abbreviation, Active: true}
			entities = replaceEntity(entities, person)
		}
	}
	if len(entities) > 50000 {
		return fmt.Errorf("sports catalog exceeds entity bound")
	}
	revision, err := sportscore.CatalogRevision(entities)
	if err != nil {
		return err
	}
	if revision == catalog.Version {
		return nil
	}
	return w.publishSportsCatalog(ctx, authority, entities, at)
}
