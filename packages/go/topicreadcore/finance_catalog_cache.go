package topicreadcore

import (
	"context"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
)

const financeCatalogMaximumCacheBytes = 16 << 20

// Catalog rows remain authoritative, including rewrites within one transaction
// (ctid), insertion/deletion, ordering and the existing 50000-row limit.
const financeCatalogStampExpression = `encode(sha256(convert_to(COALESCE(string_agg(length(instrument_id)::text||':'||instrument_id||':'||row_version||':'||row_location,',' ORDER BY instrument_id),''),'UTF8')),'hex')`
const financeCatalogMetadataQuery = `WITH selected AS MATERIALIZED(SELECT instrument_id,xmin::text AS row_version,ctid::text AS row_location FROM finance_instruments ORDER BY instrument_id LIMIT 50000) SELECT count(*)::integer,` + financeCatalogStampExpression + ` FROM selected`
const financeCatalogPayloadQuery = `WITH selected AS MATERIALIZED(SELECT instrument_id,xmin::text AS row_version,ctid::text AS row_location,payload FROM finance_instruments ORDER BY instrument_id LIMIT 50000),stamp AS(SELECT ` + financeCatalogStampExpression + ` AS revision FROM selected) SELECT selected.payload::text FROM selected CROSS JOIN stamp WHERE stamp.revision=$1 ORDER BY selected.instrument_id`

type financeCatalogCache struct {
	stamp, policy string
	instruments   []financecore.Instrument
}

func (s *FinanceStore) Catalog(ctx context.Context) ([]financecore.Instrument, error) {
	policy := s.Config.Policy
	started := time.Now()
	var count int
	var stamp string
	err := s.DB.QueryRowContext(ctx, financeCatalogMetadataQuery).Scan(&count, &stamp)
	ObserveFeedPhase(ctx, "catalog-metadata", time.Since(started))
	if err != nil {
		return nil, err
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	s.catalogMu.Lock()
	cache := s.catalogCache
	s.catalogMu.Unlock()
	if cache != nil && cache.stamp == stamp && cache.policy == policy.Revision() {
		ObserveFeedPhase(ctx, "catalog-cache-hit", 0)
		return cloneFinanceCatalog(cache.instruments), nil
	}
	ObserveFeedPhase(ctx, "catalog-cache-miss", 0)
	values := []financecore.Instrument{}
	totalBytes := 0
	if count > 0 {
		started = time.Now()
		rows, closeRows, err := corpuscore.QueryRows(ctx, s.DB, financeCatalogPayloadQuery, stamp)
		ObserveFeedPhase(ctx, "catalog-query-open", time.Since(started))
		if err != nil {
			return nil, err
		}
		defer closeRows()
		scanStarted := time.Now()
		var scanElapsed, decodeElapsed time.Duration
		defer func() {
			ObserveFeedPhase(ctx, "catalog-scan", scanElapsed)
			ObserveFeedPhase(ctx, "catalog-decode", decodeElapsed)
		}()
		for rows.Next() {
			var raw []byte
			if err = rows.Scan(&raw); err != nil {
				return nil, err
			}
			scanElapsed += time.Since(scanStarted)
			decodeStarted := time.Now()
			var value financecore.Instrument
			if err = corpuscore.DecodeContract(raw, &value); err != nil {
				return nil, err
			}
			values = append(values, financecore.ApplyReviewedMetadata(value))
			totalBytes += len(raw)
			decodeElapsed += time.Since(decodeStarted)
			scanStarted = time.Now()
		}
		scanElapsed += time.Since(scanStarted)
		if err = rows.Err(); err != nil {
			return nil, err
		}
		// A rowset changed between metadata and payload queries. Retry on the next
		// request rather than attaching new data to the previous authoritative stamp.
		if len(values) != count {
			return nil, ErrUnavailable
		}
	}
	values = policy.Filter(values)
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if totalBytes <= financeCatalogMaximumCacheBytes {
		entry := &financeCatalogCache{stamp: stamp, policy: policy.Revision(), instruments: cloneFinanceCatalog(values)}
		s.catalogMu.Lock()
		s.catalogCache = entry
		s.catalogMu.Unlock()
	}
	return values, nil
}

// Catalog callers receive owned slices and optional fields; cache entries remain
// immutable even when a caller adapts an instrument for presentation.
func cloneFinanceCatalog(values []financecore.Instrument) []financecore.Instrument {
	result := append([]financecore.Instrument{}, values...)
	cloneString := func(value *string) *string {
		if value == nil {
			return nil
		}
		copy := *value
		return &copy
	}
	cloneSlice := func(values []string) []string {
		if values == nil {
			return nil
		}
		return append([]string{}, values...)
	}
	for i := range result {
		value := &result[i]
		value.Exchange = cloneString(value.Exchange)
		value.ExchangeName = cloneString(value.ExchangeName)
		value.MIC = cloneString(value.MIC)
		value.ShareClassFIGI = cloneString(value.ShareClassFIGI)
		value.CompositeFIGI = cloneString(value.CompositeFIGI)
		value.Currency = cloneString(value.Currency)
		value.TradingViewSymbol = cloneString(value.TradingViewSymbol)
		value.Aliases = cloneSlice(value.Aliases)
		value.SectorIDs = cloneSlice(value.SectorIDs)
	}
	return result
}
