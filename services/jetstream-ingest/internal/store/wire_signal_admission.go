package store

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"unicode/utf8"

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
	payload, _ := compactWirePayloadWithSubject(event)
	return payload
}

// Prepare the immutable lookup key from the same decoded document as the
// compact envelope. Only membership results depend on the transaction snapshot.
func compactWirePayloadWithSubject(event ingest.InboxEvent) ([]byte, json.RawMessage) {
	payload := wireJSONPayloadForPostgres(event.Payload)
	if event.Collection == nil || event.Operation == nil {
		return payload, nil
	}
	signal := *event.Collection == "app.bsky.feed.like" || *event.Collection == "app.bsky.feed.repost" || *event.Collection == "app.bsky.graph.follow"
	// Publication, post, recommendation and account envelopes remain intact.
	if !signal {
		return payload, nil
	}
	// Decoding strings through any replaces invalid UTF-8. Keep the former
	// RawMessage path for malformed input so retained fields still reach the
	// database unchanged, including errors PostgreSQL would have rejected.
	if !utf8.Valid(payload) {
		compact := compactWireRawPayload(payload, *event.Operation)
		if passiveWireSignal(event) {
			return compact, wireSubjectValue(compact)
		}
		return compact, nil
	}
	document, ok := decodeWireJSONDocument(payload).(map[string]any)
	if !ok {
		return payload, nil
	}
	var subject json.RawMessage
	if passiveWireSignal(event) {
		subject = wireSubjectFromDocument(document)
	}
	commit, ok := document["commit"].(map[string]any)
	if !ok || commit == nil {
		return payload, subject
	}
	if *event.Operation == "delete" {
		_, hasRecord := commit["record"]
		_, hasCBOR := commit["record_cbor"]
		if !hasRecord && !hasCBOR {
			return payload, subject
		}
		delete(commit, "record")
		delete(commit, "record_cbor")
	} else {
		record, ok := commit["record"].(map[string]any)
		if !ok || record == nil {
			return payload, subject
		}
		// Ordinary signal records already contain only these three fields. Keep
		// their normalized bytes instead of decoding and re-encoding the envelope.
		_, hasCBOR := commit["record_cbor"]
		unchanged := !hasCBOR
		for key := range record {
			if key != "$type" && key != "subject" && key != "createdAt" {
				unchanged = false
				break
			}
		}
		if unchanged {
			return payload, subject
		}
		compact := make(map[string]any, 3)
		for _, key := range []string{"$type", "subject", "createdAt"} {
			if value, ok := record[key]; ok {
				compact[key] = value
			}
		}
		// Preserve the subject's original JSON representation as well as its
		// shape. Only records that actually lose fields need this extra scan.
		if _, exists := compact["subject"]; exists {
			compact["subject"] = wireRawRecordSubject(payload)
		}
		commit["record"] = compact
		delete(commit, "record_cbor")
	}
	document["commit"] = commit
	compact, err := json.Marshal(document)
	if err != nil {
		return payload, subject
	}
	return compact, subject
}

func wireRawRecordSubject(payload []byte) json.RawMessage {
	return wireRawPathValue(payload, "commit", "record", "subject")
}

func wireRawPathValue(payload []byte, keys ...string) json.RawMessage {
	value := json.RawMessage(payload)
	for _, key := range keys {
		var object map[string]json.RawMessage
		if json.Unmarshal(value, &object) != nil {
			return nil
		}
		value = object[key]
	}
	return value
}

func compactWireRawPayload(payload []byte, operation string) []byte {
	var document, commit map[string]json.RawMessage
	if json.Unmarshal(payload, &document) != nil ||
		json.Unmarshal(document["commit"], &commit) != nil || commit == nil {
		return payload
	}
	if operation == "delete" {
		delete(commit, "record")
		delete(commit, "record_cbor")
	} else {
		var record map[string]json.RawMessage
		if json.Unmarshal(commit["record"], &record) != nil || record == nil {
			return payload
		}
		compact := make(map[string]json.RawMessage, 3)
		for _, key := range []string{"$type", "subject", "createdAt"} {
			if value, exists := record[key]; exists {
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

func decodeWireJSONDocument(payload []byte) any {
	// Decode once instead of repeatedly scanning and copying each enclosing
	// object. UseNumber preserves malformed numeric URI semantics in PostgreSQL.
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	var value any
	if decoder.Decode(&value) != nil {
		return nil
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil
	}
	return value
}

func wireSubjectValue(payload []byte) json.RawMessage {
	if !utf8.Valid(payload) {
		value := wireRawPathValue(payload, "commit", "record", "subject", "uri")
		if string(value) == "null" {
			return nil
		}
		var uri string
		if json.Unmarshal(value, &uri) == nil {
			canonical, _ := json.Marshal(uri)
			return canonical
		}
		return value
	}
	return wireSubjectFromDocument(decodeWireJSONDocument(payload))
}

func wireSubjectFromDocument(value any) json.RawMessage {
	for _, key := range []string{"commit", "record", "subject", "uri"} {
		object, ok := value.(map[string]any)
		if !ok {
			return nil
		}
		value = object[key]
		if value == nil {
			return nil
		}
	}
	// Canonicalize only the lookup key, never the payload. Equivalent escaped
	// strings must share one membership query; malformed scalars retain #>> semantics.
	canonical, _ := json.Marshal(value)
	return canonical
}

type wireSignalSubjects struct {
	distinct  []json.RawMessage
	eventKeys []string
	indices   map[string]struct{}
}

func newWireSignalSubjects(eventCount int) wireSignalSubjects {
	return wireSignalSubjects{eventKeys: make([]string, eventCount), indices: make(map[string]struct{})}
}

func (subjects *wireSignalSubjects) add(eventIndex int, value json.RawMessage) {
	if len(value) == 0 {
		return
	}
	key := string(value)
	subjects.eventKeys[eventIndex] = key
	if _, exists := subjects.indices[key]; !exists {
		subjects.indices[key] = struct{}{}
		subjects.distinct = append(subjects.distinct, value)
	}
}

// Only compact subject values cross this read boundary, never full event payloads.
// Let PostgreSQL apply its #>> scalar/text semantics to malformed URI values too:
// silently coercing a string subject into a strongRef would change admission.
func filterWireSignals(ctx context.Context, tx *sql.Tx, events []ingest.InboxEvent) ([]ingest.InboxEvent, error) {
	return filterWireSignalsWithMetrics(ctx, tx, events, nil)
}

func filterWireSignalsWithMetrics(ctx context.Context, tx *sql.Tx, events []ingest.InboxEvent, metrics *wireCommittedMetrics) ([]ingest.InboxEvent, error) {
	prepared := newWireSignalSubjects(len(events))
	for i, event := range events {
		if passiveWireSignal(event) {
			prepared.add(i, wireSubjectValue(event.Payload))
		}
	}
	return filterPreparedWireSignals(ctx, tx, events, prepared, metrics)
}

func filterPreparedWireSignals(ctx context.Context, tx *sql.Tx, events []ingest.InboxEvent, prepared wireSignalSubjects, metrics *wireCommittedMetrics) ([]ingest.InboxEvent, error) {
	subjects := prepared.distinct
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
	for i, event := range events {
		if !passiveWireSignal(event) || admitted[prepared.eventKeys[i]] {
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
