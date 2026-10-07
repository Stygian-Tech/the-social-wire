package appviewcore

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestEntryDatesAndArticleURLMatchDeployedContract(t *testing.T) {
	at := time.Date(2026, 10, 7, 1, 2, 3, 456000000, time.FixedZone("offset", 3600))
	raw := []byte(`{"title":"A &amp; B","publishedAt":"bad date","articleUrl":"http://example.com/post/?tracking=1#part"}`)
	entry, err := (ContentRow{URI: "entry", CreatedAt: at, RenderJSON: raw}).Entry()
	if err != nil {
		t.Fatal(err)
	}
	if entry.Title != "A & B" || entry.OriginalURL == nil || *entry.OriginalURL != "http://example.com/post" {
		t.Fatalf("incorrect render fields: %#v", entry)
	}
	data, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(data, &body); err != nil {
		t.Fatal(err)
	}
	if body["publishedAt"] != "2026-10-07T00:02:03Z" || body["feedPositionAt"] != "2026-10-07T00:02:03Z" {
		t.Fatalf("date presentation changed: %s", data)
	}
	if !entry.FeedPositionAt.Equal(at) {
		t.Fatal("serialization altered precise database ordering timestamp")
	}
	if _, exists := body["thumbnailUrl"]; exists {
		t.Fatal("absent optional field emitted")
	}
	uri := thinappviewcore.RSSEntryID("https://example.com/feed", "link:https://example.com/article?source=rss")
	fallback, err := (ContentRow{URI: uri, CreatedAt: at, RenderJSON: []byte(`{"title":"RSS","publishedAt":"2026-10-07T00:00:00Z"}`)}).Entry()
	if err != nil || fallback.OriginalURL == nil || *fallback.OriginalURL != "https://example.com/article" {
		t.Fatalf("lost RSS permalink: %#v %v", fallback, err)
	}
}
