package store

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

// Bound both bind parameters and payload copies. Oversize individual records still
// stage alone under the existing per-event safety limit, in the same transaction.
const inboxInsertMaxRows = 500
const inboxInsertMaxPayloadBytes = 4 << 20

func inboxBatchEnd(events []ingest.InboxEvent, start int) int {
	end, payloadBytes := start, 0
	for end < len(events) && end-start < inboxInsertMaxRows {
		size := len(events[end].Payload)
		if end > start && payloadBytes+size > inboxInsertMaxPayloadBytes {
			break
		}
		payloadBytes += size
		end++
	}
	return end
}

func (p *Postgres) stageInboxEvents(ctx context.Context, tx *sql.Tx, events []ingest.InboxEvent) (int64, error) {
	if len(events) == 0 {
		return 0, nil
	}
	values := make([]string, 0, len(events))
	args := make([]any, 0, len(events)*14)
	for _, event := range events {
		payload := event.Payload
		if p.source.IsWire() {
			payload = wireJSONPayloadForPostgres(payload)
		}
		start := len(args) + 1
		values = append(values, fmt.Sprintf(
			"($%d::text,$%d::text,$%d::bigint,$%d::text,$%d::text,$%d::text,$%d::text,$%d::text,$%d::text,$%d::text,$%d::text,$%d::text,$%d::jsonb,$%d::timestamptz)",
			start, start+1, start+2, start+3, start+4, start+5, start+6,
			start+7, start+8, start+9, start+10, start+11, start+12, start+13))
		args = append(args, p.source.Environment, p.source.Generation, int64(event.Seq), p.source.Host,
			p.source.CursorKind, event.Kind, event.RepoDID, event.Collection, event.Operation,
			event.RepoRev, event.RecordKey, event.RecordCID, string(payload), event.Time)
	}
	columns := `environment, source_generation, seq, source_host, cursor_kind,
		event_kind, repo_did, collection, operation, repo_rev, record_key,
		record_cid, payload, event_time`
	table, extraColumns, extraValues := "appview_ingestion_inbox", "", ""
	filter := `incoming.collection IS NULL
		OR (incoming.collection IN ('site.standard.document', 'site.standard.entry',
		  'com.standard.document', 'com.standard.entry')
		  AND EXISTS (SELECT 1 FROM appview_publication_scopes scope WHERE scope.author_did = incoming.repo_did))
		OR (incoming.collection IN ('app.skyreader.feed.subscription', 'site.standard.graph.subscription')
		  AND (EXISTS (SELECT 1 FROM appview_viewer_feeds feed WHERE feed.viewer_did = incoming.repo_did)
		    OR EXISTS (SELECT 1 FROM appview_publication_scopes scope WHERE scope.viewer_did = incoming.repo_did)))`
	if p.source.IsWire() {
		table = "wire_ingestion_inbox"
		extraColumns = ", updated_at, expires_at"
		extraValues = ", NOW(), 'infinity'::timestamptz"
		filter = `COALESCE(NOT (
		  incoming.collection IN ('app.bsky.feed.like', 'app.bsky.feed.repost')
		  AND incoming.operation IN ('create', 'update')), TRUE)
		OR EXISTS (SELECT 1 FROM wire_item_aliases alias
		  WHERE alias.alias_key = incoming.payload #>> '{commit,record,subject,uri}'
		    AND alias.expires_at > NOW())`
	}
	// All identifiers above are compile-time constants. Only bind parameters carry events.
	query := "INSERT INTO " + table + " (" + columns + ", status, attempt_count, next_attempt_at, staged_at" + extraColumns + ") " +
		"SELECT incoming.*, 'pending', 0, NOW(), NOW()" + extraValues +
		" FROM (VALUES " + strings.Join(values, ",") + ") AS incoming(" + columns + ") WHERE " + filter +
		" ON CONFLICT (environment, source_generation, seq) DO NOTHING"
	result, err := tx.ExecContext(ctx, query, args...)
	if err != nil {
		return 0, fmt.Errorf("insert inbox batch starting at %d: %w", events[0].Seq, err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("inspect inbox batch starting at %d: %w", events[0].Seq, err)
	}
	return rows, nil
}
