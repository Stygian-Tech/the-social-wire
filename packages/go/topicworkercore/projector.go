package topicworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

type queryExecutor interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}
type article struct {
	Key, Title, Domain, Fingerprint string
	Summary                         sql.NullString
	Expiry, Updated                 time.Time
}

func (w *Worker) projectFinance(ctx context.Context, at time.Time) error {
	catalog, err := w.financeCatalog(ctx)
	if err != nil || catalog == nil {
		return err
	}
	count, _, err := projectWindow(ctx, w.DB, "finance", financeQuality, at, catalog.Revision, financecore.ResolverVersion, nil, 12, func(a article) (any, error) {
		return financecore.Analyze(a.Title, a.Summary.String, nil, financecore.VerifiedInstrumentIDs(a.Domain, ""), catalog.Snapshot.Instruments), nil
	}, catalog.Snapshot.Version, catalog.Fingerprint)
	if err != nil {
		return err
	}
	_, next, err := projectWindow(ctx, w.DB, "finance", financeQuality, at, catalog.Revision, financecore.ResolverVersion, w.financeCursor, 25-count, func(a article) (any, error) {
		return financecore.Analyze(a.Title, a.Summary.String, nil, financecore.VerifiedInstrumentIDs(a.Domain, ""), catalog.Snapshot.Instruments), nil
	}, catalog.Snapshot.Version, catalog.Fingerprint)
	if err != nil {
		return err
	}
	w.financeCursor = next
	_, err = w.DB.ExecContext(ctx, `DELETE FROM finance_article_analysis WHERE canonical_key IN (SELECT canonical_key FROM finance_article_analysis WHERE expires_at<=$1 ORDER BY expires_at LIMIT 100)`, at)
	return err
}
func (w *Worker) projectSports(ctx context.Context, at time.Time) error {
	catalog, err := w.sportsCatalog(ctx)
	if err != nil || catalog == nil {
		return err
	}
	if catalog.Version != sportscore.ReviewedCatalogVersion && !strings.HasPrefix(catalog.Version, sportscore.ReviewedCatalogVersion+":") {
		return nil
	}
	tx, err := w.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var acquired bool
	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(hashtextextended('socialwire:sports-article-projection',0))`).Scan(&acquired); err != nil {
		return err
	}
	if !acquired {
		return nil
	}
	for _, setting := range []string{`SET LOCAL lock_timeout='100ms'`, `SET LOCAL statement_timeout='5s'`} {
		if _, err := tx.ExecContext(ctx, setting); err != nil {
			return err
		}
	}
	index := sportscore.NewEntityIndex(catalog.Entities)
	analyze := func(a article) (any, error) { return sportscore.AnalyzeIndex(a.Title, a.Summary.String, index), nil }
	count, _, err := projectWindow(ctx, tx, "sports", sportsQuality, at, catalog.Version, sportscore.ResolverVersion, nil, 12, analyze, catalog.Version, "")
	if err != nil {
		return err
	}
	_, next, err := projectWindow(ctx, tx, "sports", sportsQuality, at, catalog.Version, sportscore.ResolverVersion, w.sportsCursor, 25-count, analyze, catalog.Version, "")
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM sports_article_analysis WHERE canonical_key IN (SELECT canonical_key FROM sports_article_analysis WHERE expires_at<=$1 ORDER BY expires_at LIMIT 100)`, at); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	w.sportsCursor = next
	return nil
}
func projectWindow(ctx context.Context, db queryExecutor, topic, quality string, at time.Time, revision, resolver string, anchor *cursor, limit int, analyze func(article) (any, error), snapshotVersion, overrideFingerprint string) (int, *cursor, error) {
	if limit <= 0 {
		return 0, anchor, nil
	}
	anchorDate := time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC)
	anchorKey := ""
	if anchor != nil {
		anchorDate = anchor.Date
		anchorKey = anchor.Key
	}
	rows, err := db.QueryContext(ctx, `SELECT canonical_key,updated_at FROM wire_items WHERE eligible=TRUE AND target_kind IN ('external_article','standard_site_document') AND commercial_class<>'probable_ad' AND source_confidence>=0.75 AND updated_at<=$1 AND (updated_at<$1 OR canonical_key>$2) ORDER BY updated_at DESC,canonical_key LIMIT 1000`, anchorDate, anchorKey)
	if err != nil {
		return 0, anchor, err
	}
	keys := []string{}
	var lastWindow *cursor
	for rows.Next() {
		var key string
		var updated time.Time
		if err := rows.Scan(&key, &updated); err != nil {
			rows.Close()
			return 0, anchor, err
		}
		keys = append(keys, key)
		lastWindow = &cursor{updated, key}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, anchor, err
	}
	if len(keys) == 0 {
		return 0, nil, nil
	}
	rows, err = db.QueryContext(ctx, `WITH scan_window AS MATERIALIZED (SELECT * FROM wire_items WHERE canonical_key=ANY($4::text[])) SELECT item.canonical_key,item.title,item.summary,item.source_domain,md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text),item.expires_at,item.updated_at FROM scan_window item LEFT JOIN `+topic+`_article_analysis analysis ON analysis.canonical_key=item.canonical_key WHERE `+quality+` AND (analysis.canonical_key IS NULL OR analysis.source_fingerprint<>md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text) OR analysis.catalog_revision<>$2 OR analysis.resolver_version<>$3 OR analysis.expires_at<=$1) ORDER BY item.updated_at DESC,item.canonical_key LIMIT $5`, at, revision, resolver, keys, limit)
	if err != nil {
		return 0, anchor, err
	}
	selected := []article{}
	for rows.Next() {
		var a article
		if err := rows.Scan(&a.Key, &a.Title, &a.Summary, &a.Domain, &a.Fingerprint, &a.Expiry, &a.Updated); err != nil {
			rows.Close()
			return 0, anchor, err
		}
		selected = append(selected, a)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, anchor, err
	}
	count := 0
	next := lastWindow
	for _, a := range selected {
		if err := ctx.Err(); err != nil {
			return count, anchor, err
		}
		analysis, err := analyze(a)
		if err != nil {
			return count, anchor, err
		}
		payload, err := json.Marshal(analysis)
		if err != nil {
			return count, anchor, err
		}
		args := []any{a.Fingerprint, revision, resolver, string(payload), at, a.Expiry, a.Key, snapshotVersion}
		overrideFence := ""
		if topic == "finance" {
			overrideFence = ` AND (SELECT md5(COALESCE(jsonb_agg(payload ORDER BY instrument_id),'[]'::jsonb)::text) FROM (SELECT instrument_id,payload FROM finance_instruments WHERE provider_key LIKE 'BBG%' ORDER BY updated_at DESC,instrument_id LIMIT 150) discovered)=$9`
			args = append(args, overrideFingerprint)
		}
		result, err := db.ExecContext(ctx, `INSERT INTO `+topic+`_article_analysis(canonical_key,source_fingerprint,catalog_revision,resolver_version,payload,analyzed_at,expires_at) SELECT item.canonical_key,$1,$2,$3,$4::jsonb,$5,$6 FROM wire_items item WHERE item.canonical_key=$7 AND item.eligible=TRUE AND item.expires_at>$5 AND md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)=$1 AND EXISTS(SELECT 1 FROM `+topic+`_catalog_snapshots WHERE is_active=TRUE AND version=$8)`+overrideFence+` ON CONFLICT(canonical_key) DO UPDATE SET source_fingerprint=EXCLUDED.source_fingerprint,catalog_revision=EXCLUDED.catalog_revision,resolver_version=EXCLUDED.resolver_version,payload=EXCLUDED.payload,analyzed_at=EXCLUDED.analyzed_at,expires_at=EXCLUDED.expires_at WHERE `+topic+`_article_analysis.analyzed_at<=EXCLUDED.analyzed_at`, args...)
		if err != nil {
			return count, anchor, err
		}
		accepted, err := result.RowsAffected()
		if err != nil {
			return count, anchor, err
		}
		count += int(accepted)
		next = &cursor{a.Updated, a.Key}
	}
	return count, next, nil
}
