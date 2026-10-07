package corpuscore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"strings"
	"time"
)

func currentSports(candidates []sportscore.RankCandidate) bool {
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
func (s *PostgreSQLStore) Finance(ctx context.Context, language string, now time.Time) (FinanceGeneration, error) {
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return FinanceGeneration{}, err
	}
	rows, err := s.query(ctx, `SELECT generation_id,generated_at,expires_at,payload::text,instruments::text FROM wire_serving.finance_generations WHERE language=$1 AND is_active=TRUE AND expires_at>$2 LIMIT 1`, language, now)
	if err != nil {
		return FinanceGeneration{}, err
	}
	if len(rows) == 0 {
		return FinanceGeneration{}, ErrUnavailable
	}
	r := rows[0]
	result := FinanceGeneration{GenerationID: strings.ToLower(r.String(0)), GeneratedAt: r.Time(1), ExpiresAt: r.Time(2), Language: language, Candidates: []financecore.RankCandidate{}, Instruments: []financecore.Instrument{}}
	if err := decodeContract([]byte(r.String(3)), &result.Candidates); err != nil {
		return result, ErrContractMismatch
	}
	if err := decodeContract([]byte(r.String(4)), &result.Instruments); err != nil {
		return result, ErrContractMismatch
	}
	return result, r.err
}
func (s *PostgreSQLStore) Sports(ctx context.Context, language string, now time.Time) (SportsGeneration, error) {
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return SportsGeneration{}, err
	}
	rows, err := s.query(ctx, `SELECT generation_id,generated_at,expires_at,payload::text,entities::text FROM wire_serving.sports_generations WHERE language=$1 AND is_active=TRUE AND expires_at>$2 LIMIT 1`, language, now)
	if err != nil {
		return SportsGeneration{}, err
	}
	if len(rows) == 0 {
		return SportsGeneration{}, ErrUnavailable
	}
	r := rows[0]
	result := SportsGeneration{GenerationID: strings.ToLower(r.String(0)), GeneratedAt: r.Time(1), ExpiresAt: r.Time(2), Language: language, Candidates: []sportscore.RankCandidate{}, Entities: []sportscore.Entity{}}
	if err := decodeContract([]byte(r.String(3)), &result.Candidates); err != nil {
		return result, ErrContractMismatch
	}
	if !currentSports(result.Candidates) {
		return result, ErrUnavailable
	}
	if err := decodeContract([]byte(r.String(4)), &result.Entities); err != nil {
		return result, ErrContractMismatch
	}
	return result, r.err
}
func (s *PostgreSQLStore) SportsSchedules(ctx context.Context, now time.Time) ([]ScheduleStatus, error) {
	rows, err := s.query(ctx, `SELECT payload::text FROM wire_serving.sports_schedule_status WHERE expires_at>$1 ORDER BY updated_at DESC LIMIT 100`, now)
	if err != nil {
		return nil, err
	}
	result := []ScheduleStatus{}
	for _, r := range rows {
		var status ScheduleStatus
		if decodeContract([]byte(r.String(0)), &status) != nil {
			return nil, ErrContractMismatch
		}
		result = append(result, status)
		if r.err != nil {
			return nil, r.err
		}
	}
	return result, nil
}
func (s *PostgreSQLStore) sportsCatalog(ctx context.Context) ([]sportscore.Entity, error) {
	rows, err := s.query(ctx, `SELECT entities::text FROM wire_serving.sports_catalog LIMIT 1`)
	if err != nil {
		return nil, err
	}
	catalog := []sportscore.Entity{}
	for _, r := range rows {
		if decodeContract([]byte(r.String(0)), &catalog) != nil {
			return nil, ErrContractMismatch
		}
		if r.err != nil {
			return nil, r.err
		}
	}
	return catalog, nil
}
func (s *PostgreSQLStore) SportsStandings(ctx context.Context, preferred []string, now time.Time) ([]sportscore.StandingSnapshot, error) {
	catalog, err := s.sportsCatalog(ctx)
	if err != nil {
		return nil, err
	}
	competitions := competitionScope(stringSet(preferred), catalog, now)
	rows, err := s.query(ctx, `SELECT payload::text FROM wire_serving.sports_standings WHERE expires_at>$1 AND ($2 OR competition_id=ANY($3::text[])) ORDER BY updated_at DESC LIMIT 100`, now, len(preferred) == 0, competitions)
	if err != nil {
		return nil, err
	}
	result := []sportscore.StandingSnapshot{}
	for _, r := range rows {
		var table sportscore.StandingSnapshot
		if decodeContract([]byte(r.String(0)), &table) != nil {
			return nil, ErrContractMismatch
		}
		result = append(result, sportscore.ReviewedStandingZones(table))
		if r.err != nil {
			return nil, r.err
		}
	}
	return result, nil
}
func nonnil(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}
func (s *PostgreSQLStore) SportsEvents(ctx context.Context, q EventsQuery, now time.Time) ([]sportscore.Event, error) {
	catalog, err := s.sportsCatalog(ctx)
	if err != nil {
		return nil, err
	}
	identity := newTeamIdentity(catalog, now)
	preferred := stringSet(q.PreferredIDs)
	direct := []string{}
	broad := map[string]bool{}
	sportPreferences := map[string]bool{}
	for _, e := range catalog {
		if !preferred[e.ID] {
			continue
		}
		switch {
		case personalKind(e.Kind):
			direct = append(direct, e.ID)
		case e.Kind == "sport":
			sportPreferences[e.ID] = true
		default:
			broad[e.ID] = true
		}
	}
	memberships := preferenceMemberships(preferred, catalog)
	membershipJSON, err := json.Marshal(memberships)
	if err != nil {
		return nil, err
	}
	competitions := competitionScope(broad, catalog, now)
	sportPreferences = sportsDescendants(sportPreferences, catalog)
	sportCompetitions := []string{}
	sportEntities := []string{}
	for _, e := range catalog {
		if e.SportID != nil && sportPreferences[*e.SportID] {
			sportEntities = append(sportEntities, e.ID)
			if e.Kind == "competition" {
				sportCompetitions = append(sportCompetitions, e.ID)
			}
		}
	}
	location := q.TimeZone
	if location == nil {
		location = time.UTC
	}
	local := now.In(location)
	dayStart := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, location)
	scoped := stringSet(append(append(append([]string{}, q.EntityIDs...), q.TeamIDs...), direct...))
	for _, m := range memberships {
		scoped[m.EntityID] = true
	}
	bindings := []teamBinding{}
	for _, b := range identity.bindings {
		if scoped[b.EntityID] {
			bindings = append(bindings, b)
		}
	}
	bindingsJSON, err := json.Marshal(bindings)
	if err != nil {
		return nil, err
	}
	allCompetitions := append(append([]string{}, competitions...), sportCompetitions...)
	rows, err := s.query(ctx, `SELECT payload::text FROM wire_serving.sports_events WHERE expires_at > $1 AND ($2 OR competition_id=ANY($3::text[]) OR (payload->'entityIDs') ?| $4::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements($5::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY($4::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))) AND ($6 OR (payload->'entityIDs') ?| $7::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements($5::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY($7::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))) AND ($8 OR ((payload->'entityIDs') ?| $9::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements($10::jsonb) membership WHERE (payload->>'startsAt')::timestamptz >= (membership->>'validFrom')::timestamptz AND (membership->>'validUntil' IS NULL OR (payload->>'startsAt')::timestamptz < (membership->>'validUntil')::timestamptz) AND ((payload->'entityIDs') ? (membership->>'entityID') OR EXISTS (SELECT 1 FROM jsonb_array_elements($5::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=membership->>'entityID' AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))))) OR competition_id=ANY($11::text[]) OR (payload->'entityIDs') ?| $12::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements($5::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY($9::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))) AND (payload->>'startsAt')::timestamptz >= $13 ORDER BY CASE WHEN payload->>'status'='in-progress' THEN 0 WHEN payload->>'status'='finished' AND (payload->>'startsAt')::timestamptz BETWEEN $14 AND $1 THEN 1 WHEN payload->>'status' IN ('scheduled','postponed') AND (payload->>'startsAt')::timestamptz >= $1 THEN 2 ELSE 3 END, CASE WHEN ((payload->'entityIDs') ?| $9::text[] OR EXISTS (SELECT 1 FROM jsonb_array_elements($10::jsonb) membership WHERE (payload->>'startsAt')::timestamptz >= (membership->>'validFrom')::timestamptz AND (membership->>'validUntil' IS NULL OR (payload->>'startsAt')::timestamptz < (membership->>'validUntil')::timestamptz) AND ((payload->'entityIDs') ? (membership->>'entityID') OR EXISTS (SELECT 1 FROM jsonb_array_elements($5::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=membership->>'entityID' AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName'))))))) OR EXISTS (SELECT 1 FROM jsonb_array_elements($5::jsonb) binding WHERE binding->>'competitionID'=competition_id AND binding->>'entityID'=ANY($9::text[]) AND binding->>'name' IN (lower(btrim(payload->>'homeName')),lower(btrim(payload->>'awayName')))) THEN 0 WHEN competition_id=ANY($15::text[]) THEN 1 WHEN competition_id=ANY($16::text[]) OR (payload->'entityIDs') ?| $12::text[] THEN 2 ELSE 3 END, abs(extract(epoch FROM ((payload->>'startsAt')::timestamptz - $1::timestamptz))), (payload->>'startsAt')::timestamptz, event_id LIMIT 500`, now, q.Global, nonnil(q.CompetitionIDs), nonnil(q.EntityIDs), string(bindingsJSON), q.TeamIDs == nil, nonnil(q.TeamIDs), len(preferred) == 0, direct, string(membershipJSON), allCompetitions, sportEntities, now.Add(-7*24*time.Hour), dayStart, competitions, sportCompetitions)
	if err != nil {
		return nil, err
	}
	result := []sportscore.Event{}
	for _, r := range rows {
		var e sportscore.Event
		if decodeContract([]byte(r.String(0)), &e) != nil {
			return nil, ErrContractMismatch
		}
		result = append(result, identity.hydrate(e))
		if r.err != nil {
			return nil, r.err
		}
	}
	return result, nil
}
