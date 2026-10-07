package operationsapi

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestStoredSnapshotsPreserveSwiftDateEpochAndExactCounters(t *testing.T) {
	type snapshot struct {
		ID      string   `json:"id"`
		At      WireTime `json:"at"`
		Counter int64    `json:"counter"`
		Note    *string  `json:"note,omitempty"`
	}
	at := time.Date(2026, 10, 7, 1, 2, 3, 125000000, time.UTC)
	expected := float64(at.Unix()-swiftReferenceUnixSeconds) + 0.125
	encoded, err := marshalStored(snapshot{ID: "fixture", At: WireTime{at}, Counter: 9007199254740993})
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if json.Unmarshal(encoded, &raw) != nil {
		t.Fatal("invalid snapshot")
	}
	var seconds float64
	if json.Unmarshal(raw["at"], &seconds) != nil || seconds != expected || string(raw["counter"]) != "9007199254740993" || raw["note"] != nil {
		t.Fatal(string(encoded))
	}
	var roundtrip snapshot
	if json.Unmarshal(encoded, &roundtrip) != nil || !roundtrip.At.Equal(at) || roundtrip.Counter != 9007199254740993 {
		t.Fatal(roundtrip)
	}
	public, err := json.Marshal(roundtrip)
	if err != nil || !strings.Contains(string(public), `"at":"2026-10-07T01:02:03.125Z"`) {
		t.Fatal(string(public), err)
	}
	var fromAPI snapshot
	if json.Unmarshal(public, &fromAPI) != nil || !fromAPI.At.Equal(at) {
		t.Fatal("API date failed round trip")
	}
	for _, invalid := range []string{`"not-a-date"`, `null`, `1e100`} {
		var date WireTime
		if json.Unmarshal([]byte(invalid), &date) == nil {
			t.Fatalf("accepted invalid timestamp %s", invalid)
		}
	}
}
