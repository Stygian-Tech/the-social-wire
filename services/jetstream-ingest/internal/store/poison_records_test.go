package store

import (
	"bytes"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stygian-tech/the-social-wire/services/jetstream-ingest/internal/ingest"
)

func TestPoisonPreparationKeepsSourceBytesAndBoundsDiagnostics(t *testing.T) {
	key := strings.Repeat("界", 5000)
	raw := []byte(`{"record":{"` + key + `\u0000":1,"` + key + `\ufffd":2}}`)
	original := bytes.Clone(raw)
	events := []ingest.InboxEvent{{Seq: 1, Payload: raw}, {Seq: 2, Payload: []byte(`{"record":{"text":"before\u0000after"}}`)}}
	good, poison := preparePoisonRecords(events)
	if len(good) != 1 || good[0].Seq != 2 || len(poison) != 1 || poison[0].event.Seq != 1 {
		t.Fatalf("wrong deterministic partition: good=%#v poison=%#v", good, poison)
	}
	if !bytes.Equal(original, raw) || !bytes.Equal(poison[0].event.Payload, original) {
		t.Fatal("poison source bytes were changed")
	}
	if len(poison[0].reason) > 512 || !utf8.ValidString(poison[0].reason) {
		t.Fatalf("unbounded/invalid diagnostic: bytes=%d", len(poison[0].reason))
	}
	if string(good[0].Payload) != `{"record":{"text":"before�after"}}` {
		t.Fatalf("supported normalization not preserved: %s", good[0].Payload)
	}
}
