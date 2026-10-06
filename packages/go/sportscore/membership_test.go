package sportscore

import (
	"encoding/json"
	"testing"
	"time"
)

func TestMembershipAcceptsBothPersistedDateFormats(t *testing.T) {
	var numeric, iso Membership
	if err := json.Unmarshal([]byte(`{"entityID":"team","validFrom":0,"validUntil":60}`), &numeric); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(`{"entityID":"team","validFrom":"2001-01-01T00:00:00Z","validUntil":"2001-01-01T00:01:00Z"}`), &iso); err != nil {
		t.Fatal(err)
	}
	if !numeric.ValidFrom.Equal(iso.ValidFrom) || !numeric.ValidUntil.Equal(*iso.ValidUntil) {
		t.Fatal("reference-date/ISO mismatch")
	}
	if !numeric.Includes(numeric.ValidFrom) || numeric.Includes(*numeric.ValidUntil) || numeric.Includes(numeric.ValidFrom.Add(-time.Nanosecond)) {
		t.Fatal("membership boundary mismatch")
	}
}
func TestMembershipRejectsMissingOrNullStart(t *testing.T) {
	for _, record := range []string{`{"entityID":"team"}`, `{"entityID":"team","validFrom":null}`} {
		var membership Membership
		if json.Unmarshal([]byte(record), &membership) == nil {
			t.Fatal("accepted missing start")
		}
	}
}
