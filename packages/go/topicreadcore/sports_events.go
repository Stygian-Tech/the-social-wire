package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"time"
)

type SportsEventsResponse struct {
	Events          []sportscore.Event            `json:"events"`
	UpdatedAt       *time.Time                    `json:"updatedAt,omitempty"`
	Degraded        bool                          `json:"degraded"`
	EventsLimited   bool                          `json:"eventsLimited"`
	BracketSources  []SportsBracketSource         `json:"bracketSources"`
	Standings       []sportscore.StandingSnapshot `json:"standings"`
	PreferredIDs    *[]string                     `json:"preferredIDs,omitempty"`
	TimeZone        *string                       `json:"timeZone,omitempty"`
	SchedulesStatus string                        `json:"schedulesStatus"`
}

func emptySportsEvents() SportsEventsResponse {
	return SportsEventsResponse{Events: []sportscore.Event{}, BracketSources: []SportsBracketSource{}, Standings: []sportscore.StandingSnapshot{}, SchedulesStatus: "unavailable"}
}
func (s *SportsStore) Events(ctx context.Context, feed string, now time.Time, teams, preferred []string, zone *time.Location, zoneName string) (SportsEventsResponse, error) {
	empty := emptySportsEvents()
	if !s.serves() {
		return empty, ErrUnavailable
	}
	if !s.Config.EventsEnabled {
		return empty, nil
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return empty, err
	}
	definition, ok := sportsDefinition(feed, catalog)
	if !ok {
		return empty, ErrInvalidCursor
	}
	if len(teams) > 100 || len(preferred) > 100 {
		return empty, ErrInvalidCursor
	}
	active := map[string]bool{}
	validTeams := map[string]bool{}
	for _, e := range catalog {
		if e.Active {
			active[e.ID] = true
			if sportsTeamKind(e.Kind) {
				validTeams[e.ID] = true
			}
		}
	}
	for _, id := range preferred {
		if !active[id] {
			return empty, ErrInvalidCursor
		}
	}
	for _, id := range teams {
		if !validTeams[id] {
			return empty, ErrInvalidCursor
		}
	}
	preferences := sportsKeys(sportsSet(preferred))
	if teams != nil {
		teams = sportsKeys(sportsSet(teams))
	}
	if zone == nil {
		zone = time.UTC
	}
	if zoneName == "" {
		zoneName = zone.String()
	}
	empty.PreferredIDs = &preferences
	empty.TimeZone = &zoneName
	if teams != nil && len(teams) == 0 {
		empty.SchedulesStatus = "empty"
		return empty, nil
	}
	selected := sportsSet(corpuscore.SportsDescendants(definition.EntityIDs, catalog))
	competitionIDs := map[string]bool{}
	for _, e := range catalog {
		if e.SportID != nil && selected[*e.SportID] {
			for _, id := range e.CompetitionIDs {
				competitionIDs[id] = true
			}
			if e.Kind == "competition" {
				competitionIDs[e.ID] = true
			}
		}
		if selected[e.ID] && e.Kind == "competition" {
			competitionIDs[e.ID] = true
		}
	}
	q := corpuscore.EventsQuery{Global: feed == "sports", CompetitionIDs: sportsKeys(competitionIDs), EntityIDs: sportsKeys(selected), TeamIDs: teams, PreferredIDs: preferences, TimeZone: zone}
	events := []sportscore.Event{}
	remoteFailed := false
	if s.Remote != nil {
		remoteFailed = true
		value, e := s.Remote.SportsEvents(ctx, q, now)
		if e == nil {
			remoteFailed = false
			events = value[:min(500, len(value))]
			if err = s.importEvents(ctx, events); err != nil {
				return empty, err
			}
		}
	}
	if len(events) == 0 {
		store := corpuscore.PostgreSQLStore{DB: s.DB}
		events, err = store.SportsEventsWithCatalog(ctx, q, now, catalog)
		if err != nil {
			return empty, err
		}
	}
	identity := corpuscore.NewSportsTeamIdentity(catalog, now)
	prefs := sportsSet(preferences)
	direct := map[string]bool{}
	sports := map[string]bool{}
	broad := []string{}
	for _, e := range catalog {
		if !prefs[e.ID] {
			continue
		}
		if sportsPersonalKind(e.Kind) {
			direct[e.ID] = true
		} else if e.Kind == "sport" {
			sports[e.ID] = true
		} else {
			broad = append(broad, e.ID)
		}
	}
	memberships := corpuscore.SportsPreferenceMemberships(preferences, catalog)
	broadCompetitions := sportsSet(corpuscore.SportsCompetitionScope(broad, catalog, now))
	sports = sportsSet(corpuscore.SportsDescendants(sportsKeys(sports), catalog))
	sportEntities := map[string]bool{}
	for _, e := range catalog {
		if e.SportID != nil && sports[*e.SportID] {
			sportEntities[e.ID] = true
			if e.Kind == "competition" {
				broadCompetitions[e.ID] = true
			}
		}
	}
	result := []sportscore.Event{}
	var updated *time.Time
	teamSet := sportsSet(teams)
	for _, cached := range events {
		event := identity.Hydrate(cached)
		interest := sportsIntersects(event.EntityIDs, direct) || sportsIntersects(event.EntityIDs, sportEntities) || broadCompetitions[event.CompetitionID]
		for _, m := range memberships {
			interest = interest || (m.Includes(event.StartsAt) && sportsIntersects(event.EntityIDs, map[string]bool{m.EntityID: true}))
		}
		if len(prefs) > 0 && !interest {
			continue
		}
		if teams != nil && !sportsIntersects(event.EntityIDs, teamSet) {
			continue
		}
		if feed == "sports" || selected[event.CompetitionID] || competitionIDs[event.CompetitionID] || sportsIntersects(event.EntityIDs, selected) {
			result = append(result, event)
			if updated == nil || event.UpdatedAt.After(*updated) {
				at := event.UpdatedAt
				updated = &at
			}
		}
	}
	tables, err := s.standings(ctx, definition, catalog, now, teams, preferences)
	if err != nil {
		return empty, err
	}
	schedule, scheduleUpdated, err := s.scheduleStatus(ctx, definition, catalog, now, teams, preferences)
	if err != nil {
		return empty, err
	}
	if updated == nil {
		updated = scheduleUpdated
	}
	result = sportsOrder(result, now, preferences, catalog, zone)
	status := schedule
	if len(result) > 0 {
		status = "available"
	}
	empty.EventsLimited = len(result) >= 500
	empty.Events = result[:min(500, len(result))]
	empty.UpdatedAt = updated
	empty.Degraded = remoteFailed || updated == nil || (updated != nil && now.Sub(*updated) > time.Hour)
	empty.BracketSources = sportsBrackets(definition, catalog, teams, preferences, now)
	empty.Standings = tables
	empty.SchedulesStatus = status
	return empty, nil
}
func (s *SportsStore) importEvents(ctx context.Context, events []sportscore.Event) error {
	raw, err := corpuscore.MarshalHTTP(events)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `INSERT INTO sports_events(event_id,competition_id,payload,updated_at,expires_at)SELECT event->>'id',event->>'competitionID',event,(event->>'updatedAt')::timestamptz,(event->>'updatedAt')::timestamptz+INTERVAL '72 hours' FROM jsonb_array_elements($1::jsonb)event ON CONFLICT(event_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at`, raw)
	return err
}
