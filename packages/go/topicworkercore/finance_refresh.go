package topicworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

func (w *Worker) refreshFinance(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time) error {
	previous, err := w.rawFinanceCatalog(ctx)
	if err != nil {
		return err
	}
	ids := []string{}
	if raw, ok := w.env["FINANCE_OPENFIGI_IDS"]; ok {
		ids = unique(strings.Split(raw, ","))
	} else {
		for _, entry := range financecore.ReviewedEntries() {
			ids = append(ids, entry.ExpectedProviderID)
		}
		ids = unique(ids)
	}
	if previous != nil && at.Sub(previous.Snapshot.GeneratedAt.Time) < 24*time.Hour {
		valid := true
		providerIDs := map[string]bool{}
		for _, i := range previous.Snapshot.Instruments {
			valid = valid && w.policy.Permits(i)
			providerIDs[i.ProviderID] = true
		}
		for _, id := range ids {
			valid = valid && providerIDs[id]
		}
		if valid {
			return nil
		}
	}
	if w.lastFinanceRefresh != nil && at.Sub(*w.lastFinanceRefresh) < time.Hour {
		if previous != nil {
			return nil
		}
		return fmt.Errorf("finance catalog unavailable during retry backoff")
	}
	w.lastFinanceRefresh = &at
	snapshot, err := w.financeCandidate(ctx, previous, ids, at)
	if err != nil {
		if previous != nil {
			return nil
		}
		return err
	}
	payload, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	tx, err := w.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fence(ctx, tx, authority); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE finance_catalog_snapshots SET is_active=FALSE WHERE is_active=TRUE`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO finance_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)VALUES($1,$2,$3,$4::jsonb,TRUE)`, identifier(), snapshot.Version, at, string(payload)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)SELECT instrument->>'id',CASE WHEN instrument->>'kind'='crypto' THEN 'coingecko:' ELSE '' END||(instrument->>'providerID'),instrument,$1 FROM jsonb_array_elements($2::jsonb->'instruments') instrument ON CONFLICT(instrument_id)DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at`, at, string(payload)); err != nil {
		return err
	}
	return tx.Commit()
}
func unique(values []string) []string {
	set := map[string]bool{}
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			set[trimmed] = true
		}
	}
	result := []string{}
	for value := range set {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
func (w *Worker) financeCandidate(ctx context.Context, previous *financeCatalog, required []string, at time.Time) (financeSnapshot, error) {
	snapshot := financeSnapshot{}
	if len(required) > 150 {
		return snapshot, fmt.Errorf("finance required FIGIs exceed 150")
	}
	rows, err := w.DB.QueryContext(ctx, `SELECT provider_key FROM finance_instruments WHERE provider_key LIKE 'BBG%' ORDER BY provider_key LIMIT 151`)
	if err != nil {
		return snapshot, err
	}
	extra := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return snapshot, err
		}
		extra = append(extra, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return snapshot, err
	}
	oldByID := map[string]financecore.Instrument{}
	if previous != nil {
		for _, i := range previous.Snapshot.Instruments {
			oldByID[i.ID] = i
			if strings.HasPrefix(i.ProviderID, "BBG") {
				extra = append(extra, i.ProviderID)
			}
		}
	}
	requiredSet := map[string]bool{}
	for _, id := range required {
		requiredSet[id] = true
	}
	additional := []string{}
	for _, id := range unique(extra) {
		if !requiredSet[id] {
			additional = append(additional, id)
		}
	}
	bounded := append(append([]string{}, required...), additional[:min(150-len(required), len(additional))]...)
	securities := []financecore.Instrument{}
	for start := 0; start < len(bounded); start += 5 {
		if start > 0 && w.env["OPENFIGI_API_KEY"] == "" {
			if err := pause(ctx, 3100*time.Millisecond); err != nil {
				return snapshot, err
			}
		}
		mapped, err := w.mapFIGIs(ctx, bounded[start:min(start+5, len(bounded))])
		if err != nil {
			return snapshot, err
		}
		securities = append(securities, mapped...)
	}
	refreshed := map[string]bool{}
	for _, id := range bounded {
		refreshed[id] = true
	}
	for _, i := range oldByID {
		if strings.HasPrefix(i.ProviderID, "BBG") && !refreshed[i.ProviderID] {
			securities = append(securities, i)
		}
	}
	byID := map[string]financecore.Instrument{}
	for _, i := range securities {
		if _, ok := byID[i.ID]; !ok {
			byID[i.ID] = i
		}
	}
	all := []financecore.Instrument{}
	for _, i := range byID {
		all = append(all, i)
	}
	if w.policy.CryptoEnabled {
		coins, err := w.coins(ctx)
		if err != nil {
			return snapshot, err
		}
		all = append(all, coins...)
	}
	all = append(all, financecore.ReviewedInstruments()...)
	present := map[string]bool{}
	merged := []financecore.Instrument{}
	for _, i := range all {
		if i.ID == "" || i.ProviderID == "" || i.Symbol == "" || present[i.ID] {
			return snapshot, fmt.Errorf("invalid finance catalog identity")
		}
		present[i.ID] = true
		if old, ok := oldByID[i.ID]; ok {
			if i.Currency == nil {
				i.Currency = old.Currency
			}
			if i.MIC == nil {
				i.MIC = old.MIC
			}
			if i.ShareClassFIGI == nil {
				i.ShareClassFIGI = old.ShareClassFIGI
			}
			if i.CompositeFIGI == nil {
				i.CompositeFIGI = old.CompositeFIGI
			}
			aliases := append(append([]string{}, i.Aliases...), old.Aliases...)
			if old.Symbol != i.Symbol {
				aliases = append(aliases, old.Symbol)
				i.TradingViewSymbol = nil
			} else {
				i.TradingViewSymbol = old.TradingViewSymbol
			}
			i.Aliases = unique(aliases)
			if len(i.SectorIDs) == 0 {
				i.SectorIDs = old.SectorIDs
			}
		}
		merged = append(merged, financecore.ApplyReviewedMetadata(i))
	}
	for _, i := range oldByID {
		if !present[i.ID] {
			i.IsActive = false
			i.TradingViewSymbol = nil
			merged = append(merged, financecore.ApplyReviewedMetadata(i))
		}
	}
	sort.Slice(merged, func(i, j int) bool { return merged[i].ID < merged[j].ID })
	snapshot = financeSnapshot{identifier(), swiftDate{at}, w.policy.Filter(merged)}
	return snapshot, nil
}

// Refresh decisions inspect the unfiltered committed snapshot. Otherwise disabling a
// provider could leave its formerly active payload indefinitely inside the daily TTL.
func (w *Worker) rawFinanceCatalog(ctx context.Context) (*financeCatalog, error) {
	var payload string
	if err := w.DB.QueryRowContext(ctx, `SELECT payload::text FROM finance_catalog_snapshots WHERE is_active=TRUE LIMIT 1`).Scan(&payload); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	var snapshot financeSnapshot
	if err := json.Unmarshal([]byte(payload), &snapshot); err != nil {
		return nil, err
	}
	return &financeCatalog{Snapshot: snapshot}, nil
}
