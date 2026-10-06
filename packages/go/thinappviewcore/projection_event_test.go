package thinappviewcore

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestProjectionEnvelopeMetadataAndMicroseconds(t *testing.T) {
	data := []byte(`{"did":"did:plc:test","cursor":42,"time_us":1700000000123456,"kind":"commit","commit":{"operation":"create","collection":"site.standard.document","rkey":"entry","rev":"rev","record":{"title":"test"}}}`)
	event, err := ParseProjectionEvent(data, 42, "commit", "did:plc:test")
	if err != nil {
		t.Fatal(err)
	}
	if !event.EventTime.Equal(time.Unix(1700000000, 123456000)) {
		t.Fatal(event.EventTime)
	}
	if _, err := ParseProjectionEvent(data, 41, "commit", "did:plc:test"); !errors.Is(err, ErrMetadataMismatch) {
		t.Fatal(err)
	}
}

func TestSDKProjectionPreservesRecordIntegersAndRejectsNonRecords(t *testing.T) {
	data := []byte(`{"did":"did:plc:test","cursor":9007199254740991,"time_us":1700000000123456,"kind":"commit","commit":{"operation":"create","collection":"site.standard.document","rkey":"entry","rev":"rev","record":{"counter":9007199254740991}}}`)
	event, err := ParseProjectionEvent(data, 9007199254740991, "commit", "did:plc:test")
	if err != nil {
		t.Fatal(err)
	}
	var record map[string]json.RawMessage
	if err := json.Unmarshal(event.Commit.RecordJSON, &record); err != nil || string(record["counter"]) != "9007199254740991" {
		t.Fatal(record, err)
	}
	for _, value := range []string{`null`, `[]`, `"record"`} {
		payload := []byte(`{"did":"did:plc:test","cursor":42,"time_us":1,"kind":"commit","commit":{"operation":"create","collection":"site.standard.document","rkey":"entry","rev":"rev","record":` + value + `}}`)
		if _, err := ParseProjectionEvent(payload, 42, "commit", "did:plc:test"); !errors.Is(err, ErrInvalidCommit) {
			t.Fatal("non-object record accepted", value, err)
		}
	}
}
func TestProjectionDeleteDoesNotRequireRecord(t *testing.T) {
	data := []byte(`{"did":"did:plc:test","cursor":"42","time_us":1,"kind":"commit","commit":{"operation":"delete","collection":"site.standard.document","rkey":"entry","rev":"rev"}}`)
	event, err := ParseProjectionEvent(data, 42, "commit", "did:plc:test")
	if err != nil || event.Commit.RecordJSON != nil {
		t.Fatal(event, err)
	}
}
func TestAccountEventUsesProviderCursor(t *testing.T) {
	data := []byte(`{"did":"did:plc:test","cursor":42,"time_us":1,"kind":"account","account":{"did":"did:plc:test","seq":999,"active":false,"status":"takendown","time":"2026-10-05T12:00:00Z"}}`)
	event, err := ParseProjectionEvent(data, 42, "account", "did:plc:test")
	if err != nil || event.Sequence != 42 || event.Account.Status != "takendown" {
		t.Fatal(event, err)
	}
}
