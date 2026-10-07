package topicreadcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"strings"
	"time"
)

func (s *FinanceStore) Catalog(ctx context.Context) ([]financecore.Instrument, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT payload::text FROM finance_instruments ORDER BY instrument_id LIMIT 50000`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []financecore.Instrument{}
	for rows.Next() {
		var raw []byte
		if err = rows.Scan(&raw); err != nil {
			return nil, err
		}
		var i financecore.Instrument
		if err = corpuscore.DecodeContract(raw, &i); err != nil {
			return nil, err
		}
		result = append(result, financecore.ApplyReviewedMetadata(i))
	}
	return s.Config.Policy.Filter(result), rows.Err()
}
func (s *FinanceStore) Availability(ctx context.Context, now time.Time) (FinanceAvailability, error) {
	available := false
	if s.Config.Rights && s.Config.Mode == "visible" {
		if s.Remote != nil {
			source, err := s.Remote.Finance(ctx, "en", now)
			if err == nil && source.Language == "en" && source.ExpiresAt.After(now) && len(source.Candidates) > 0 {
				available = true
				if err = s.importCatalog(ctx, source, now); err != nil {
					return FinanceAvailability{}, err
				}
			}
		} else {
			if err := s.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM finance_generations WHERE expires_at>$1 AND is_active=TRUE)`, now).Scan(&available); err != nil {
				return FinanceAvailability{}, err
			}
		}
		if !available {
			_, err := s.fallback(ctx, "en", now)
			available = err == nil
		}
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return FinanceAvailability{}, err
	}
	return FinanceAvailability{s.Config.Mode == "visible", available, s.Config.Widgets, FinanceDefinitions(catalog)}, nil
}
func (s *FinanceStore) source(ctx context.Context, language string, now time.Time) (corpuscore.FinanceGeneration, error) {
	if s.Remote != nil {
		source, err := s.Remote.Finance(ctx, language, now)
		if err != nil {
			var status corpuscore.RemoteStatusError
			var version corpuscore.RemoteVersionError
			if errors.As(err, &status) || errors.As(err, &version) {
				return s.fallback(ctx, language, now)
			}
			return source, corpusError(err)
		}
		if source.Language != language || !source.ExpiresAt.After(now) || len(source.Candidates) > 5000 {
			return source, ErrUnavailable
		}
		if err = s.importCatalog(ctx, source, now); err != nil {
			return source, err
		}
		return source, nil
	}
	var source corpuscore.FinanceGeneration
	var raw []byte
	var provenance string
	err := s.DB.QueryRowContext(ctx, `SELECT generation_id::text,generated_at,expires_at,payload::text,serving_source FROM finance_generations WHERE language=$1 AND expires_at>$2 ORDER BY is_active DESC,generated_at DESC LIMIT 1`, language, now).Scan(&source.GenerationID, &source.GeneratedAt, &source.ExpiresAt, &raw, &provenance)
	if errors.Is(err, sql.ErrNoRows) {
		return s.fallback(ctx, language, now)
	}
	if err != nil {
		return source, err
	}
	source.Language = language
	source.Source = &provenance
	err = corpuscore.DecodeContract(raw, &source.Candidates)
	return source, err
}
func (s *FinanceStore) importCatalog(ctx context.Context, source corpuscore.FinanceGeneration, now time.Time) error {
	revision := source.GenerationID + ":" + s.Config.Policy.Revision()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.importedRevision == revision {
		return nil
	}
	instruments := s.Config.Policy.Filter(source.Instruments)
	if len(instruments) > 5000 {
		return ErrUnavailable
	}
	payload, err := json.Marshal(instruments)
	if err != nil {
		return err
	}
	_, err = s.DB.ExecContext(ctx, `INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at) SELECT instrument->>'id','corpus:'||(instrument->>'id'),instrument,$2 FROM jsonb_array_elements($1::jsonb)instrument ON CONFLICT(instrument_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at WHERE finance_instruments.payload IS DISTINCT FROM EXCLUDED.payload`, payload, now)
	if err == nil {
		s.importedRevision = revision
	}
	return err
}
func (s *FinanceStore) fallback(ctx context.Context, language string, now time.Time) (corpuscore.FinanceGeneration, error) {
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return corpuscore.FinanceGeneration{}, err
	}
	page, err := s.Wire.Feed(ctx, "", 50, language, "", now)
	if err != nil || page.Language != language {
		return corpuscore.FinanceGeneration{}, ErrUnavailable
	}
	candidates := []financecore.RankCandidate{}
	for ordinal, item := range page.Items {
		summary := ""
		if item.Summary != nil {
			summary = *item.Summary
		}
		analysis := financecore.Analyze(item.Title, summary, nil, financecore.VerifiedInstrumentIDs(item.Source.Domain, ""), catalog)
		if analysis.Eligible {
			candidates = append(candidates, financecore.RankCandidate{Item: item, Analysis: analysis, BaseScore: float64(50 - ordinal), MajorGlobal: len(analysis.Associations) == 0 && analysis.Materiality != "price-chatter"})
		}
	}
	if len(candidates) == 0 {
		return corpuscore.FinanceGeneration{}, ErrUnavailable
	}
	source := "simplified_fallback"
	return corpuscore.FinanceGeneration{GenerationID: newID(), GeneratedAt: now, ExpiresAt: now.Add(48 * time.Hour), Language: language, Candidates: candidates, Source: &source}, nil
}
func topicLanguage(raw string) string {
	raw = strings.ToLower(raw)
	parts := strings.FieldsFunc(raw, func(r rune) bool { return r == '-' })
	if len(parts) == 0 {
		return "und"
	}
	raw = parts[0]
	if len(raw) < 2 || len(raw) > 8 {
		return "und"
	}
	for _, r := range raw {
		if r < 'a' || r > 'z' {
			return "und"
		}
	}
	return raw
}
