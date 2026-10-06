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
	data, e := os.ReadFile("../../read-state/fixtures/v2-foundation.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixture struct {
		ViewerDID  string      `json:"viewerDid"`
		DeviceID   string      `json:"deviceId"`
		Manifest   Manifest    `json:"manifest"`
		Operations []Operation `json:"operations"`
	}
	if e = json.Unmarshal(data, &fixture); e != nil {
		t.Fatal(e)
	}
	if e = ValidateManifest(fixture.Manifest, fixture.ViewerDID); e != nil {
		t.Fatal(e)
	}
	p, e := NewProjection(fixture.Operations, fixture.Manifest.LastSequence, 1)
	if e != nil {
		t.Fatal(e)
	}
	if p.LastSequence() != 9 {
		t.Fatal("fixture sequence lost")
	}
	r, e := NewDeviceReceipt(fixture.ViewerDID, fixture.DeviceID)
	if e != nil {
		t.Fatal(e)
	}
	advanced, e := r.Advance(1, []string{strings.Repeat("a", 64), strings.Repeat("b", 64)})
	if e != nil {
		t.Fatal(e)
	}
	n, e := r.VerifiedAcknowledgement(advanced, []string{strings.Repeat("a", 64), strings.Repeat("b", 64)})
	if e != nil || n != 2 {
		t.Fatal("receipt prefix failed", e)
	}
	if _, e = r.VerifiedAcknowledgement(advanced, []string{strings.Repeat("c", 64), strings.Repeat("b", 64)}); !errors.Is(e, ErrConflictingSequence) {
		t.Fatal("counter-only acknowledgement accepted", e)
	}
}
func TestBoundaryMicrosecondsAndUTF8Tie(t *testing.T) {
	site := "https://site.example"
	entry := "é"
	scope := Scope{"pub", "did:plc:writer", []string{site}}
	o := Operation{ActionID: "a", Sequence: 1, State: Read, ActedAt: "2026-10-05T00:00:00Z", Selection: Boundaries, Boundaries: []Boundary{{scope, "2026-10-05T00:00:00.000005Z", &entry}}}
	p, e := NewProjection([]Operation{o}, 1, 1)
	if e != nil {
		t.Fatal(e)
	}
	at, _ := ParseDate(o.Boundaries[0].CreatedAt)
	if !p.Resolve(Subject{"a", scope.AuthorDID, &site, at}).IsRead {
		t.Fatal("inclusive boundary lost")
	}
	if p.Resolve(Subject{"𐀀", scope.AuthorDID, &site, at}).IsRead {
		t.Fatal("UTF-8 tie boundary wrong")
	}
	if p.Resolve(Subject{"a", scope.AuthorDID, &site, at.Add(time.Microsecond)}).IsRead {
		t.Fatal("microsecond boundary rounded")
	}
	o.Boundaries[0].Scope.PublicationSiteKeys[0] = "mutated"
	if !p.Resolve(Subject{"a", scope.AuthorDID, &site, at}).IsRead {
		t.Fatal("projection mutated through input")
	}
}
func TestCanonicalRejectsLossyValues(t *testing.T) {
	for _, v := range []any{1.0, int64(MaximumSequence + 1)} {
		if _, e := CanonicalBytes(v); e == nil {
			t.Fatal("lossy value accepted")
		}
	}
	a, _ := CanonicalHash(map[string]any{"long": "b", "a": int64(1)})
	b, _ := CanonicalHash(map[string]any{"a": int64(1), "long": "b"})
	if a != b {
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
	data, e := os.ReadFile("../../read-state/fixtures/v2-foundation.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
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
	if e = json.Unmarshal(data, &f); e != nil {
		t.Fatal(e)
	}
	hashes := []string{}
	for i, o := range f.Operations {
		h, e := OriginalIntentHash([]Operation{o})
		if e != nil || h != f.Receipts[i].Hash {
			t.Fatalf("intent %s differs from TS/Swift fixture: %s %v", o.ActionID, h, e)
		}
		hashes = append(hashes, h)
	}
	initial, e := NewDeviceReceipt(f.Viewer, f.Device)
	if e != nil || initial != f.Initial {
		t.Fatalf("initial receipt differs: %+v %v", initial, e)
	}
	advanced, e := initial.Advance(1, hashes)
	if e != nil || advanced != f.Advanced {
		t.Fatalf("advanced receipt differs: %+v %v", advanced, e)
	}
}
