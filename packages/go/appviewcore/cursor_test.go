package appviewcore

import (
	"testing"
	"time"
)

func TestDeployedCursorContract(t *testing.T) {
	const fixture = "2026-10-06T09:03:20Z|at://did:plc:test/site.standard.document/a|b"
	cursor, err := DecodeEntryCursor(fixture)
	if err != nil || cursor.URI != "at://did:plc:test/site.standard.document/a|b" || cursor.Encode() != fixture {
		t.Fatalf("deployed cursor did not round trip: %#v %v", cursor, err)
	}
	if cursor.CreatedAt.Location() != time.UTC {
		t.Fatal("cursor timestamp is not UTC")
	}
}

func TestRejectMalformedCursors(t *testing.T) {
	for _, raw := range []string{"", "2026-10-06T09:03:20Z", "2026-10-06T09:03:20Z|", "not-a-date|at://entry", "2026-13-01T00:00:00Z|entry"} {
		if _, err := DecodeEntryCursor(raw); err == nil {
			t.Errorf("accepted malformed cursor %q", raw)
		}
	}
}

func TestCursorRetainsDatabaseOrderingPrecision(t *testing.T) {
	fixture := "2026-10-06T09:03:20.123456789Z|at://did:plc:test/site.standard.document/a"
	cursor, err := DecodeEntryCursor(fixture)
	if err != nil || cursor.Encode() != fixture {
		t.Fatalf("fractional position lost: %#v %v", cursor, err)
	}
}
