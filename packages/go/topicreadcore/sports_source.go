package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"log/slog"
	"strings"
	"time"
)

func (s *SportsStore) Catalog(ctx context.Context) ([]sportscore.Entity, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT payload::text FROM sports_entities ORDER BY entity_id LIMIT 50000`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []sportscore.Entity{}
	count := 0
	for rows.Next() {
		var raw []byte
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		var e sportscore.Entity
		if err = corpuscore.DecodeContract(raw, &e); err != nil {
			return nil, err
		}
		count++
		if e.Active {
			out = append(out, e)
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if count == 0 {
		return sportscore.ReviewedEntities(), nil
	}
	return out, nil
}
func (s *SportsStore) Availability(ctx context.Context, now time.Time) (SportsAvailability, error) {
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return SportsAvailability{}, err
	}
	available := false
	if err = s.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM sports_generations WHERE language='en' AND expires_at>$1 AND payload->0->'analysis'->>'resolverVersion'=$2)`, now, sportscore.ResolverVersion).Scan(&available); err != nil {
		return SportsAvailability{}, err
	}
	revision, err := sportscore.ServingCatalogRevision(catalog)
	if err != nil {
		return SportsAvailability{}, err
	}
	return SportsAvailability{s.Config.Mode == "visible", available, s.Config.EventsEnabled, SportsDefinitions(catalog), catalog, revision}, nil
}
func (s *SportsStore) Entities(ctx context.Context, q string) ([]sportscore.Entity, error) {
	q = strings.TrimSpace(q)
	if q == "" || len([]rune(q)) > 200 {
		return nil, ErrInvalidCursor
	}
	exactID := q
	q = strings.ToLower(q)
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return nil, err
	}
	out := []sportscore.Entity{}
	for _, e := range catalog {
		if !SportsSelectable(e) {
			continue
		}
		matched := e.ID == exactID || strings.Contains(strings.ToLower(e.Name), q)
		for _, alias := range e.Aliases {
			matched = matched || strings.Contains(strings.ToLower(alias), q)
		}
		if matched {
			out = append(out, e)
			if len(out) == 50 {
				break
			}
		}
	}
	return out, nil
}
func (s *SportsStore) source(ctx context.Context, lang string, now time.Time) (corpuscore.SportsGeneration, error) {
	if s.Remote != nil {
		value, err := s.Remote.Sports(ctx, lang, now)
		if err == nil && value.Language == lang && value.ExpiresAt.After(now) && len(value.Candidates) <= 5000 && sportsCurrent(value.Candidates) {
			if err = s.importCatalog(ctx, value, now); err == nil {
				return value, nil
			}
		}
		if ctx.Err() != nil {
			return corpuscore.SportsGeneration{}, ctx.Err()
		}
		slog.Warn("Sports corpus unavailable; checking retained generation")
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT generation_id::text,generated_at,expires_at,payload::text,serving_source FROM sports_generations WHERE language=$1 AND expires_at>$2 ORDER BY is_active DESC,generated_at DESC LIMIT 10`, lang, now)
	if err != nil {
		return corpuscore.SportsGeneration{}, err
	}
	for rows.Next() {
		var value corpuscore.SportsGeneration
		var raw []byte
		var provenance string
		if err = rows.Scan(&value.GenerationID, &value.GeneratedAt, &value.ExpiresAt, &raw, &provenance); err != nil {
			rows.Close()
			return value, err
		}
		if err = corpuscore.DecodeContract(raw, &value.Candidates); err != nil {
			rows.Close()
			return value, err
		}
		if !sportsCurrent(value.Candidates) {
			continue
		}
		value.Language = lang
		value.Source = &provenance
		rows.Close()
		return value, nil
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return corpuscore.SportsGeneration{}, err
	}
	return s.fallback(ctx, lang, now)
}
func (s *SportsStore) importCatalog(ctx context.Context, source corpuscore.SportsGeneration, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.importedRevision == source.GenerationID {
		return nil
	}
	if len(source.Entities) == 0 || len(source.Entities) > 50000 {
		return ErrUnavailable
	}
	ids := []string{}
	for _, e := range source.Entities {
		ids = append(ids, e.ID)
	}
	raw, err := corpuscore.MarshalHTTP(source.Entities)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `WITH retired AS(UPDATE sports_entities SET payload=jsonb_set(payload,'{active}','false'::jsonb),updated_at=$3 WHERE NOT(entity_id=ANY($2::text[])))INSERT INTO sports_entities(entity_id,payload,updated_at)SELECT entity->>'id',entity,$3 FROM jsonb_array_elements($1::jsonb)entity ON CONFLICT(entity_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at WHERE sports_entities.payload IS DISTINCT FROM EXCLUDED.payload`, raw, ids, now)
	if err == nil {
		s.importedRevision = source.GenerationID
	}
	return err
}
func (s *SportsStore) fallback(ctx context.Context, lang string, now time.Time) (corpuscore.SportsGeneration, error) {
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return corpuscore.SportsGeneration{}, err
	}
	page, err := s.Wire.Feed(ctx, "", 50, lang, "", now)
	if err != nil || page.Language != lang {
		return corpuscore.SportsGeneration{}, ErrUnavailable
	}
	candidates := []sportscore.RankCandidate{}
	index := sportscore.NewEntityIndex(catalog)
	for ordinal, item := range page.Items {
		summary := ""
		if item.Summary != nil {
			summary = *item.Summary
		}
		analysis := sportscore.AnalyzeIndex(item.Title, summary, index)
		if analysis.Eligible {
			candidates = append(candidates, sportscore.RankCandidate{Item: item, Analysis: analysis, BaseScore: float64(50 - ordinal), MajorGlobal: analysis.Materiality == "championship" || analysis.Materiality == "record"})
		}
	}
	if len(candidates) == 0 {
		return corpuscore.SportsGeneration{}, ErrUnavailable
	}
	provenance := "simplified_fallback"
	return corpuscore.SportsGeneration{GenerationID: newID(), GeneratedAt: now, ExpiresAt: now.Add(48 * time.Hour), Language: lang, Candidates: candidates, Source: &provenance}, nil
}
