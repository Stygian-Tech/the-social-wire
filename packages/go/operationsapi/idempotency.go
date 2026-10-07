package operationsapi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"sort"
	"strconv"
	"strings"
	"time"
)

func IdempotencyFingerprint(action, targetType string, targetID *string, version *int, fields map[string]*string) string {
	component := func(name, value string) string { return fmt.Sprintf("%d:%s%d:%s", len(name), name, len(value), value) }
	id, expected := "<nil>", "<nil>"
	if targetID != nil {
		id = *targetID
	}
	if version != nil {
		expected = strconv.Itoa(*version)
	}
	var input strings.Builder
	for _, field := range [][2]string{{"action", action}, {"targetType", targetType}, {"targetId", id}, {"expectedVersion", expected}} {
		input.WriteString(component(field[0], field[1]))
	}
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		value := "<nil>"
		if fields[key] != nil {
			value = *fields[key]
		}
		input.WriteString(component(key, value))
	}
	digest := sha256.Sum256([]byte(input.String()))
	return hex.EncodeToString(digest[:])
}
func (s *PostgresStore) existingIdempotency(ctx context.Context, key, action, targetType string, targetID *string, fingerprint string) (json.RawMessage, error) {
	if _, err := s.DB.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1 || '|' || $2,0))`, s.Environment, key); err != nil {
		return nil, err
	}
	var storedAction, storedType, payload string
	var storedID, storedFingerprint *string
	err := s.DB.QueryRow(ctx, `SELECT action,target_type,target_id,request_fingerprint,result_payload::text FROM operations_idempotency_records WHERE environment=$1 AND idempotency_key=$2 LIMIT 1`, s.Environment, key).Scan(&storedAction, &storedType, &storedID, &storedFingerprint, &payload)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if storedAction != action || storedType != targetType || storedID == nil || storedFingerprint == nil || *storedFingerprint != fingerprint || (targetID != nil && *storedID != *targetID) || payload == "" {
		return nil, ErrIdempotencyConflict
	}
	return json.RawMessage(payload), nil
}
func (s *PostgresStore) insertIdempotency(ctx context.Context, key, action, targetType, targetID, outcome, fingerprint string, result any, at time.Time) error {
	payload, err := marshalStored(result)
	if err != nil {
		return err
	}
	_, err = s.DB.Exec(ctx, `INSERT INTO operations_idempotency_records(environment,idempotency_key,action,target_type,target_id,outcome,request_fingerprint,result_payload,created_at,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9,$10)`, s.Environment, key, boundedText(action, 128), boundedText(targetType, 64), targetID, outcome, fingerprint, string(payload), at, at.Add(365*24*time.Hour))
	return err
}
func (s *PostgresStore) extendLifecycleRetention(ctx context.Context, targetType, targetID string, at time.Time) error {
	for _, table := range []string{"operations_audit_events", "operations_idempotency_records"} {
		if _, err := s.DB.Exec(ctx, `UPDATE `+table+` SET expires_at=$4 WHERE environment=$1 AND target_type=$2 AND target_id=$3`, s.Environment, targetType, targetID, at.Add(365*24*time.Hour)); err != nil {
			return err
		}
	}
	return nil
}
