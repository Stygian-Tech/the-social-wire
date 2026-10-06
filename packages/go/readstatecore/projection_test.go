package readstatecore

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestSharedProtocolFixture(t *testing.T) {
	data, err := os.ReadFile("../../read-state/fixtures/v2-foundation.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ViewerDID  string      `json:"viewerDid"`
		DeviceID   string      `json:"deviceId"`
		Manifest   Manifest    `json:"manifest"`
		Operations []Operation `json:"operations"`
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if err = ValidateManifest(fixture.Manifest, fixture.ViewerDID); err != nil {
		t.Fatal(err)
	}
	projection, err := NewProjection(fixture.Operations, fixture.Manifest.LastSequence, 1)
	if err != nil {
		t.Fatal(err)
	}
	if projection.LastSequence() != 9 {
		t.Fatal("fixture sequence lost")
	}
	receipt, err := NewDeviceReceipt(fixture.ViewerDID, fixture.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	advanced, err := receipt.Advance(1, []string{strings.Repeat("a", 64), strings.Repeat("b", 64)})
	if err != nil {
		t.Fatal(err)
	}
	count, err := receipt.VerifiedAcknowledgement(advanced, []string{strings.Repeat("a", 64), strings.Repeat("b", 64)})
	if err != nil || count != 2 {
		t.Fatal("receipt prefix failed", err)
	}
	if _, err = receipt.VerifiedAcknowledgement(advanced, []string{strings.Repeat("c", 64), strings.Repeat("b", 64)}); !errors.Is(err, ErrConflictingSequence) {
		t.Fatal("counter-only acknowledgement accepted", err)
	}
}
func TestBoundaryMicrosecondsAndUTF8Tie(t *testing.T) {
	site := "https://site.example"
	entry := "é"
	scope := Scope{"pub", "did:plc:writer", []string{site}}
	operation := Operation{ActionID: "a", Sequence: 1, State: Read, ActedAt: "2026-10-05T00:00:00Z", Selection: Boundaries, Boundaries: []Boundary{{scope, "2026-10-05T00:00:00.000005Z", &entry}}}
	projection, err := NewProjection([]Operation{operation}, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	at, _ := ParseDate(operation.Boundaries[0].CreatedAt)
	if !projection.Resolve(Subject{"a", scope.AuthorDID, &site, at}).IsRead {
		t.Fatal("inclusive boundary lost")
	}
	if projection.Resolve(Subject{"𐀀", scope.AuthorDID, &site, at}).IsRead {
		t.Fatal("UTF-8 tie boundary wrong")
	}
	if projection.Resolve(Subject{"a", scope.AuthorDID, &site, at.Add(time.Microsecond)}).IsRead {
		t.Fatal("microsecond boundary rounded")
	}
	operation.Boundaries[0].Scope.PublicationSiteKeys[0] = "mutated"
	if !projection.Resolve(Subject{"a", scope.AuthorDID, &site, at}).IsRead {
		t.Fatal("projection mutated through input")
	}
}
func TestCanonicalRejectsLossyValues(t *testing.T) {
	for _, value := range []any{1.0, int64(MaximumSequence + 1)} {
		if _, err := CanonicalBytes(value); err == nil {
			t.Fatal("lossy value accepted")
		}
	}
	leftValue, _ := CanonicalHash(map[string]any{"long": "b", "a": int64(1)})
	rightValue, _ := CanonicalHash(map[string]any{"a": int64(1), "long": "b"})
	if leftValue != rightValue {
		t.Fatal("canonical map ordering changed")
	}
}

func TestDAGCBORRetainsProtocolBounds(t *testing.T) {
	cycle := map[string]any{}
	cycle["self"] = cycle
	for _, value := range []any{cycle, strings.Repeat("a", 16*1024*1024), string([]byte{0xff}), []byte("bytes")} {
		if _, err := CanonicalBytes(value); err == nil {
			t.Fatal("out-of-policy canonical value accepted")
		}
	}
	// Golden canonical bytes include length-first key order and negative integers.
	data, err := CanonicalBytes(map[string]any{"aa": int64(-1), "b": int64(24)})
	if err != nil || !strings.EqualFold(fmt.Sprintf("%x", data), "a26162181862616120") {
		t.Fatalf("canonical encoding changed: %x %v", data, err)
	}
}

func TestFixtureCanonicalReceiptHashes(t *testing.T) {
	data, err := os.ReadFile("../../read-state/fixtures/v2-foundation.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Viewer     string      `json:"viewerDid"`
		Device     string      `json:"deviceId"`
		Operations []Operation `json:"operations"`
		Receipts   []struct {
			ActionID string `json:"actionId"`
			Hash     string `json:"originalIntentHash"`
		} `json:"receipts"`
		Initial  DeviceReceipt `json:"initialReceipt"`
		Advanced DeviceReceipt `json:"advancedReceipt"`
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	hashes := []string{}
	for itemIndex, operation := range fixture.Operations {
		intentHash, err := OriginalIntentHash([]Operation{operation})
		if err != nil || intentHash != fixture.Receipts[itemIndex].Hash {
			t.Fatalf("intent %s differs from TS/Swift fixture: %s %v", operation.ActionID, intentHash, err)
		}
		hashes = append(hashes, intentHash)
	}
	initial, err := NewDeviceReceipt(fixture.Viewer, fixture.Device)
	if err != nil || initial != fixture.Initial {
		t.Fatalf("initial receipt differs: %+v %v", initial, err)
	}
	advanced, err := initial.Advance(1, hashes)
	if err != nil || advanced != fixture.Advanced {
		t.Fatalf("advanced receipt differs: %+v %v", advanced, err)
	}
}
