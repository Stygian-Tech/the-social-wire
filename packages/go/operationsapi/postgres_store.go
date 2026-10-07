package operationsapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"strconv"
	"time"
)

type Database interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	Query(context.Context, string, ...any) (pgx.Rows, error)
	QueryRow(context.Context, string, ...any) pgx.Row
	Begin(context.Context) (pgx.Tx, error)
}
type PostgresStore struct {
	DB                Database
	Environment       string
	FingerprintSecret string
}

func NewPostgresStore(db Database, environment string) (*PostgresStore, error) {
	if db == nil || (environment != "dev" && environment != "prod") {
		return nil, errors.New("Operations requires a database and canonical environment")
	}
	return &PostgresStore{DB: db, Environment: environment}, nil
}
func (s *PostgresStore) Ping(ctx context.Context) error {
	var one int
	return s.DB.QueryRow(ctx, "SELECT 1").Scan(&one)
}
func (s *PostgresStore) ChangeEventCursorBounds(ctx context.Context) (ChangeEventCursorBounds, error) {
	bounds := ChangeEventCursorBounds{EarliestAvailable: 1}
	err := s.DB.QueryRow(ctx, "SELECT earliest_available_cursor,latest_cursor FROM operations_change_event_watermarks WHERE environment=$1", s.Environment).Scan(&bounds.EarliestAvailable, &bounds.Latest)
	if errors.Is(err, pgx.ErrNoRows) {
		return ChangeEventCursorBounds{EarliestAvailable: 1}, nil
	}
	return bounds, err
}
func (s *PostgresStore) AppendChangeEvent(ctx context.Context, event ChangeEvent) (ChangeEvent, error) {
	payload, err := json.Marshal(event.Payload)
	if err != nil {
		return ChangeEvent{}, err
	}
	if event.Payload == nil {
		payload = []byte(`{}`)
		event.Payload = map[string]string{}
	}
	event.Environment = s.Environment
	event.EventType = boundedText(event.EventType, 160)
	event.EntityType = boundedText(event.EntityType, 64)
	err = s.DB.QueryRow(ctx, "SELECT operations_append_change_event($1,$2,$3,$4,$5::jsonb,$6)", s.Environment, event.EventType, event.EntityType, event.EntityID, string(payload), event.OccurredAt).Scan(&event.Cursor)
	return event, err
}
func (s *PostgresStore) ListChangeEvents(ctx context.Context, after int64, limit int) ([]ChangeEvent, error) {
	rows, err := s.DB.Query(ctx, `SELECT cursor,event_type,entity_type,entity_id,payload::text,occurred_at FROM operations_change_events WHERE environment=$1 AND cursor>$2 ORDER BY cursor ASC LIMIT $3`, s.Environment, max(0, after), max(1, min(limit, 500)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := []ChangeEvent{}
	for rows.Next() {
		var event ChangeEvent
		var payload string
		event.Environment = s.Environment
		if err = rows.Scan(&event.Cursor, &event.EventType, &event.EntityType, &event.EntityID, &payload, &event.OccurredAt); err != nil {
			return nil, err
		}
		if json.Unmarshal([]byte(payload), &event.Payload) != nil || event.Payload == nil {
			event.Payload = map[string]string{}
		}
		events = append(events, event)
	}
	return events, rows.Err()
}
func randomUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	v := hex.EncodeToString(b[:])
	return v[:8] + "-" + v[8:12] + "-" + v[12:16] + "-" + v[16:20] + "-" + v[20:], nil
}
func (s *PostgresStore) RecordAudit(ctx context.Context, audit MutationAudit) error {
	id, err := randomUUID()
	if err != nil {
		return err
	}
	before := map[string]string{}
	for k, v := range audit.Before {
		before[k] = v
	}
	if audit.ExpectedVersion != nil {
		if _, ok := before["expectedVersion"]; !ok {
			before["expectedVersion"] = strconv.Itoa(*audit.ExpectedVersion)
		}
	}
	beforeJSON, err := json.Marshal(before)
	if err != nil {
		return err
	}
	after := audit.After
	if after == nil {
		after = map[string]string{}
	}
	afterJSON, err := json.Marshal(after)
	if err != nil {
		return err
	}
	var note *string
	if audit.Note != nil {
		v := boundedText(*audit.Note, 280)
		note = &v
	}
	_, err = s.DB.Exec(ctx, `INSERT INTO operations_audit_events (environment,id,operator_did,action,target_type,target_id,idempotency_key,request_id,expected_version,note,before_state,after_state,outcome,occurred_at,expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12::jsonb,$13,$14,$15)`, s.Environment, id, audit.OperatorDID, boundedText(audit.Action, 128), boundedText(audit.TargetType, 64), audit.TargetID, audit.IdempotencyKey, boundedText(audit.RequestID, 128), audit.ExpectedVersion, note, string(beforeJSON), string(afterJSON), boundedText(audit.Outcome, 32), audit.OccurredAt, audit.OccurredAt.Add(365*24*time.Hour))
	return err
}
