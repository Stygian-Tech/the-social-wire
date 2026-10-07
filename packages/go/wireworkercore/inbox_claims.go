package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

// PostgresInboxClaims admits repository heads without scanning every queued row in
// a deep repository. Leased and delayed retry heads remain ordering barriers.
type PostgresInboxClaims struct {
	DB                     *sql.DB
	Scope                  *InboxScope
	BatchSize, Concurrency int
}

const inboxReturnColumns = `inbox.environment,inbox.source_generation,inbox.seq,inbox.source_host,inbox.cursor_kind,inbox.event_kind,inbox.repo_did,inbox.collection,inbox.operation,inbox.record_key,inbox.payload::text,inbox.event_time,inbox.lease_token,inbox.attempt_count`

func scanInboxRows(rows *sql.Rows) ([]InboxEvent, error) {
	defer rows.Close()
	events := []InboxEvent{}
	for rows.Next() {
		var e InboxEvent
		if err := rows.Scan(&e.Repository.Environment, &e.Repository.SourceGeneration, &e.Sequence, &e.SourceHost, &e.CursorKind, &e.EventKind, &e.Repository.RepoDID, &e.Collection, &e.Operation, &e.RecordKey, &e.PayloadJSON, &e.EventTime, &e.LeaseToken, &e.AttemptCount); err != nil {
			return nil, err
		}
		events = append(events, e)
	}
	return events, rows.Err()
}
func (c PostgresInboxClaims) scopeArgs() (any, string) {
	if c.Scope == nil {
		return nil, "[]"
	}
	data, _ := json.Marshal(c.Scope.Generations)
	return c.Scope.Environment, string(data)
}
func (c PostgresInboxClaims) ClaimWork(ctx context.Context, at time.Time, limit int, after *InboxRepository) (InboxWorkBatch, error) {
	available := min(c.BatchSize, c.Concurrency, max(0, limit))
	if available <= 0 {
		return InboxWorkBatch{}, nil
	}
	passive, err := c.ackPassive(ctx, at, c.BatchSize)
	if err != nil {
		return InboxWorkBatch{}, err
	}
	deletes, err := c.claimPassiveDeletes(ctx, at, available)
	if err != nil {
		return InboxWorkBatch{}, err
	}
	remaining := available - len(deletes)
	var heads []InboxEvent
	if remaining > 0 {
		heads, err = c.claimHeads(ctx, at, remaining, after)
		if err != nil {
			return InboxWorkBatch{}, err
		}
		if len(heads) == 0 && after != nil {
			heads, err = c.claimHeads(ctx, at, remaining, nil)
			if err != nil {
				return InboxWorkBatch{}, err
			}
		}
	}
	next := after
	if len(heads) > 0 {
		repo := heads[len(heads)-1].Repository
		next = &repo
	}
	return InboxWorkBatch{append(deletes, heads...), passive, next}, nil
}
func (c PostgresInboxClaims) ClaimNext(ctx context.Context, repo InboxRepository, at time.Time) (*InboxEvent, error) {
	if c.Scope != nil {
		allowed := false
		for _, g := range c.Scope.Generations {
			allowed = allowed || g == repo.SourceGeneration
		}
		if c.Scope.Environment != repo.Environment || !allowed {
			return nil, nil
		}
	}
	token, err := newGenerationID()
	if err != nil {
		return nil, err
	}
	rows, err := c.DB.QueryContext(ctx, `WITH repository_head AS MATERIALIZED(SELECT seq FROM wire_ingestion_inbox WHERE environment=$1 AND source_generation=$2 AND repo_did=$3 AND status IN('pending','leased','retry') ORDER BY seq LIMIT 1),candidate AS(SELECT inbox.environment,inbox.source_generation,inbox.seq FROM wire_ingestion_inbox inbox JOIN repository_head head ON head.seq=inbox.seq WHERE inbox.environment=$1 AND inbox.source_generation=$2 AND inbox.repo_did=$3 AND ((inbox.status IN('pending','retry') AND inbox.next_attempt_at<=$4) OR(inbox.status='leased' AND inbox.lease_expires_at<=$4)) FOR UPDATE OF inbox SKIP LOCKED) UPDATE wire_ingestion_inbox inbox SET status='leased',lease_owner='wire-worker',lease_token=$5,lease_expires_at=$6,attempt_count=attempt_count+1,updated_at=$4 FROM candidate WHERE inbox.environment=candidate.environment AND inbox.source_generation=candidate.source_generation AND inbox.seq=candidate.seq RETURNING `+inboxReturnColumns, repo.Environment, repo.SourceGeneration, repo.RepoDID, at, token, at.Add(120*time.Second))
	if err != nil {
		return nil, err
	}
	events, err := scanInboxRows(rows)
	if err != nil || len(events) == 0 {
		return nil, err
	}
	return &events[0], nil
}
func (c PostgresInboxClaims) claimHeads(ctx context.Context, at time.Time, limit int, after *InboxRepository) ([]InboxEvent, error) {
	token, err := newGenerationID()
	if err != nil {
		return nil, err
	}
	scope, generations := c.scopeArgs()
	var afterEnv, afterGeneration, afterDID any
	if after != nil {
		afterEnv = after.Environment
		afterGeneration = after.SourceGeneration
		afterDID = after.RepoDID
	}
	scan := `SELECT candidate.environment,candidate.source_generation,candidate.repo_did,candidate.seq FROM wire_ingestion_inbox candidate WHERE candidate.status IN('pending','leased','retry') AND ($1::text IS NULL OR candidate.environment=$1 AND candidate.source_generation IN(SELECT jsonb_array_elements_text($2::jsonb)))`
	query := `WITH RECURSIVE repository_heads AS((` + scan + ` AND($3::text IS NULL OR(candidate.environment,candidate.source_generation,candidate.repo_did)>($3,$4,$5)) ORDER BY candidate.environment,candidate.source_generation,candidate.repo_did,candidate.seq LIMIT 1) UNION ALL SELECT successor.* FROM repository_heads previous CROSS JOIN LATERAL(` + scan + ` AND(candidate.environment,candidate.source_generation,candidate.repo_did)>(previous.environment,previous.source_generation,previous.repo_did) ORDER BY candidate.environment,candidate.source_generation,candidate.repo_did,candidate.seq LIMIT 1)successor),candidates AS(SELECT candidate.environment,candidate.source_generation,candidate.seq FROM repository_heads head JOIN wire_ingestion_inbox candidate ON candidate.environment=head.environment AND candidate.source_generation=head.source_generation AND candidate.seq=head.seq WHERE(candidate.status IN('pending','retry') AND candidate.next_attempt_at<=$6) OR(candidate.status='leased' AND candidate.lease_expires_at<=$6) ORDER BY candidate.environment,candidate.source_generation,candidate.repo_did FOR UPDATE OF candidate SKIP LOCKED LIMIT $7),claimed AS(UPDATE wire_ingestion_inbox inbox SET status='leased',lease_owner='wire-worker',lease_token=$8,lease_expires_at=$9,attempt_count=attempt_count+1,updated_at=$6 FROM candidates WHERE inbox.environment=candidates.environment AND inbox.source_generation=candidates.source_generation AND inbox.seq=candidates.seq RETURNING inbox.*) SELECT ` + inboxReturnColumns + ` FROM claimed inbox ORDER BY inbox.environment,inbox.source_generation,inbox.repo_did`
	rows, err := c.DB.QueryContext(ctx, query, scope, generations, afterEnv, afterGeneration, afterDID, at, limit, token, at.Add(120*time.Second))
	if err != nil {
		return nil, err
	}
	return scanInboxRows(rows)
}
func (c PostgresInboxClaims) ackPassive(ctx context.Context, at time.Time, limit int) (int, error) {
	scope, generations := c.scopeArgs()
	rows, err := c.DB.QueryContext(ctx, `WITH candidates AS(SELECT candidate.environment,candidate.source_generation,candidate.seq FROM wire_ingestion_inbox candidate WHERE($1::text IS NULL OR candidate.environment=$1 AND candidate.source_generation IN(SELECT jsonb_array_elements_text($2::jsonb))) AND candidate.status IN('pending','retry') AND candidate.next_attempt_at<=$3 AND candidate.event_kind='commit' AND candidate.collection IN('app.bsky.feed.like','app.bsky.feed.repost') AND candidate.operation IN('create','update') AND NULLIF(BTRIM(COALESCE(candidate.payload#>>'{commit,record,subject,uri}',CASE WHEN jsonb_typeof(candidate.payload#>'{commit,record,subject}')='string' THEN candidate.payload#>>'{commit,record,subject}' END)),'')IS NOT NULL AND NOT EXISTS(SELECT 1 FROM wire_item_aliases alias WHERE alias.alias_key=COALESCE(candidate.payload#>>'{commit,record,subject,uri}',CASE WHEN jsonb_typeof(candidate.payload#>'{commit,record,subject}')='string' THEN candidate.payload#>>'{commit,record,subject}' END) AND alias.expires_at>$3) AND NOT EXISTS(SELECT 1 FROM wire_ingestion_inbox earlier WHERE earlier.environment=candidate.environment AND earlier.source_generation=candidate.source_generation AND earlier.repo_did=candidate.repo_did AND earlier.seq<candidate.seq AND earlier.status IN('pending','leased','retry')) ORDER BY candidate.next_attempt_at,candidate.seq,candidate.environment,candidate.source_generation FOR UPDATE SKIP LOCKED LIMIT $4) UPDATE wire_ingestion_inbox inbox SET status='applied',next_attempt_at=$3,failure_category=NULL,failure_reason=NULL,applied_at=$3,dead_lettered_at=NULL,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,attempt_count=attempt_count+1,expires_at=$5,updated_at=$3 FROM candidates WHERE inbox.environment=candidates.environment AND inbox.source_generation=candidates.source_generation AND inbox.seq=candidates.seq AND inbox.status IN('pending','retry') AND inbox.next_attempt_at<=$3 RETURNING inbox.seq`, scope, generations, at, max(1, min(limit, 5000)), at.Add(300*time.Second))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		count++
	}
	return count, rows.Err()
}
func (c PostgresInboxClaims) claimPassiveDeletes(ctx context.Context, at time.Time, limit int) ([]InboxEvent, error) {
	if c.Scope == nil {
		return nil, nil
	}
	token, err := newGenerationID()
	if err != nil {
		return nil, err
	}
	scope, generations := c.scopeArgs()
	filter := `candidate.environment=$1 AND candidate.source_generation IN(SELECT jsonb_array_elements_text($2::jsonb)) AND candidate.event_kind='commit' AND candidate.collection IN('app.bsky.feed.like','app.bsky.feed.repost') AND candidate.operation='delete' AND candidate.record_key IS NOT NULL AND NOT EXISTS(SELECT 1 FROM wire_ingestion_inbox earlier WHERE earlier.environment=candidate.environment AND earlier.source_generation=candidate.source_generation AND earlier.repo_did=candidate.repo_did AND earlier.seq<candidate.seq AND earlier.status IN('pending','leased','retry') AND(earlier.event_kind<>'commit' OR earlier.collection IS NULL OR earlier.collection NOT IN('app.bsky.feed.like','app.bsky.feed.repost') OR earlier.operation IS DISTINCT FROM 'delete' OR earlier.record_key IS NULL))`
	query := `WITH pending_retry_candidates AS(SELECT candidate.environment,candidate.source_generation,candidate.seq,candidate.next_attempt_at AS eligible_at FROM wire_ingestion_inbox candidate WHERE ` + filter + ` AND candidate.status IN('pending','retry') AND candidate.next_attempt_at<=$3 ORDER BY candidate.next_attempt_at,candidate.seq FOR UPDATE SKIP LOCKED LIMIT $4),expired_lease_candidates AS(SELECT candidate.environment,candidate.source_generation,candidate.seq,candidate.lease_expires_at AS eligible_at FROM wire_ingestion_inbox candidate WHERE ` + filter + ` AND candidate.status='leased' AND candidate.lease_expires_at<=$3 ORDER BY candidate.lease_expires_at,candidate.seq FOR UPDATE SKIP LOCKED LIMIT $4),candidates AS(SELECT * FROM pending_retry_candidates UNION ALL SELECT * FROM expired_lease_candidates ORDER BY eligible_at,seq,environment,source_generation LIMIT $4) UPDATE wire_ingestion_inbox inbox SET status='leased',lease_owner='wire-worker',lease_token=$5,lease_expires_at=$6,attempt_count=attempt_count+1,updated_at=$3 FROM candidates WHERE inbox.environment=candidates.environment AND inbox.source_generation=candidates.source_generation AND inbox.seq=candidates.seq RETURNING ` + inboxReturnColumns
	rows, err := c.DB.QueryContext(ctx, query, scope, generations, at, limit, token, at.Add(120*time.Second))
	if err != nil {
		return nil, err
	}
	events, err := scanInboxRows(rows)
	sort.Slice(events, func(i, j int) bool { return events[i].Sequence < events[j].Sequence })
	return events, err
}

// Finish checks the exact lease token; a recovered claim cannot be acknowledged by
// its previous worker. Call on the projection transaction for atomic apply/ack.
func FinishInbox(ctx context.Context, tx *sql.Tx, event InboxEvent, status string, retryAt time.Time, reason *string, at time.Time) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	var applied, dead any
	expiry := time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC)
	switch status {
	case "applied":
		applied = at
		expiry = at.Add(300 * time.Second)
	case "dead_letter":
		dead = at
		expiry = at.Add(7 * 24 * time.Hour)
	case "retry":
	default:
		return false, fmt.Errorf("invalid inbox completion status")
	}
	result, err := tx.ExecContext(ctx, `UPDATE wire_ingestion_inbox SET status=$1,next_attempt_at=$2,failure_category=$3,failure_reason=$3,applied_at=$4,dead_lettered_at=$5,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,expires_at=$6,updated_at=$7 WHERE environment=$8 AND source_generation=$9 AND seq=$10 AND lease_token=$11 AND status='leased'`, status, retryAt, reason, applied, dead, expiry, at, event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence, event.LeaseToken)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	return n > 0, err
}
