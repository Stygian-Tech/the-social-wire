package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

const wireSubjectLookupBatchSize = 500

func wireSubjectBatchEnd(subjects []json.RawMessage, start int) int {
	end, bytes := start, 0
	for end < len(subjects) && end-start < wireSubjectLookupBatchSize {
		size := len(subjects[end])
		if end > start && bytes+size > inboxInsertMaxPayloadBytes {
			break
		}
		bytes += size
		end++
	}
	return end
}

// Normalize the complete envelope first so invalid discarded fields cannot hide
// normalization failures. Keep the envelope identity and the original subject
// shape; downstream malformed-record handling must not change during compaction.
func compactWirePayload(event ingest.InboxEvent) []byte {
	payload := wireJSONPayloadForPostgres(event.Payload)
	if event.Collection == nil || event.Operation == nil {
		return payload
	}
	signal := *event.Collection == "app.bsky.feed.like" || *event.Collection == "app.bsky.feed.repost" || *event.Collection == "app.bsky.graph.follow"
	// Publication, post, recommendation and account envelopes remain intact.
	if !signal {
		return payload
	}
	var document map[string]json.RawMessage
	if json.Unmarshal(payload, &document) != nil {
		return payload
	}
	var commit map[string]json.RawMessage
	if json.Unmarshal(document["commit"], &commit) != nil || commit == nil {
		return payload
	}
	if *event.Operation == "delete" {
		delete(commit, "record")
		delete(commit, "record_cbor")
	} else {
		var record map[string]json.RawMessage
		if json.Unmarshal(commit["record"], &record) != nil || record == nil {
			return payload
		}
		compact := make(map[string]json.RawMessage, 3)
		for _, key := range []string{"$type", "subject", "createdAt"} {
			if value, ok := record[key]; ok {
				compact[key] = value
			}
		}
		commit["record"], _ = json.Marshal(compact)
		delete(commit, "record_cbor")
	}
	document["commit"], _ = json.Marshal(commit)
	compact, err := json.Marshal(document)
	if err != nil {
		return payload
	}
	return compact
}

func passiveWireSignal(event ingest.InboxEvent) bool {
	return event.Collection != nil && event.Operation != nil &&
		(*event.Collection == "app.bsky.feed.like" || *event.Collection == "app.bsky.feed.repost") &&
		(*event.Operation == "create" || *event.Operation == "update")
}

func wireSubjectValue(payload []byte) json.RawMessage {
	var value json.RawMessage = payload
	for _, key := range []string{"commit", "record", "subject", "uri"} {
		var object map[string]json.RawMessage
		if json.Unmarshal(value, &object) != nil {
			return nil
		}
		value = object[key]
		if len(value) == 0 {
			return nil
		}
	}
	if string(value) == "null" {
		return nil
	}
	// Canonicalize only the lookup key, never the payload. Equivalent escaped
	// strings must share one membership query; malformed scalars retain #>> semantics.
	var uri string
	if json.Unmarshal(value, &uri) == nil {
		canonical, _ := json.Marshal(uri)
		return canonical
	}
	return value
}

// Only compact subject values cross this read boundary, never full event payloads.
// Let PostgreSQL apply its #>> scalar/text semantics to malformed URI values too:
// silently coercing a string subject into a strongRef would change admission.
func filterWireSignals(ctx context.Context, tx *sql.Tx, events []ingest.InboxEvent) ([]ingest.InboxEvent, error) {
	return filterWireSignalsWithMetrics(ctx, tx, events, nil)
}

func filterWireSignalsWithMetrics(ctx context.Context, tx *sql.Tx, events []ingest.InboxEvent, metrics *wireCommittedMetrics) ([]ingest.InboxEvent, error) {
	subjects := make([]json.RawMessage, 0)
	indices := make(map[string]int)
	for _, event := range events {
		if !passiveWireSignal(event) {
			continue
		}
		subject := wireSubjectValue(event.Payload)
		if len(subject) == 0 {
			continue
		}
		key := string(subject)
		if _, exists := indices[key]; !exists {
			indices[key] = len(subjects)
			subjects = append(subjects, subject)
		}
	}
	admitted := make(map[string]bool, len(subjects))
	for start := 0; start < len(subjects); {
		end := wireSubjectBatchEnd(subjects, start)
		keys, err := json.Marshal(subjects[start:end])
		if err != nil {
			return nil, fmt.Errorf("encode Wire subject keys: %w", err)
		}
		if metrics != nil {
			metrics.lookupSubjects += uint64(end - start)
			metrics.lookupBytes += uint64(len(keys))
		}
		rows, err := tx.QueryContext(ctx, `
   SELECT requested.ordinality
   FROM jsonb_array_elements($1::jsonb) WITH ORDINALITY AS requested(subject, ordinality)
   WHERE EXISTS (SELECT 1 FROM wire_item_aliases alias
     WHERE alias.alias_key = requested.subject #>> '{}' AND alias.expires_at > NOW())`, string(keys))
		if err != nil {
			return nil, fmt.Errorf("lookup Wire subject keys: %w", err)
		}
		for rows.Next() {
			var ordinal int
			if err := rows.Scan(&ordinal); err != nil {
				rows.Close()
				return nil, fmt.Errorf("read Wire subject key: %w", err)
			}
			admitted[string(subjects[start+ordinal-1])] = true
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, fmt.Errorf("read Wire subject keys: %w", err)
		}
		start = end
	}
	result := make([]ingest.InboxEvent, 0, len(events))
	for _, event := range events {
		if !passiveWireSignal(event) || admitted[string(wireSubjectValue(event.Payload))] {
			result = append(result, event)
		}
	}
	if metrics != nil {
		metrics.acceptedEvents = uint64(len(result))
		metrics.filteredPassiveEvents = uint64(len(events) - len(result))
		for _, event := range result {
			metrics.acceptedBytes += uint64(len(event.Payload))
		}
	}
	return result, nil
}
