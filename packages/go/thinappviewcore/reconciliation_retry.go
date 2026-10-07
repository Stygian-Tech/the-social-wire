package thinappviewcore

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"time"
)

var ErrReconciliationRetryScope = errors.New("invalid reconciliation retry scope")
var ErrReconciliationRetryCount = errors.New("reconciliation retry count differs from expected")

const MaximumOperatorReconciliationRetries = 100

var reconciliationRetryGeneration = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,255}$`)

// OperatorRetryFailedReconciliations requeues only failed requests whose original
// inbox event remains an unreconciled dead letter. It preserves historical
// attempts, recovery checkpoints and all terminal event/watermark evidence.
// Operators must supply the exact number expected in this environment/generation.
func (s InboxStore) OperatorRetryFailedReconciliations(ctx context.Context, environment, generation string, expectedCount int, at time.Time) (int, error) {
	if (environment != "dev" && environment != "prod") || !reconciliationRetryGeneration.MatchString(generation) || expectedCount < 1 || expectedCount > MaximumOperatorReconciliationRetries || at.IsZero() || s.DB == nil {
		return 0, ErrReconciliationRetryScope
	}
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SET LOCAL lock_timeout = '5s'; SET LOCAL statement_timeout = '10s'`); err != nil {
		return 0, err
	}
	// Lock both the request and matching evidence. Do not skip locked rows: a
	// partial selection must never masquerade as the operator's exact scope.
	rows, err := tx.QueryContext(ctx, `SELECT request.id
FROM appview_ingestion_reconciliation_requests request
JOIN appview_ingestion_inbox inbox
  ON inbox.environment = request.environment
 AND inbox.source_generation = request.source_generation
 AND inbox.seq = request.trigger_seq
 AND inbox.repo_did = request.repo_did
WHERE request.environment = $1 AND request.source_generation = $2
  AND request.status = 'failed'
  AND inbox.status = 'dead_letter' AND inbox.reconciled_at IS NULL
ORDER BY request.trigger_seq, request.id
LIMIT $3 FOR UPDATE OF request, inbox`, environment, generation, expectedCount+1)
	if err != nil {
		return 0, err
	}
	ids := make([]string, 0, expectedCount+1)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, err
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	if len(ids) != expectedCount {
		return 0, ErrReconciliationRetryCount
	}
	result, err := tx.ExecContext(ctx, `UPDATE appview_ingestion_reconciliation_requests
SET status = 'pending', next_attempt_at = $1,
    lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL, updated_at = $1
WHERE environment = $2 AND source_generation = $3 AND status = 'failed'
  AND id = ANY($4::text[])`, at, environment, generation, ids)
	if err != nil {
		return 0, err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if count != int64(expectedCount) {
		return 0, ErrReconciliationRetryCount
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return expectedCount, nil
}
