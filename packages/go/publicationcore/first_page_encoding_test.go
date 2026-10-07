package publicationcore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"strings"
	"testing"
	"time"
)

func TestFirstPageCachePreservesFractionalPositions(t *testing.T) {
	at := time.Date(2026, 10, 7, 5, 4, 3, 123456789, time.UTC)
	position := at.Add(345 * time.Millisecond)
	cursor := (appviewcore.EntryCursor{CreatedAt: position, URI: "at://fixture/document/one"}).Encode()
	page := appviewcore.EntryPage{Entries: []appviewcore.Entry{{EntryID: "at://fixture/document/one", Title: "Fixture", PublishedAt: at, FeedPositionAt: position, IsRead: false}}, Cursor: &cursor}
	raw, err := EncodeFirstPage(page)
	if err != nil {
		t.Fatal(err)
	}
	var data struct{ Entries []map[string]any }
	if err := json.Unmarshal(raw, &data); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"publishedAt", "feedPositionAt"} {
		if _, ok := data.Entries[0][key].(float64); !ok {
			t.Fatalf("%s is not numeric", key)
		}
	}
	decoded, err := decodePage(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	for _, dates := range [][2]time.Time{{at, decoded.Entries[0].PublishedAt}, {position, decoded.Entries[0].FeedPositionAt}} {
		delta := dates[0].Sub(dates[1])
		if delta < -120*time.Nanosecond || delta > 120*time.Nanosecond {
			t.Fatalf("reference-date precision lost: %s", delta)
		}
	}
	if decoded.Cursor == nil || *decoded.Cursor != cursor {
		t.Fatal("cursor changed")
	}
	api, err := json.Marshal(page)
	if err != nil || !strings.Contains(string(api), `"publishedAt":"2026-10-07T05:04:03Z"`) {
		t.Fatal("public encoding changed", err)
	}
}
