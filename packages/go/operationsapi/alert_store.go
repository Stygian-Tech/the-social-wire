package operationsapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"strconv"
	"time"
)

const alertColumns = `id,rule,condition_key,severity,status,summary,evidence::text,runbook_slug,opened_at,updated_at,acknowledged_by_did,resolved_by_did,delivery_attempts,last_delivery_error,next_delivery_at,delivery_dead_lettered_at,version`

func scanAlert(row interface{ Scan(...any) error }, environment string) (Alert, error) {
	a := Alert{Environment: environment}
	var evidence string
	var opened, updated time.Time
	var next, dead *time.Time
	err := row.Scan(&a.ID, &a.Rule, &a.ConditionKey, &a.Severity, &a.Status, &a.Summary, &evidence, &a.RunbookSlug, &opened, &updated, &a.AcknowledgedByDID, &a.ResolvedByDID, &a.DeliveryAttempts, &a.LastDeliveryError, &next, &dead, &a.Version)
	if err != nil {
		return a, err
	}
	a.OpenedAt = WireTime{opened}
	a.UpdatedAt = WireTime{updated}
	if next != nil {
		a.NextDeliveryAt = &WireTime{*next}
	}
	if dead != nil {
		a.DeliveryDeadLetteredAt = &WireTime{*dead}
	}
	switch a.Status {
	case "open", "acknowledged", "resolved":
	default:
		a.Status = "open"
	}
	if json.Unmarshal([]byte(evidence), &a.Evidence) != nil || a.Evidence == nil {
		a.Evidence = map[string]string{}
	}
	return a, nil
}
func (s *PostgresStore) FetchAlert(ctx context.Context, id string) (*Alert, error) {
	a, err := scanAlert(s.DB.QueryRow(ctx, `SELECT `+alertColumns+` FROM operations_alerts WHERE environment=$1 AND id=$2 LIMIT 1`, s.Environment, id), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}
func (s *PostgresStore) ListAlerts(ctx context.Context, view string, limit int, before *string) (Page[Alert], error) {
	statuses := []string{}
	switch view {
	case "active":
		statuses = []string{"open", "acknowledged"}
	case "history":
		statuses = []string{"resolved"}
	case "all":
		statuses = []string{"open", "acknowledged", "resolved"}
	default:
		return Page[Alert]{}, HTTPError{400, "Unknown alert lifecycle view"}
	}
	limit = max(1, min(limit, 250))
	var date *time.Time
	var id *string
	if before != nil {
		cursor, err := DecodePaginationCursor(*before)
		if err != nil {
			return Page[Alert]{}, err
		}
		date = &cursor.Date
		id = &cursor.ID
	}
	rows, err := s.DB.Query(ctx, `SELECT `+alertColumns+` FROM operations_alerts WHERE environment=$1 AND status=ANY($2::text[]) AND ($3::timestamptz IS NULL OR opened_at<$3::timestamptz OR (opened_at=$3::timestamptz AND id<$4::text)) ORDER BY opened_at DESC,id DESC LIMIT $5`, s.Environment, statuses, date, id, limit+1)
	if err != nil {
		return Page[Alert]{}, err
	}
	items := []Alert{}
	for rows.Next() {
		a, err := scanAlert(rows, s.Environment)
		if err != nil {
			rows.Close()
			return Page[Alert]{}, err
		}
		items = append(items, a)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return Page[Alert]{}, err
	}
	page := Page[Alert]{Items: items}
	if err = s.DB.QueryRow(ctx, `SELECT count(*) FROM operations_alerts WHERE environment=$1 AND status=ANY($2::text[])`, s.Environment, statuses).Scan(&page.TotalCount); err != nil {
		return page, err
	}
	if len(items) > limit {
		page.Items = items[:limit]
		last := page.Items[len(page.Items)-1]
		cursor := EncodePaginationCursor(last.OpenedAt.Time, last.ID)
		page.NextCursor = &cursor
	}
	return page, nil
}
func (s *PostgresStore) OpenAlert(ctx context.Context, rule, condition, severity, summary string, evidence map[string]string, runbook string, at time.Time) (Alert, error) {
	id, err := randomUUID()
	if err != nil {
		return Alert{}, err
	}
	payload, err := json.Marshal(BoundedAttributes(evidence, 256))
	if err != nil {
		return Alert{}, err
	}
	return scanAlert(s.DB.QueryRow(ctx, `INSERT INTO operations_alerts(environment,id,rule,condition_key,severity,status,summary,evidence,runbook_slug,opened_at,updated_at,next_delivery_at,version) VALUES($1,$2,$3,$4,$5,'open',$6,$7::jsonb,$8,$9,$9,$9,0) ON CONFLICT(environment,condition_key) WHERE environment<>'__legacy_unscoped__' AND status!='resolved' DO UPDATE SET severity=EXCLUDED.severity,summary=EXCLUDED.summary,evidence=EXCLUDED.evidence,runbook_slug=EXCLUDED.runbook_slug,updated_at=EXCLUDED.updated_at,version=operations_alerts.version+1 RETURNING `+alertColumns, s.Environment, id, boundedText(rule, 128), boundedText(condition, 192), boundedText(severity, 32), boundedText(summary, 512), string(payload), boundedText(runbook, 128), at), s.Environment)
}
func (s *PostgresStore) TransitionAlert(ctx context.Context, id, status string, version int, operatorDID, key string, requestID, note *string, at time.Time) (Alert, error) {
	return s.mutateAlert(ctx, id, status, version, operatorDID, key, requestID, note, at, false)
}
func (s *PostgresStore) RetryAlertDelivery(ctx context.Context, id string, version int, operatorDID, key string, requestID, note *string, at time.Time) (Alert, error) {
	return s.mutateAlert(ctx, id, "", version, operatorDID, key, requestID, note, at, true)
}
func (s *PostgresStore) mutateAlert(ctx context.Context, id, status string, version int, operatorDID, key string, requestID, note *string, at time.Time, retry bool) (Alert, error) {
	action := "alert." + status
	fields := map[string]*string{"operatorDid": &operatorDID, "note": note, "status": &status}
	if retry {
		action = "alert.delivery_retry"
		delete(fields, "status")
	}
	fingerprint := IdempotencyFingerprint(action, "alert", &id, &version, fields)
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Alert{}, err
	}
	defer tx.Rollback(context.Background())
	local, _ := NewPostgresStore(tx, s.Environment)
	replay, err := local.existingIdempotency(ctx, key, action, "alert", &id, fingerprint)
	if err != nil {
		return Alert{}, err
	}
	audit := MutationAudit{OperatorDID: operatorDID, Action: action, TargetType: "alert", TargetID: &id, IdempotencyKey: &key, ExpectedVersion: &version, Note: note, OccurredAt: at}
	if requestID != nil {
		audit.RequestID = *requestID
	}
	if replay != nil {
		var a Alert
		if json.Unmarshal(replay, &a) != nil || a.ID != id {
			return Alert{}, ErrIdempotencyConflict
		}
		audit.After = map[string]string{"status": a.Status, "version": strconv.Itoa(a.Version)}
		audit.Outcome = "idempotent_replay"
		if err = local.RecordAudit(ctx, audit); err != nil {
			return Alert{}, err
		}
		return a, tx.Commit(ctx)
	}
	current, err := scanAlert(tx.QueryRow(ctx, `SELECT `+alertColumns+` FROM operations_alerts WHERE environment=$1 AND id=$2 FOR UPDATE`, s.Environment, id), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return Alert{}, ErrNotFound
	}
	if err != nil {
		return Alert{}, err
	}
	if current.Version != version {
		return Alert{}, ErrVersionConflict
	}
	if (retry && current.Status == "resolved") || (!retry && !((current.Status == "open" && (status == "acknowledged" || status == "resolved")) || (current.Status == "acknowledged" && status == "resolved"))) {
		return Alert{}, ErrInvalidTransition
	}
	var updated Alert
	if retry {
		updated, err = scanAlert(tx.QueryRow(ctx, `UPDATE operations_alerts SET next_delivery_at=$3,delivery_dead_lettered_at=NULL,delivery_attempts=0,last_delivery_error=NULL,updated_at=$3,version=version+1 WHERE environment=$1 AND id=$2 AND status!='resolved' AND version=$4 RETURNING `+alertColumns, s.Environment, id, at, version), s.Environment)
	} else {
		var acknowledged, resolved *string
		if status == "acknowledged" {
			acknowledged = &operatorDID
		}
		if status == "resolved" {
			resolved = &operatorDID
		}
		updated, err = scanAlert(tx.QueryRow(ctx, `UPDATE operations_alerts SET status=$3,updated_at=$4,acknowledged_by_did=COALESCE($5,acknowledged_by_did),resolved_by_did=COALESCE($6,resolved_by_did),expires_at=CASE WHEN $3='resolved' THEN $7 ELSE expires_at END,version=version+1 WHERE environment=$1 AND id=$2 AND version=$8 RETURNING `+alertColumns, s.Environment, id, status, at, acknowledged, resolved, at.Add(365*24*time.Hour), version), s.Environment)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return Alert{}, ErrVersionConflict
	}
	if err != nil {
		return Alert{}, err
	}
	if !retry && status == "resolved" {
		if err = local.extendLifecycleRetention(ctx, "alert", id, at); err != nil {
			return Alert{}, err
		}
	}
	outcome := "succeeded"
	if retry {
		outcome = "queued"
	}
	if err = local.insertIdempotency(ctx, key, action, "alert", id, outcome, fingerprint, updated, at); err != nil {
		return Alert{}, err
	}
	audit.Before = map[string]string{"status": current.Status, "version": strconv.Itoa(current.Version)}
	audit.After = map[string]string{"status": updated.Status, "version": strconv.Itoa(updated.Version)}
	audit.Outcome = outcome
	if retry {
		audit.Before["deliveryAttempts"] = strconv.Itoa(current.DeliveryAttempts)
		audit.After = map[string]string{"delivery": "queued", "deliveryAttempts": "0", "version": strconv.Itoa(updated.Version)}
	}
	if err = local.RecordAudit(ctx, audit); err != nil {
		return Alert{}, err
	}
	return updated, tx.Commit(ctx)
}
func AlertDeliveryDelay(id string, attempt int) time.Duration {
	bounded := max(1, min(attempt, 7))
	base := min(3200, 15*(1<<bounded))
	jitterMaximum := max(1, base/4)
	hash := uint64(14695981039346656037)
	for _, b := range []byte(id + ":" + strconv.Itoa(bounded)) {
		hash ^= uint64(b)
		hash *= 1099511628211
	}
	return time.Duration(min(3600, base+int(hash%uint64(jitterMaximum+1)))) * time.Second
}
func (s *PostgresStore) RecordAlertDelivery(ctx context.Context, id string, deliveryError *string, at time.Time) error {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	var attempts int
	err = tx.QueryRow(ctx, `SELECT delivery_attempts FROM operations_alerts WHERE environment=$1 AND id=$2 AND status!='resolved' FOR UPDATE`, s.Environment, id).Scan(&attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return tx.Commit(ctx)
	}
	if err != nil {
		return err
	}
	attempts++
	var next, dead *time.Time
	if deliveryError != nil {
		if attempts >= 8 {
			dead = &at
		} else {
			value := at.Add(AlertDeliveryDelay(id, attempts))
			next = &value
		}
	}
	var failure *string
	if deliveryError != nil {
		value := boundedText(*deliveryError, 256)
		failure = &value
	}
	_, err = tx.Exec(ctx, `UPDATE operations_alerts SET delivery_attempts=delivery_attempts+1,last_delivery_error=$3,next_delivery_at=$4,delivery_dead_lettered_at=$5,updated_at=$6,version=version+1 WHERE environment=$1 AND id=$2 AND status!='resolved'`, s.Environment, id, failure, next, dead, at)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}
