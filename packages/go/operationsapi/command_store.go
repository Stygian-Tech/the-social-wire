package operationsapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"strconv"
	"time"
)

const commandColumns = `id,action,status,requested_by_did,audit_note,claimed_by,lease_expires_at,failure_reason,created_at,updated_at,completed_at,version`

func scanCommand(row interface{ Scan(...any) error }, env string) (WorkerCommand, error) {
	command := WorkerCommand{Environment: env}
	var created, updated time.Time
	var lease, completed *time.Time
	err := row.Scan(&command.ID, &command.Action, &command.Status, &command.RequestedByDID, &command.AuditNote, &command.ClaimedBy, &lease, &command.FailureReason, &created, &updated, &completed, &command.Version)
	command.CreatedAt = WireTime{created}
	command.UpdatedAt = WireTime{updated}
	if lease != nil {
		command.LeaseExpiresAt = &WireTime{*lease}
	}
	if completed != nil {
		command.CompletedAt = &WireTime{*completed}
	}
	switch command.Status {
	case "queued", "running", "completed", "failed":
	default:
		command.Status = "queued"
	}
	if command.Action != "reconnect_jetstream" {
		command.Action = "reconnect_jetstream"
	}
	return command, err
}
func (s *PostgresStore) CreateCommand(ctx context.Context, action, operatorDID string, note *string, version int, key string, requestID *string, at time.Time) (WorkerCommand, error) {
	if action != "reconnect_jetstream" {
		return WorkerCommand{}, ErrInvalidTransition
	}
	name := "jetstream.reconnect_requested"
	fingerprint := IdempotencyFingerprint(name, "command", nil, &version, map[string]*string{"operatorDid": &operatorDID, "auditNote": note})
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return WorkerCommand{}, err
	}
	defer tx.Rollback(context.Background())
	local, _ := NewPostgresStore(tx, s.Environment)
	audit := MutationAudit{OperatorDID: operatorDID, Action: name, TargetType: "command", IdempotencyKey: &key, ExpectedVersion: &version, Note: note, OccurredAt: at}
	if requestID != nil {
		audit.RequestID = *requestID
	}
	replay, err := local.existingIdempotency(ctx, key, name, "command", nil, fingerprint)
	if err != nil {
		return WorkerCommand{}, err
	}
	if replay != nil {
		var command WorkerCommand
		if json.Unmarshal(replay, &command) != nil || command.ID == "" {
			return WorkerCommand{}, ErrIdempotencyConflict
		}
		audit.TargetID = &command.ID
		audit.Outcome = "idempotent_replay"
		audit.After = map[string]string{"status": command.Status, "version": strconv.Itoa(command.Version), "targetId": command.ID}
		if err = local.RecordAudit(ctx, audit); err != nil {
			return WorkerCommand{}, err
		}
		return command, tx.Commit(ctx)
	}
	actual := 0
	err = tx.QueryRow(ctx, `SELECT version FROM appview_ingestion_stream_state WHERE environment=$1 AND source='jetstream' FOR UPDATE`, s.Environment).Scan(&actual)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return WorkerCommand{}, err
	}
	if actual != version {
		return WorkerCommand{}, ErrVersionConflict
	}
	id, err := randomUUID()
	if err != nil {
		return WorkerCommand{}, err
	}
	var boundedNote *string
	if note != nil {
		value := boundedText(*note, 280)
		boundedNote = &value
	}
	command, err := scanCommand(tx.QueryRow(ctx, `INSERT INTO operations_commands(environment,id,action,status,requested_by_did,audit_note,created_at,updated_at,expires_at,version) VALUES($1,$2,$3,'queued',$4,$5,$6,$6,$7,0) RETURNING `+commandColumns, s.Environment, id, action, operatorDID, boundedNote, at, at.Add(365*24*time.Hour)), s.Environment)
	if err != nil {
		return WorkerCommand{}, err
	}
	if err = local.insertIdempotency(ctx, key, name, "command", id, "queued", fingerprint, command, at); err != nil {
		return WorkerCommand{}, err
	}
	audit.TargetID = &id
	audit.Before = map[string]string{"streamVersion": strconv.Itoa(actual)}
	audit.After = map[string]string{"status": "queued", "version": "0", "targetId": id}
	audit.Outcome = "queued"
	if err = local.RecordAudit(ctx, audit); err != nil {
		return WorkerCommand{}, err
	}
	return command, tx.Commit(ctx)
}
func (s *PostgresStore) ListCommands(ctx context.Context, limit int, before *string) (Page[WorkerCommand], error) {
	limit = max(1, min(limit, 250))
	var date *time.Time
	var id *string
	if before != nil {
		cursor, err := DecodePaginationCursor(*before)
		if err != nil {
			return Page[WorkerCommand]{}, err
		}
		date = &cursor.Date
		id = &cursor.ID
	}
	rows, err := s.DB.Query(ctx, `SELECT `+commandColumns+` FROM operations_commands WHERE environment=$1 AND ($2::timestamptz IS NULL OR created_at<$2::timestamptz OR (created_at=$2::timestamptz AND id<$3::text)) ORDER BY created_at DESC,id DESC LIMIT $4`, s.Environment, date, id, limit+1)
	if err != nil {
		return Page[WorkerCommand]{}, err
	}
	items := []WorkerCommand{}
	for rows.Next() {
		command, err := scanCommand(rows, s.Environment)
		if err != nil {
			rows.Close()
			return Page[WorkerCommand]{}, err
		}
		items = append(items, command)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return Page[WorkerCommand]{}, err
	}
	page := Page[WorkerCommand]{Items: items}
	if err = s.DB.QueryRow(ctx, `SELECT count(*) FROM operations_commands WHERE environment=$1`, s.Environment).Scan(&page.TotalCount); err != nil {
		return page, err
	}
	if len(items) > limit {
		page.Items = items[:limit]
		last := page.Items[len(page.Items)-1]
		cursor := EncodePaginationCursor(last.CreatedAt.Time, last.ID)
		page.NextCursor = &cursor
	}
	return page, nil
}
func (s *PostgresStore) ClaimNextCommand(ctx context.Context, action, workerID string, at time.Time) (*WorkerCommand, error) {
	command, err := scanCommand(s.DB.QueryRow(ctx, `WITH next_command AS (SELECT id FROM operations_commands WHERE environment=$1 AND action=$2 AND (status='queued' OR (status='running' AND lease_expires_at<$4)) ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) UPDATE operations_commands AS command SET status='running',claimed_by=$3,lease_expires_at=$5,updated_at=$4,version=command.version+1 FROM next_command WHERE command.environment=$1 AND command.id=next_command.id RETURNING command.id,command.action,command.status,command.requested_by_did,command.audit_note,command.claimed_by,command.lease_expires_at,command.failure_reason,command.created_at,command.updated_at,command.completed_at,command.version`, s.Environment, action, workerID, at, at.Add(300*time.Second)), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &command, nil
}
func (s *PostgresStore) CompleteCommand(ctx context.Context, id, status string, failure *string, workerID string, version int, requestID, note *string, at time.Time) (WorkerCommand, error) {
	if status != "completed" && status != "failed" {
		return WorkerCommand{}, ErrInvalidTransition
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return WorkerCommand{}, err
	}
	defer tx.Rollback(context.Background())
	var boundedFailure *string
	if failure != nil {
		value := boundedText(*failure, 160)
		boundedFailure = &value
	}
	command, err := scanCommand(tx.QueryRow(ctx, `UPDATE operations_commands SET status=$3,failure_reason=$4,updated_at=$5,completed_at=$5,expires_at=$6,lease_expires_at=NULL,version=version+1 WHERE environment=$1 AND id=$2 AND status='running' AND claimed_by=$7 AND lease_expires_at>=$5 AND version=$8 RETURNING `+commandColumns, s.Environment, id, status, boundedFailure, at, at.Add(365*24*time.Hour), workerID, version), s.Environment)
	if errors.Is(err, pgx.ErrNoRows) {
		return WorkerCommand{}, ErrLeaseConflict
	}
	if err != nil {
		return WorkerCommand{}, err
	}
	local, _ := NewPostgresStore(tx, s.Environment)
	if err = local.extendLifecycleRetention(ctx, "command", id, at); err != nil {
		return WorkerCommand{}, err
	}
	outcome := "succeeded"
	if status == "failed" {
		outcome = "failed"
	}
	afterOutcome := "succeeded"
	if boundedFailure != nil {
		afterOutcome = *boundedFailure
	}
	audit := MutationAudit{OperatorDID: "system:worker", Action: "command." + status, TargetType: "command", TargetID: &id, ExpectedVersion: &version, Note: note, Before: map[string]string{"status": "running", "version": strconv.Itoa(version), "leaseOwner": workerID}, After: map[string]string{"status": status, "version": strconv.Itoa(command.Version), "outcome": afterOutcome}, Outcome: outcome, OccurredAt: at}
	if requestID != nil {
		audit.RequestID = *requestID
	}
	if err = local.RecordAudit(ctx, audit); err != nil {
		return WorkerCommand{}, err
	}
	return command, tx.Commit(ctx)
}
