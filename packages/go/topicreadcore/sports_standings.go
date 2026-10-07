package topicreadcore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"time"
)

func (s *SportsStore) scheduleStatus(ctx context.Context, d SportsDefinition, catalog []sportscore.Entity, now time.Time, teams, preferred []string) (string, *time.Time, error) {
	if s.Remote != nil {
		values, err := s.Remote.SportsSchedules(ctx, now)
		if err == nil && len(values) <= 100 {
			raw, err := corpuscore.MarshalHTTP(values)
			if err != nil {
				return "", nil, err
			}
			if _, err = s.DB.ExecContext(ctx, `INSERT INTO sports_schedule_status(competition_id,payload,updated_at,expires_at)SELECT value->>'competitionID',value,(value->>'updatedAt')::timestamptz,(value->>'updatedAt')::timestamptz+INTERVAL '72 hours' FROM jsonb_array_elements($1::jsonb)value ON CONFLICT(competition_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at`, raw); err != nil {
				return "", nil, err
			}
		}
	}
	_, related := sportsRelated(d, catalog)
	scope := corpuscore.SportsCompetitionScope(preferred, catalog, now)
	teamSet := sportsSet(teams)
	teamCompetitions := map[string]bool{}
	for _, e := range catalog {
		if teamSet[e.ID] {
			for _, id := range e.CompetitionIDs {
				teamCompetitions[id] = true
			}
		}
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT payload::text FROM sports_schedule_status WHERE expires_at>$1 AND ($2 OR competition_id=ANY($3::text[])) AND ($4 OR competition_id=ANY($5::text[])) AND ($6 OR competition_id=ANY($7::text[])) ORDER BY updated_at DESC LIMIT 100`, now, len(preferred) == 0, scope, teams == nil, sportsKeys(teamCompetitions), d.ID == "sports", sportsKeys(related))
	if err != nil {
		return "", nil, err
	}
	defer rows.Close()
	status := "unavailable"
	var updated *time.Time
	for rows.Next() {
		var raw []byte
		var value corpuscore.ScheduleStatus
		if err = rows.Scan(&raw); err != nil {
			return "", nil, err
		}
		if err = corpuscore.DecodeContract(raw, &value); err != nil {
			return "", nil, err
		}
		if d.ID != "sports" && !related[value.CompetitionID] {
			continue
		}
		if status == "unavailable" {
			status = "empty"
		}
		if value.Status == "available" {
			status = "available"
		}
		if updated == nil || value.UpdatedAt.After(*updated) {
			at := value.UpdatedAt
			updated = &at
		}
	}
	return status, updated, rows.Err()
}
func (s *SportsStore) standings(ctx context.Context, d SportsDefinition, catalog []sportscore.Entity, now time.Time, teams, preferred []string) ([]sportscore.StandingSnapshot, error) {
	remoteFailed := false
	if s.Remote != nil {
		remoteFailed = true
		tables, err := s.Remote.SportsStandings(ctx, preferred, now)
		if err == nil && len(tables) <= 100 {
			remoteFailed = false
			raw, err := corpuscore.MarshalHTTP(tables)
			if err != nil {
				return nil, err
			}
			if _, err = s.DB.ExecContext(ctx, `INSERT INTO sports_standings(competition_id,season,payload,updated_at,expires_at)SELECT value->>'competitionID',value->>'season',value,(value->>'updatedAt')::timestamptz,(value->>'updatedAt')::timestamptz+INTERVAL '72 hours' FROM jsonb_array_elements($1::jsonb)value WHERE value->>'updatedAt' IS NOT NULL ON CONFLICT(competition_id,season)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at,expires_at=EXCLUDED.expires_at`, raw); err != nil {
				return nil, err
			}
		}
	}
	_, related := sportsRelated(d, catalog)
	scope := corpuscore.SportsCompetitionScope(preferred, catalog, now)
	identity := corpuscore.NewSportsTeamIdentity(catalog, now)
	teamSet := sportsSet(teams)
	bindings := []corpuscore.SportsTeamBinding{}
	for _, b := range identity.Bindings() {
		if teamSet[b.EntityID] {
			bindings = append(bindings, b)
		}
	}
	bindingJSON, err := json.Marshal(bindings)
	if err != nil {
		return nil, err
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT payload::text FROM sports_standings WHERE expires_at>$1 AND ($2 OR competition_id=ANY($3::text[])) AND ($4 OR EXISTS(SELECT 1 FROM jsonb_array_elements(payload->'rows')row WHERE row->>'entityID'=ANY($5::text[]) OR EXISTS(SELECT 1 FROM jsonb_array_elements($6::jsonb)binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY($5::text[]) AND binding->>'name'=lower(btrim(row->>'name')) AND row->>'entityID' IS NULL))) AND ($7 OR competition_id=ANY($8::text[])) ORDER BY updated_at DESC LIMIT 100`, now, len(preferred) == 0, scope, teams == nil, teamsOrEmpty(teams), bindingJSON, d.ID == "sports", sportsKeys(related))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []sportscore.StandingSnapshot{}
	seen := map[string]bool{}
	for rows.Next() {
		var raw []byte
		var value sportscore.StandingSnapshot
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		if err = corpuscore.DecodeContract(raw, &value); err != nil {
			return nil, err
		}
		if seen[value.CompetitionID] || (d.ID != "sports" && !related[value.CompetitionID]) {
			continue
		}
		seen[value.CompetitionID] = true
		value = sportscore.ReviewedStandingZones(identity.HydrateStandings(value))
		value.Degraded = remoteFailed || value.UpdatedAt.IsZero() || now.Sub(value.UpdatedAt) > time.Hour
		out = append(out, value)
		if len(out) == 20 {
			break
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 && teams == nil && len(preferred) == 0 && d.ID != "sports" {
		keys := sportsKeys(related)
		if len(keys) > 0 {
			out = append(out, sportscore.StandingSnapshot{CompetitionID: keys[0], Season: "", SourceURL: "https://www.thesportsdb.com/", Status: "unavailable", Degraded: remoteFailed, Rows: []sportscore.StandingRow{}})
		}
	}
	return out, nil
}
func teamsOrEmpty(ids []string) []string {
	if ids == nil {
		return []string{}
	}
	return ids
}
