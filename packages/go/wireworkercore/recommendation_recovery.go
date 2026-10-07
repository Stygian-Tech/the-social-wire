package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type recommendationPosition struct {
	Time                    time.Time
	Environment, Generation string
	Sequence                int64
}
type RecommendationRecoveryCounts struct{ Attempted, Resolved, Conflicted, Superseded, Pending int }

func recommendationScope(scope *InboxScope) (any, string, string) {
	if scope == nil {
		return nil, "[]", "*"
	}
	generations := append([]string{}, scope.Generations...)
	sort.Strings(generations)
	data, _ := json.Marshal(generations)
	return scope.Environment, string(data), scope.Environment + ":" + strings.Join(generations, ",")
}

const journalScopePredicate = `($1::text IS NULL OR environment=$1 AND(jsonb_array_length($2::jsonb)=0 OR source_generation IN(SELECT jsonb_array_elements_text($2::jsonb))))`

func (j *PostgresRecommendationJournal) Recover(ctx context.Context, at time.Time, limit int, scope *InboxScope) (RecommendationRecoveryCounts, error) {
	limit = max(1, min(limit, 100))
	environment, generations, scopeKey := recommendationScope(scope)
	rows, err := j.DB.QueryContext(ctx, `SELECT environment,source_generation,seq FROM wire_recommendation_journal WHERE status='pending' AND next_attempt_at<=$3 AND `+journalScopePredicate+` ORDER BY next_attempt_at,environment,source_generation,seq LIMIT $4`, environment, generations, at, max(1, limit/2))
	if err != nil {
		return RecommendationRecoveryCounts{}, err
	}
	keys := []InboxRepository{}
	sequences := []int64{}
	for rows.Next() {
		var env, gen string
		var seq int64
		if err = rows.Scan(&env, &gen, &seq); err != nil {
			rows.Close()
			return RecommendationRecoveryCounts{}, err
		}
		keys = append(keys, InboxRepository{Environment: env, SourceGeneration: gen})
		sequences = append(sequences, seq)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return RecommendationRecoveryCounts{}, err
	}
	remaining := limit - len(keys)
	if remaining > 0 {
		j.mu.Lock()
		position := j.recoveryPositions[scopeKey]
		j.mu.Unlock()
		var afterTime, afterEnv, afterGen, afterSeq any
		if position != nil {
			afterTime = position.Time
			afterEnv = position.Environment
			afterGen = position.Generation
			afterSeq = position.Sequence
		}
		rows, err = j.DB.QueryContext(ctx, `WITH page AS MATERIALIZED(SELECT environment,source_generation,seq,source_host,cursor_kind,source_uri,event_time FROM wire_recommendation_journal WHERE status='resolved' AND event_time>$3 AND `+journalScopePredicate+` AND($4::timestamptz IS NULL OR(event_time,environment,source_generation,seq)>($4,$5,$6,$7)) ORDER BY event_time,environment,source_generation,seq LIMIT 256) SELECT page.environment,page.source_generation,page.seq,page.event_time,projection.found IS NULL FROM page LEFT JOIN LATERAL(SELECT TRUE AS found FROM wire_signal_events signal WHERE signal.occurred_at=page.event_time AND signal.source_uri=page.source_uri AND signal.transport_event_key='transport:'||page.environment||':'||page.source_host||':'||page.cursor_kind||':'||page.seq::text LIMIT 1 OFFSET 0)projection ON TRUE ORDER BY page.event_time,page.environment,page.source_generation,page.seq`, environment, generations, at.Add(-wirecore.SignalRetention), afterTime, afterEnv, afterGen, afterSeq)
		if err != nil {
			return RecommendationRecoveryCounts{}, err
		}
		var last *recommendationPosition
		found := 0
		for rows.Next() {
			if found >= remaining {
				break
			}
			var env, gen string
			var seq int64
			var eventTime time.Time
			var missing bool
			if err = rows.Scan(&env, &gen, &seq, &eventTime, &missing); err != nil {
				rows.Close()
				return RecommendationRecoveryCounts{}, err
			}
			last = &recommendationPosition{eventTime, env, gen, seq}
			if missing {
				keys = append(keys, InboxRepository{Environment: env, SourceGeneration: gen})
				sequences = append(sequences, seq)
				found++
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return RecommendationRecoveryCounts{}, err
		}
		j.mu.Lock()
		if j.recoveryPositions == nil {
			j.recoveryPositions = map[string]*recommendationPosition{}
		}
		j.recoveryPositions[scopeKey] = last
		j.mu.Unlock()
	}
	counts := RecommendationRecoveryCounts{}
	for index, key := range keys {
		if err := ctx.Err(); err != nil {
			return counts, err
		}
		status, err := j.recoverEntry(ctx, key.Environment, key.SourceGeneration, sequences[index], at)
		if err != nil {
			return counts, err
		}
		if status == "" {
			continue
		}
		counts.Attempted++
		switch status {
		case "resolved", "deleted":
			counts.Resolved++
		case "conflict":
			counts.Conflicted++
		case "superseded", "expired":
			counts.Superseded++
		default:
			counts.Pending++
		}
	}
	return counts, nil
}
func (j *PostgresRecommendationJournal) recoverEntry(ctx context.Context, environment, generation string, sequence int64, at time.Time) (string, error) {
	tx, err := j.DB.BeginTx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	entry, err := readRecommendation(ctx, tx, environment, generation, sequence)
	if err != nil || entry == nil {
		return "", err
	}
	if err = lockRecommendationRecord(ctx, tx, environment, entry.Repo, entry.URI, true); err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	entry, err = readRecommendation(ctx, tx, environment, generation, sequence)
	if err != nil || entry == nil {
		return "", err
	}
	if entry.Status != "pending" && entry.Status != "resolved" {
		return "", nil
	}
	var ready bool
	err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_recommendation_journal journal WHERE environment=$1 AND source_generation=$2 AND seq=$3 AND((status='pending' AND next_attempt_at<=$4) OR(status='resolved' AND event_time>$5 AND NOT EXISTS(SELECT 1 FROM wire_signal_events WHERE occurred_at=$6 AND source_uri=journal.source_uri AND transport_event_key=$7))))`, environment, generation, sequence, at, at.Add(-wirecore.SignalRetention), entry.Time, entry.transportKey()).Scan(&ready)
	if err != nil || !ready {
		return "", err
	}
	status, err := j.reconcile(ctx, tx, *entry, at)
	if err != nil {
		return "", err
	}
	if err = tx.Commit(); err != nil {
		return "", err
	}
	return status, nil
}

type RecommendationBacklog struct {
	PendingCount, ConflictCount, CountLimit int
	OldestPendingAge, OldestConflictAge     time.Duration
}

func (j *PostgresRecommendationJournal) Backlog(ctx context.Context, at time.Time, scope *InboxScope) (RecommendationBacklog, error) {
	result := RecommendationBacklog{CountLimit: 1000}
	environment, generations, _ := recommendationScope(scope)
	for _, status := range []string{"pending", "conflict"} {
		var count int
		var oldest sql.NullTime
		err := j.DB.QueryRowContext(ctx, `SELECT count(*)::bigint,min(event_time) FROM(SELECT event_time FROM wire_recommendation_journal WHERE status='`+status+`' AND `+journalScopePredicate+` ORDER BY event_time,environment,source_generation,seq LIMIT 1000)bounded`, environment, generations).Scan(&count, &oldest)
		if err != nil {
			return result, err
		}
		age := time.Duration(0)
		if oldest.Valid {
			age = max(time.Duration(0), at.Sub(oldest.Time))
		}
		if status == "pending" {
			result.PendingCount = count
			result.OldestPendingAge = age
		} else {
			result.ConflictCount = count
			result.OldestConflictAge = age
		}
	}
	return result, nil
}
