// Package thinappviewcore provides repository-local ingestion and projection contracts.
package thinappviewcore

// Validates a stored event against its independent cursor/kind/DID metadata before
// decoding with the official Jetstream SDK. Numeric strings remain backward-compatible,
// record integers stay exact, and event-specific payload rules reject malformed commits or
// lifecycle events.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	jetstream "github.com/bluesky-social/jetstream"
)

var (
	ErrInvalidJSON      = errors.New("invalid projection JSON")
	ErrInvalidEnvelope  = errors.New("invalid projection envelope")
	ErrMetadataMismatch = errors.New("projection metadata mismatch")
	ErrInvalidCommit    = errors.New("invalid projection commit")
	ErrInvalidIdentity  = errors.New("invalid projection identity")
	ErrInvalidAccount   = errors.New("invalid projection account")
	ErrInvalidSync      = errors.New("invalid projection sync")
)

// ProjectionEvent is one validated commit, identity, account, or sync event using the
// provider cursor.
type ProjectionEvent struct {
	Kind      string
	DID       string
	Sequence  int64
	EventTime time.Time
	Commit    *ProjectionCommit
	Identity  *ProjectionIdentity
	Account   *ProjectionAccount
	Sync      *ProjectionSync
}

// ProjectionCommit carries create/update/delete identity and raw object JSON; delete
// events may omit record data.
type ProjectionCommit struct {
	Operation, Collection, RKey, RepoRev string
	CID                                  *string
	RecordJSON                           json.RawMessage
}

// ProjectionIdentity carries the optional updated repository handle.
type ProjectionIdentity struct{ Handle *string }

// ProjectionAccount carries activation and normalized lifecycle status for an account.
type ProjectionAccount struct {
	Active bool
	Status string
}

// ProjectionSync carries the repository revision requesting reconciliation.
type ProjectionSync struct{ RepoRev string }

func stringValue(value any) string {
	text, _ := value.(string)
	return strings.TrimSpace(text)
}
func integerValue(value any) (int64, bool) {
	switch typedValue := value.(type) {
	case int64:
		return typedValue, true
	case json.Number:
		count, err := typedValue.Int64()
		return count, err == nil
	case string:
		count, err := strconv.ParseInt(typedValue, 10, 64)
		return count, err == nil
	}
	return 0, false
}
func optionalString(value any) *string {
	if text := stringValue(value); text != "" {
		return &text
	}
	return nil
}
func validDID(value any) string {
	if text := stringValue(value); strings.HasPrefix(text, "did:") {
		return text
	}
	return ""
}
func nestedEventTime(value any) (time.Time, error) {
	return time.Parse(time.RFC3339Nano, stringValue(value))
}

