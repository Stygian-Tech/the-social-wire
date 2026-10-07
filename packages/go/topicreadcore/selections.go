package topicreadcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"log/slog"
	"strings"
	"time"
)

type SelectionProjection struct {
	DB   *sql.DB
	Repo PublicRepoReader
}
type selectionRow struct{ key, kind, reference string }
type FinanceSelections struct{ Instruments, Sectors []string }

func (p *SelectionProjection) Finance(ctx context.Context, viewer string, refresh bool, now time.Time) (FinanceSelections, error) {
	result := FinanceSelections{[]string{}, []string{}}
	if viewer == "" {
		return result, nil
	}
	rows, err := p.selections(ctx, "finance", viewer, refresh, now)
	if err != nil {
		return result, err
	}
	for _, r := range rows {
		if r.kind == "instrument" {
			result.Instruments = append(result.Instruments, r.reference)
		} else {
			result.Sectors = append(result.Sectors, r.reference)
		}
	}
	return result, nil
}
func (p *SelectionProjection) Sports(ctx context.Context, viewer string, refresh bool, now time.Time) ([]sportscore.Selection, error) {
	result := []sportscore.Selection{}
	if viewer == "" {
		return result, nil
	}
	rows, err := p.selections(ctx, "sports", viewer, refresh, now)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		result = append(result, sportscore.Selection{Reference: r.reference, Action: r.kind})
	}
	return result, nil
}
func (p *SelectionProjection) selections(ctx context.Context, domain, viewer string, refresh bool, now time.Time) ([]selectionRow, error) {
	var synced time.Time
	err := p.DB.QueryRowContext(ctx, `SELECT synced_at FROM `+domain+`_selection_sync WHERE viewer_did=$1`, viewer).Scan(&synced)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if refresh || err != nil || now.Sub(synced) >= time.Minute {
		err = p.refresh(ctx, domain, viewer, now)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			if refresh {
				return nil, ErrUnavailable
			}
			slog.Warn("Topic PDS reconciliation failed; retaining projected selections", "domain", domain)
		}
	}
	kind := "kind"
	if domain == "sports" {
		kind = "action"
	}
	rows, err := p.DB.QueryContext(ctx, `SELECT record_key,`+kind+`,reference FROM `+domain+`_selections WHERE viewer_did=$1 ORDER BY record_key`, viewer)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []selectionRow{}
	for rows.Next() {
		var value selectionRow
		if err := rows.Scan(&value.key, &value.kind, &value.reference); err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, rows.Err()
}
func (p *SelectionProjection) refresh(ctx context.Context, domain, viewer string, now time.Time) error {
	if p.Repo == nil {
		return ErrUnavailable
	}
	collection := "app.thesocialwire." + domain + ".selection"
	values := []selectionRow{}
	cursor := ""
	observed := map[string]bool{}
	completed := false
	stringField := func(raw json.RawMessage) string { var value string; _ = json.Unmarshal(raw, &value); return value }
	for range 20 {
		page, err := p.Repo.ListRecords(ctx, viewer, collection, cursor, 100, false)
		if err != nil {
			return err
		}
		for _, record := range page.Records {
			if stringField(record.Value["$type"]) != collection {
				continue
			}
			reference := stringField(record.Value["reference"])
			if reference == "" || len(reference) > 128 {
				continue
			}
			parts := strings.Split(record.URI, "/")
			key := parts[len(parts)-1]
			if record.URI != "at://"+viewer+"/"+collection+"/"+key {
				continue
			}
			kind := ""
			if domain == "finance" {
				kind = stringField(record.Value["kind"])
				if (kind != "instrument" && kind != "sector") || key != financecore.SelectionRecordKey(kind, reference) {
					continue
				}
			} else {
				kind = stringField(record.Value["action"])
				if (kind != "follow" && kind != "mute") || key != sportscore.SelectionRecordKey(reference) {
					continue
				}
			}
			values = append(values, selectionRow{key, kind, reference})
		}
		cursor = page.Cursor
		if cursor == "" {
			completed = true
			break
		}
		if observed[cursor] {
			return ErrUnavailable
		}
		observed[cursor] = true
	}
	if !completed {
		return ErrUnavailable
	}
	return p.apply(ctx, domain, viewer, values, now)
}
func (p *SelectionProjection) apply(ctx context.Context, domain, viewer string, values []selectionRow, now time.Time) error {
	tx, err := p.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	lock := 91827
	column := "kind"
	if domain == "sports" {
		lock = 91828
		column = "action"
	}
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,$2))`, viewer, lock); err != nil {
		return err
	}
	table := domain + "_selections"
	versions := domain + "_selection_versions"
	if _, err := tx.ExecContext(ctx, `INSERT INTO `+versions+`(viewer_did,record_key,event_at,repo_rev,is_deleted) SELECT viewer_did,record_key,updated_at,'',FALSE FROM `+table+` WHERE viewer_did=$1 ON CONFLICT(viewer_did,record_key) DO NOTHING`, viewer); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM `+table+` selection WHERE viewer_did=$1 AND NOT EXISTS(SELECT 1 FROM `+versions+` version WHERE version.viewer_did=selection.viewer_did AND version.record_key=selection.record_key AND version.event_at>$2)`, viewer, now); err != nil {
		return err
	}
	keys := []string{}
	for _, v := range values {
		keys = append(keys, v.key)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE `+versions+` SET event_at=$2,repo_rev='',is_deleted=TRUE WHERE viewer_did=$1 AND event_at<=$2 AND NOT(record_key=ANY($3::text[]))`, viewer, now, keys); err != nil {
		return err
	}
	for _, v := range values {
		var accepted string
		err := tx.QueryRowContext(ctx, `INSERT INTO `+versions+`(viewer_did,record_key,event_at,repo_rev,is_deleted) VALUES($1,$2,$3,'',FALSE) ON CONFLICT(viewer_did,record_key) DO UPDATE SET event_at=EXCLUDED.event_at,repo_rev='',is_deleted=FALSE WHERE `+versions+`.event_at<=EXCLUDED.event_at RETURNING record_key`, viewer, v.key, now).Scan(&accepted)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO `+table+`(viewer_did,record_key,`+column+`,reference,updated_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(viewer_did,record_key) DO UPDATE SET `+column+`=EXCLUDED.`+column+`,reference=EXCLUDED.reference,updated_at=EXCLUDED.updated_at`, viewer, v.key, v.kind, v.reference, now); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO `+domain+`_selection_sync(viewer_did,synced_at) VALUES($1,$2) ON CONFLICT(viewer_did) DO UPDATE SET synced_at=EXCLUDED.synced_at`, viewer, now); err != nil {
		return err
	}
	return tx.Commit()
}
