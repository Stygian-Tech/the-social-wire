package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"time"
)

type PublicationSignalRecovery struct {
	DB     *sql.DB
	Hasher *wirecore.ActorHasher
	Scope  InboxScope
}

func (s PublicationSignalRecovery) RunBatch(ctx context.Context, at time.Time, limit int) (int, error) {
	data, _ := json.Marshal(s.Scope.Generations)
	generations := string(data)
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	_, err = tx.ExecContext(ctx, `UPDATE wire_publication_signal_recovery_jobs job SET replay_completed_at=$1 FROM appview_jetstream_checkpoints checkpoint,wire_ingestion_inbox_epochs epoch WHERE job.environment=$2 AND job.source_generation IN(SELECT jsonb_array_elements_text($3::jsonb)) AND job.completed_at IS NOT NULL AND job.replay_completed_at IS NULL AND checkpoint.environment=job.environment AND checkpoint.source_generation=job.source_generation AND checkpoint.replay_state='live' AND checkpoint.last_staged_seq>=checkpoint.replay_sealed_seq AND epoch.environment=job.environment AND epoch.source_generation=job.source_generation AND epoch.initialized_at=job.inbox_initialized_at AND NOT EXISTS(SELECT 1 FROM wire_ingestion_inbox inbox WHERE inbox.environment=job.environment AND inbox.source_generation=job.source_generation AND inbox.status IN('pending','leased','retry','deferred','dead_letter'))`, at, s.Scope.Environment, generations)
	if err != nil {
		return 0, err
	}
	var generation, afterURI string
	var initialized, afterTime time.Time
	var maximum int64
	err = tx.QueryRowContext(ctx, `SELECT job.source_generation,job.inbox_initialized_at,job.maximum_source_seq,job.after_event_time,job.after_source_uri FROM wire_publication_signal_recovery_jobs job JOIN wire_ingestion_inbox_epochs epoch ON epoch.environment=job.environment AND epoch.source_generation=job.source_generation AND epoch.initialized_at=job.inbox_initialized_at WHERE job.environment=$1 AND job.source_generation IN(SELECT jsonb_array_elements_text($2::jsonb)) AND job.completed_at IS NULL ORDER BY job.inbox_initialized_at LIMIT 1 FOR UPDATE OF job SKIP LOCKED`, s.Scope.Environment, generations).Scan(&generation, &initialized, &maximum, &afterTime, &afterURI)
	if err == sql.ErrNoRows {
		return 0, tx.Commit()
	}
	if err != nil {
		return 0, err
	}
	cutoff := at.Add(-wirecore.SignalRetention)
	rows, err := tx.QueryContext(ctx, `SELECT event_time,source_uri FROM wire_standard_record_fences WHERE environment=$1 AND source_generation=$2 AND activity_recorded AND operation<>'delete' AND event_time>$3 AND updated_at<$4 AND seq<=$5 AND event_kind='commit' AND(event_time,source_uri)>($6,$7) ORDER BY event_time,source_uri LIMIT $8`, s.Scope.Environment, generation, cutoff, initialized, maximum, afterTime, afterURI, max(1, min(limit, 500)))
	if err != nil {
		return 0, err
	}
	type entry struct {
		at  time.Time
		uri string
	}
	page := []entry{}
	for rows.Next() {
		var row entry
		if err = rows.Scan(&row.at, &row.uri); err != nil {
			rows.Close()
			return 0, err
		}
		page = append(page, row)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	for _, row := range page {
		parts := strings.Split(strings.TrimPrefix(row.uri, "at://"), "/")
		if len(parts) != 3 || !strings.HasPrefix(row.uri, "at://") || (parts[1] != "site.standard.document" && parts[1] != "site.standard.entry") {
			continue
		}
		repo := parts[0]
		if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "wire-recommendation-account:"+s.Scope.Environment+":"+repo); err != nil {
			return 0, err
		}
		if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, row.uri); err != nil {
			return 0, err
		}
		var seq int64
		var host, cursor, key string
		var eventTime time.Time
		err = tx.QueryRowContext(ctx, `SELECT fence.seq,fence.source_host,fence.cursor_kind,fence.event_time,alias.canonical_key FROM wire_standard_record_fences fence JOIN appview_jetstream_checkpoints checkpoint ON checkpoint.environment=fence.environment AND checkpoint.source_generation=fence.source_generation AND checkpoint.source_host=fence.source_host AND checkpoint.cursor_kind=fence.cursor_kind JOIN wire_item_aliases alias ON alias.alias_key=fence.source_uri AND alias.expires_at>$1 JOIN wire_items item ON item.canonical_key=alias.canonical_key AND item.expires_at>$1 WHERE fence.environment=$2 AND fence.source_generation=$3 AND fence.source_uri=$4 AND fence.seq<=$5 AND fence.updated_at<$6 AND fence.event_kind='commit' AND fence.activity_recorded AND fence.operation<>'delete' AND fence.event_time>$7 AND fence.event_time<=$1 AND NOT EXISTS(SELECT 1 FROM wire_recommendation_account_fences account WHERE account.environment=fence.environment AND account.repo_did=$8 AND(NOT account.active OR account.inactive_through>=fence.event_time))`, at, s.Scope.Environment, generation, row.uri, maximum, initialized, cutoff, repo).Scan(&seq, &host, &cursor, &eventTime, &key)
		if err == sql.ErrNoRows {
			continue
		}
		if err != nil {
			return 0, err
		}
		actor, err := s.Hasher.Hash(repo)
		if err != nil {
			return 0, err
		}
		if _, err = tx.ExecContext(ctx, `SELECT ensure_wire_signal_event_partition(($1::timestamptz AT TIME ZONE 'UTC')::date)`, eventTime); err != nil {
			return 0, err
		}
		event := InboxEvent{Repository: InboxRepository{Environment: s.Scope.Environment, SourceGeneration: generation}, Sequence: seq, SourceHost: host, CursorKind: cursor, EventTime: eventTime}
		eventKey := fmt.Sprintf("%s:%s:%d", event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence)
		transport := fmt.Sprintf("transport:%s:%s:%s:%d", event.Repository.Environment, event.SourceHost, event.CursorKind, event.Sequence)
		if _, err = tx.ExecContext(ctx, `INSERT INTO wire_signal_events(event_key,transport_event_key,canonical_key,signal_kind,actor_key_hash,source_uri,source_collection,source_action,occurred_at,expires_at) SELECT $1,$2,$3,'publication',$4,$5,$6,'publication',$7,$8 WHERE NOT EXISTS(SELECT 1 FROM wire_signal_events WHERE source_uri=$5) ON CONFLICT DO NOTHING`, eventKey, transport, key, actor, row.uri, parts[1], eventTime, eventTime.Add(wirecore.SignalRetention)); err != nil {
			return 0, err
		}
	}
	if len(page) > 0 {
		last := page[len(page)-1]
		_, err = tx.ExecContext(ctx, `UPDATE wire_publication_signal_recovery_jobs SET after_event_time=$1,after_source_uri=$2 WHERE environment=$3 AND source_generation=$4 AND inbox_initialized_at=$5`, last.at, last.uri, s.Scope.Environment, generation, initialized)
	} else {
		_, err = tx.ExecContext(ctx, `UPDATE wire_publication_signal_recovery_jobs SET completed_at=$1 WHERE environment=$2 AND source_generation=$3 AND inbox_initialized_at=$4`, at, s.Scope.Environment, generation, initialized)
	}
	if err != nil {
		return 0, err
	}
	if err = tx.Commit(); err != nil {
		return 0, err
	}
	return len(page), nil
}