func (s *PostgresStore) ListAlertsPendingDelivery(ctx context.Context, limit int, at time.Time) ([]Alert, error) {
	rows, err := s.DB.Query(ctx, `SELECT `+alertColumns+` FROM operations_alerts WHERE environment=$1 AND status!='resolved' AND delivery_dead_lettered_at IS NULL AND next_delivery_at<=$2 ORDER BY next_delivery_at,opened_at LIMIT $3`, s.Environment, at, max(1, min(limit, 100)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	alerts := []Alert{}
	for rows.Next() {
		alert, err := scanAlert(rows, s.Environment)
		if err != nil {
			return nil, err
		}
		alerts = append(alerts, alert)
	}
	return alerts, rows.Err()
}
func (s *PostgresStore) ResolveAlert(ctx context.Context, condition string, at time.Time) error {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	rows, err := tx.Query(ctx, `UPDATE operations_alerts SET status='resolved',resolved_by_did='system:evaluator',updated_at=$3,expires_at=$4,version=version+1 WHERE environment=$1 AND condition_key=$2 AND status!='resolved' RETURNING id`, s.Environment, condition, at, at.Add(365*24*time.Hour))
	if err != nil {
		return err
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	local, _ := NewPostgresStore(tx, s.Environment)
	for _, id := range ids {
		if err = local.extendLifecycleRetention(ctx, "alert", id, at); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
