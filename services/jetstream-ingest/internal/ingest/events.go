package ingest

import (
	"encoding/json"
	"fmt"
	"math"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
)

const MaxEventPayloadBytes = 32 << 20

type InboxEvent struct {
	Seq        uint64
	Time       time.Time
	Kind       string
	RepoDID    string
	Collection *string
	Operation  *string
	RepoRev    *string
	RecordKey  *string
	RecordCID  *string
	Payload    []byte
}

func PrepareBatch(events []jetstream.Event, trackedDIDs map[string]struct{}) ([]InboxEvent, uint64, time.Time, error) {
	return PrepareBatchForPipeline(events, trackedDIDs, false)
}

// PrepareBatchForPipeline preserves all account and identity lifecycle events for the global Wire
// lane. The scoped publication lane continues to retain lifecycle events only for tracked DIDs.
func PrepareBatchForPipeline(events []jetstream.Event, trackedDIDs map[string]struct{}, includeAllLifecycle bool) ([]InboxEvent, uint64, time.Time, error) {
	prepared := make([]InboxEvent, 0, len(events))
	var lastSeq uint64
	var lastEventTime time.Time
	for index := range events {
		event := events[index]
		if err := validateEvent(event); err != nil {
			return nil, 0, time.Time{}, fmt.Errorf("event %d: %w", index, err)
		}
		if event.Seq > lastSeq {
			lastSeq = event.Seq
			lastEventTime = time.UnixMicro(event.TimeUS).UTC()
		}

		if event.Kind != jetstream.KindCommit && !includeAllLifecycle {
			if _, tracked := trackedDIDs[event.DID]; !tracked {
				continue
			}
		}

		payloadEvent := event
		if event.Commit != nil {
			commit := *event.Commit
			// The default SDK already supplies the projectable Record map. Do not
			// retain a second base64 copy of the same record in the durable JSON inbox.
			commit.RecordCBOR = nil
			payloadEvent.Commit = &commit
		}
		payload, err := json.Marshal(payloadEvent)
		if err != nil {
			return nil, 0, time.Time{}, fmt.Errorf("marshal seq %d: %w", event.Seq, err)
		}
		if len(payload) > MaxEventPayloadBytes {
			return nil, 0, time.Time{}, fmt.Errorf("seq %d payload exceeds 32 MiB safety limit", event.Seq)
		}
		row := InboxEvent{
			Seq: event.Seq, Time: time.UnixMicro(event.TimeUS).UTC(), Kind: string(event.Kind),
			RepoDID: event.DID, Payload: payload,
		}
		switch event.Kind {
		case jetstream.KindCommit:
			collection := event.Commit.Collection
			operation := string(event.Commit.Operation)
			rev := event.Commit.Rev
			rkey := event.Commit.Rkey
			row.Collection = &collection
			row.Operation = &operation
			row.RepoRev = &rev
			row.RecordKey = &rkey
			if event.Commit.CID != "" {
				cid := event.Commit.CID
				row.RecordCID = &cid
			}
		case jetstream.KindSync:
			rev := event.Sync.Rev
			row.RepoRev = &rev
		}
		prepared = append(prepared, row)
	}
	return prepared, lastSeq, lastEventTime, nil
}

func validateEvent(event jetstream.Event) error {
	if event.Seq == 0 || event.Seq > math.MaxInt64 {
		return fmt.Errorf("cursor %d is outside PostgreSQL BIGINT range", event.Seq)
	}
	if event.DID == "" {
		return fmt.Errorf("cursor %d has no DID", event.Seq)
	}
	payloads := 0
	if event.Commit != nil {
		payloads++
	}
	if event.Identity != nil {
		payloads++
	}
	if event.Account != nil {
		payloads++
	}
	if event.Sync != nil {
		payloads++
	}
	if payloads != 1 {
		return fmt.Errorf("cursor %d must contain exactly one event payload", event.Seq)
	}
	switch event.Kind {
	case jetstream.KindCommit:
		if event.Commit == nil {
			return fmt.Errorf("commit cursor %d has no commit payload", event.Seq)
		}
		if event.Commit.Collection == "" || event.Commit.Rkey == "" || event.Commit.Rev == "" {
			return fmt.Errorf("commit cursor %d is missing identity fields", event.Seq)
		}
		switch event.Commit.Operation {
		case jetstream.OpCreate, jetstream.OpUpdate:
			if event.Commit.Record == nil {
				return fmt.Errorf("commit cursor %d has no projectable JSON record", event.Seq)
			}
		case jetstream.OpDelete:
		default:
			return fmt.Errorf("commit cursor %d has unsupported operation %q", event.Seq, event.Commit.Operation)
		}
	case jetstream.KindIdentity:
		if event.Identity == nil {
			return fmt.Errorf("identity cursor %d has no identity payload", event.Seq)
		}
	case jetstream.KindAccount:
		if event.Account == nil {
			return fmt.Errorf("account cursor %d has no account payload", event.Seq)
		}
	case jetstream.KindSync:
		if event.Sync == nil || event.Sync.Rev == "" {
			return fmt.Errorf("sync cursor %d has no repository revision", event.Seq)
		}
	default:
		return fmt.Errorf("cursor %d has unsupported kind %q", event.Seq, event.Kind)
	}
	return nil
}
