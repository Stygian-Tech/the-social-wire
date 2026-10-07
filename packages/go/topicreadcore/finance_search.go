package topicreadcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"log/slog"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

func (s *FinanceStore) Instruments(ctx context.Context, query string, now time.Time) ([]financecore.Instrument, error) {
	if !s.serves() {
		return nil, ErrUnavailable
	}
	query = strings.TrimSpace(query)
	if query == "" || utf8.RuneCountInString(query) > 200 {
		return nil, ErrInvalidCursor
	}
	normalized := strings.ToLower(query)
	if strings.HasPrefix(query, "fin_") {
		var raw []byte
		err := s.DB.QueryRowContext(ctx, `SELECT payload::text FROM finance_instruments WHERE instrument_id=$1`, query).Scan(&raw)
		if errors.Is(err, sql.ErrNoRows) {
			return []financecore.Instrument{}, nil
		}
		if err != nil {
			return nil, err
		}
		var value financecore.Instrument
		if err = json.Unmarshal(raw, &value); err != nil {
			return nil, err
		}
		return s.Config.Policy.Filter([]financecore.Instrument{financecore.ApplyReviewedMetadata(value)}), nil
	}
	s.mu.Lock()
	cached, ok := s.searchCache[normalized]
	s.mu.Unlock()
	if ok && now.Sub(cached.At) < 10*time.Minute {
		return append([]financecore.Instrument{}, cached.Items...), nil
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return nil, err
	}
	found := []financecore.Instrument{}
	for _, i := range catalog {
		matched := i.ID == query || strings.Contains(strings.ToLower(i.Name), normalized) || strings.Contains(strings.ToLower(i.Symbol), normalized)
		for _, alias := range i.Aliases {
			matched = matched || strings.Contains(strings.ToLower(alias), normalized)
		}
		if i.IsActive && matched {
			found = append(found, i)
		}
	}
	interval := time.Minute
	if s.Config.OpenFIGIKey != nil {
		interval = 12 * time.Second
	}
	s.mu.Lock()
	canSearch := now.Sub(s.lastSearch) >= interval
	s.mu.Unlock()
	if len(found) < 5 && canSearch {
		claimed, err := s.claimSearch(ctx, now, interval)
		if err != nil {
			return nil, err
		}
		if claimed {
			s.mu.Lock()
			s.lastSearch = now
			s.mu.Unlock()
			remote, err := s.Provider.Search(ctx, query)
			if err == nil {
				remote = remote[:min(50, len(remote))]
				for index, i := range remote {
					remote[index] = financecore.ApplyReviewedMetadata(i)
					payload, e := json.Marshal(remote[index])
					if e != nil {
						err = e
						break
					}
					_, e = s.DB.ExecContext(ctx, `INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)VALUES($1,$2,$3::jsonb,$4) ON CONFLICT(provider_key)DO UPDATE SET updated_at=EXCLUDED.updated_at,payload=EXCLUDED.payload||jsonb_build_object('aliases',finance_instruments.payload->'aliases','sectorIDs',finance_instruments.payload->'sectorIDs','tradingViewSymbol',CASE WHEN finance_instruments.payload->>'symbol'=EXCLUDED.payload->>'symbol' THEN finance_instruments.payload->'tradingViewSymbol' ELSE 'null'::jsonb END)`, i.ID, i.ProviderID, payload, now)
					if e != nil {
						err = e
						break
					}
				}
				if err == nil {
					found = append(found, remote...)
				}
			}
			if err != nil {
				slog.Warn("Finance reference search unavailable")
			}
		}
	}
	seen := map[string]bool{}
	unique := []financecore.Instrument{}
	for _, i := range found {
		if !seen[i.ID] {
			seen[i.ID] = true
			unique = append(unique, i)
		}
	}
	exchange := func(i financecore.Instrument) string {
		if i.Exchange != nil {
			return *i.Exchange
		}
		return ""
	}
	sort.Slice(unique, func(i, j int) bool {
		a, b := unique[i], unique[j]
		ae, be := strings.EqualFold(a.Symbol, query), strings.EqualFold(b.Symbol, query)
		if ae != be {
			return ae
		}
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		if exchange(a) != exchange(b) {
			return exchange(a) < exchange(b)
		}
		return a.ID < b.ID
	})
	found = limitFinanceSearchResults(unique)
	s.mu.Lock()
	if s.searchCache == nil {
		s.searchCache = map[string]financeSearchEntry{}
	}
	if len(s.searchCache) >= 100 {
		s.searchCache = map[string]financeSearchEntry{}
	}
	s.searchCache[normalized] = financeSearchEntry{now, found}
	s.mu.Unlock()
	return found, nil
}
func (s *FinanceStore) claimSearch(ctx context.Context, now time.Time, interval time.Duration) (bool, error) {
	var key string
	err := s.DB.QueryRowContext(ctx, `INSERT INTO finance_provider_request_budget(provider_key,requested_at)VALUES('openfigi-search',$1) ON CONFLICT(provider_key)DO UPDATE SET requested_at=EXCLUDED.requested_at WHERE finance_provider_request_budget.requested_at<=$2 RETURNING provider_key`, now, now.Add(-interval)).Scan(&key)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func limitFinanceSearchResults(items []financecore.Instrument) []financecore.Instrument {
	// The cache must own only its displayed rows, not the full matching catalog.
	result := make([]financecore.Instrument, min(50, len(items)))
	copy(result, items)
	return result
}
