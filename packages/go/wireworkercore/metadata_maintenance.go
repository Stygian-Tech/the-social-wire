package wireworkercore

import (
	"context"
	"database/sql"
	"log/slog"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
)

type MetadataRepairProgress struct {
	Scanned, Repaired int
	Wrapped           bool
}

func waitMaintenance(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
func maintenanceLoop(ctx context.Context, initial, interval time.Duration, batch func(context.Context, time.Time) (int, error)) error {
	if err := waitMaintenance(ctx, initial); err != nil {
		return err
	}
	for {
		_, err := batch(ctx, time.Now().UTC())
		if ctx.Err() != nil {
			return ctx.Err()
		}
		delay := interval
		if err != nil {
			delay = max(delay, 30*time.Second)
			slog.Warn("Wire disposable diagnostic work failed", "category", "operation_failed")
		}
		if err := waitMaintenance(ctx, delay); err != nil {
			return err
		}
	}
}
func (h *EnrichmentHost) repairLoop(ctx context.Context, authority *operationscore.RoleLeaseAuthority) error {
	baseline := h.RepairInterval
	if baseline == 0 {
		baseline = time.Second
	}
	idle := baseline
	delay := idle
	observedBoundary, repaired := false, false
	for {
		progress, err := h.Store.Repair(ctx, authority, time.Now().UTC(), 1000)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			delay = min(60*time.Second, delay*2)
		} else {
			if progress.Repaired > 0 {
				repaired = true
				idle = baseline
			}
			if progress.Wrapped {
				if observedBoundary && !repaired {
					idle = min(60*time.Second, idle*2)
				}
				observedBoundary = true
				repaired = false
			}
			delay = idle
		}
		if err := waitMaintenance(ctx, delay); err != nil {
			return err
		}
	}
}
func (s *MetadataStore) Repair(ctx context.Context, authority *operationscore.RoleLeaseAuthority, at time.Time, limit int) (MetadataRepairProgress, error) {
	var progress MetadataRepairProgress
	if authority == nil {
		return progress, ErrMissingAuthority
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return progress, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SET LOCAL lock_timeout='500ms'`); err != nil {
		return progress, err
	}
	if _, err := tx.ExecContext(ctx, `SET LOCAL statement_timeout='5s'`); err != nil {
		return progress, err
	}
	if err := tx.QueryRowContext(ctx, metadataRepairSQL, max(1, min(limit, 1000)), at).Scan(&progress.Scanned, &progress.Repaired, &progress.Wrapped); err != nil {
		return progress, err
	}
	if err := operationscore.LockRoleLeaseFence(ctx, tx, *authority, false); err != nil {
		return progress, err
	}
	return progress, tx.Commit()
}

type metadataPrunePosition struct {
	Until time.Time
	Key   string
}

func (h *EnrichmentHost) pruneMetadata(ctx context.Context, at time.Time, position *metadataPrunePosition) (int, *metadataPrunePosition, error) {
	tx, err := h.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, position, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SET LOCAL statement_timeout='2s'`); err != nil {
		return 0, position, err
	}
	var until *time.Time
	var key *string
	if position != nil {
		until = &position.Until
		key = &position.Key
	}
	var scanned, deleted int
	var lastUntil sql.NullTime
	var lastKey sql.NullString
	err = tx.QueryRowContext(ctx, `WITH candidates AS MATERIALIZED(SELECT canonical_key,stale_until FROM wire_link_metadata_cache WHERE stale_until IS NOT NULL AND stale_until<=$1 AND ($2::timestamptz IS NULL OR (stale_until,canonical_key)>($2,$3::text)) ORDER BY stale_until,canonical_key LIMIT 100),
deletable AS MATERIALIZED(SELECT cache.canonical_key FROM candidates candidate JOIN wire_link_metadata_cache cache USING(canonical_key)
LEFT JOIN LATERAL(SELECT TRUE AS protected FROM wire_items item WHERE item.canonical_key=cache.canonical_key AND item.eligible AND item.expires_at>$1 AND item.canonical_url LIKE 'https://%' LIMIT 1 OFFSET 0) live ON TRUE
WHERE cache.stale_until IS NOT NULL AND cache.stale_until<=$1 AND NOT(cache.status='fetching' AND cache.retry_after>$1) AND live.protected IS NULL FOR UPDATE OF cache SKIP LOCKED),
deleted AS(DELETE FROM wire_link_metadata_cache cache USING deletable WHERE cache.canonical_key=deletable.canonical_key RETURNING 1)
SELECT (SELECT COUNT(*) FROM candidates),last.stale_until,last.canonical_key,(SELECT COUNT(*) FROM deleted) FROM(SELECT 1)singleton LEFT JOIN LATERAL(SELECT stale_until,canonical_key FROM candidates ORDER BY stale_until DESC,canonical_key DESC LIMIT 1)last ON TRUE`, at, until, key).Scan(&scanned, &lastUntil, &lastKey, &deleted)
	if err != nil {
		return 0, position, err
	}
	if err := tx.Commit(); err != nil {
		return 0, position, err
	}
	if scanned < 100 {
		return scanned, nil, nil
	}
	return scanned, &metadataPrunePosition{lastUntil.Time, lastKey.String}, nil
}
func (h *EnrichmentHost) disposableBatch(ctx context.Context, at time.Time, position **metadataPrunePosition) (int, error) {
	for _, table := range []string{"wire_item_mentions", "wire_talked_accounts"} {
		if _, err := h.DB.ExecContext(ctx, `DELETE FROM `+table+` WHERE ctid IN(SELECT ctid FROM `+table+` WHERE expires_at<=$1 LIMIT 500 FOR UPDATE SKIP LOCKED)`, at); err != nil {
			return 0, err
		}
	}
	deadline := time.Now().Add(2 * time.Second)
	for batch := 0; batch < 20 && time.Now().Before(deadline); batch++ {
		scanned, next, err := h.pruneMetadata(ctx, at, *position)
		if err != nil {
			return 0, err
		}
		*position = next
		if scanned < 100 {
			break
		}
	}
	return 0, nil
}
func (h *EnrichmentHost) healthBatch(ctx context.Context, at time.Time) (int, error) {
	tx, err := h.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SET LOCAL statement_timeout='2s'`); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx, `SET LOCAL lock_timeout='500ms'`); err != nil {
		return 0, err
	}
	var hits, stale, misses, failures, people, fresh int64
	var age float64
	if err := tx.QueryRowContext(ctx, metadataHealthSQL, at).Scan(&hits, &stale, &misses, &failures, &age, &people, &fresh); err != nil {
		return 0, err
	}
	slog.Info("Wire enrichment health", "metadata_hits", hits, "metadata_stale", stale, "metadata_misses", misses, "metadata_failures", failures, "oldest_failure_seconds", age, "people_eligible", people, "people_profiles_fresh", fresh)
	return 0, tx.Commit()
}