// ParseProjectionEvent checks cursor/kind/DID against stored metadata and returns SDK-
// decoded event fields without applying durable side effects.
func ParseProjectionEvent(data []byte, expectedSequence int64, expectedKind, expectedDID string) (ProjectionEvent, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var object map[string]any
	if err := decoder.Decode(&object); err != nil {
		return ProjectionEvent{}, ErrInvalidJSON
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return ProjectionEvent{}, ErrInvalidJSON
	}
	did, kind := validDID(object["did"]), stringValue(object["kind"])
	sequence, sequenceOK := integerValue(object["cursor"])
	microseconds, timeOK := integerValue(object["time_us"])
	if did == "" || !sequenceOK || sequence < 0 || !timeOK || microseconds < 0 || kind != "commit" && kind != "identity" && kind != "account" && kind != "sync" {
		return ProjectionEvent{}, ErrInvalidEnvelope
	}
	if sequence != expectedSequence || kind != expectedKind || did != expectedDID {
		return ProjectionEvent{}, ErrMetadataMismatch
	}

	// Retain legacy numeric-string envelopes, then decode with the provider SDK.
	// UseNumber keeps record integers exact rather than converting them to float64.
	object["cursor"], object["time_us"] = sequence, microseconds
	object["did"], object["kind"] = did, kind
	nested, _ := object[kind].(map[string]any)
	if kind != "commit" {
		if seq, ok := integerValue(nested["seq"]); ok {
			nested["seq"] = seq
		}
	}
	normalized, err := json.Marshal(object)
	if err != nil {
		return ProjectionEvent{}, ErrInvalidJSON
	}
	sdkDecoder := json.NewDecoder(bytes.NewReader(normalized))
	sdkDecoder.UseNumber()
	var provider jetstream.Event
	if err := sdkDecoder.Decode(&provider); err != nil {
		return ProjectionEvent{}, map[string]error{
			"commit": ErrInvalidCommit, "identity": ErrInvalidIdentity,
			"account": ErrInvalidAccount, "sync": ErrInvalidSync,
		}[kind]
	}
	event := ProjectionEvent{Kind: string(provider.Kind), DID: provider.DID, Sequence: int64(provider.Seq), EventTime: time.UnixMicro(provider.TimeUS).UTC()}
	if kind == "commit" {
		commit := provider.Commit
		if commit == nil || (commit.Operation != jetstream.OpCreate && commit.Operation != jetstream.OpUpdate && commit.Operation != jetstream.OpDelete) ||
			strings.TrimSpace(commit.Collection) == "" || strings.TrimSpace(commit.Rkey) == "" || strings.TrimSpace(commit.Rev) == "" {
			return ProjectionEvent{}, ErrInvalidCommit
		}
		var record json.RawMessage
		if _, present := nested["record"]; present {
			if commit.Record == nil {
				return ProjectionEvent{}, ErrInvalidCommit
			}
			record, err = json.Marshal(commit.Record)
			if err != nil {
				return ProjectionEvent{}, ErrInvalidCommit
			}
		}
		if commit.Operation != jetstream.OpDelete && record == nil {
			return ProjectionEvent{}, ErrInvalidCommit
		}
		event.Commit = &ProjectionCommit{string(commit.Operation), strings.TrimSpace(commit.Collection), strings.TrimSpace(commit.Rkey), strings.TrimSpace(commit.Rev), optionalString(commit.CID), record}
		return event, nil
	}
	nestedSeq, validSeq := integerValue(nested["seq"])
	invalid := map[string]error{"identity": ErrInvalidIdentity, "account": ErrInvalidAccount, "sync": ErrInvalidSync}[kind]
	if validDID(nested["did"]) != did || !validSeq || nestedSeq < 0 {
		return ProjectionEvent{}, invalid
	}
	if kind == "sync" {
		if provider.Sync == nil || strings.TrimSpace(provider.Sync.Rev) == "" {
			return ProjectionEvent{}, ErrInvalidSync
		}
		if provider.Sync.Time != "" {
			at, err := nestedEventTime(provider.Sync.Time)
			if err != nil {
				return ProjectionEvent{}, ErrInvalidSync
			}
			event.EventTime = at
		}
		event.Sync = &ProjectionSync{strings.TrimSpace(provider.Sync.Rev)}
		return event, nil
	}
	at, err := nestedEventTime(nested["time"])
	if err != nil {
		return ProjectionEvent{}, invalid
	}
	event.EventTime = at
	if kind == "identity" {
		if provider.Identity == nil {
			return ProjectionEvent{}, ErrInvalidIdentity
		}
		event.Identity = &ProjectionIdentity{optionalString(provider.Identity.Handle)}
		return event, nil
	}
	if provider.Account == nil {
		return ProjectionEvent{}, ErrInvalidAccount
	}
	if _, ok := nested["active"].(bool); !ok {
		return ProjectionEvent{}, ErrInvalidAccount
	}
	status := "active"
	if !provider.Account.Active {
		status = strings.ToLower(strings.TrimSpace(provider.Account.Status))
		switch status {
		case "active", "takendown", "suspended", "deactivated", "deleted":
		default:
			status = "deactivated"
		}
	}
	event.Account = &ProjectionAccount{provider.Account.Active, status}
	return event, nil
}
