package analyticscore

import (
	"context"
	"database/sql"
	"fmt"
	_ "github.com/jackc/pgx/v5/stdlib"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPostgresDedupIsolationSnapshotNullsAndRetention(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_ANALYTICS_TEST_DATABASE_URL")
	if dsn == "" {
		dsn = os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	}
	if dsn == "" {
		t.Skip("isolated PostgreSQL analytics fixture required")
	}
	db, e := sql.Open("pgx", dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	store := Store{DB: db, Secret: strings.Repeat("test-secret", 4)}
	ctx := context.Background()
	now := time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)
	author := fmt.Sprintf("did:plc:analytics%d", time.Now().UnixNano())
	uri := "at://" + author + "/app.bsky.feed.post/one"
	t.Cleanup(func() {
		for _, table := range []string{"creator_analytics_items", "creator_analytics_refresh", "creator_analytics_snapshots", "creator_analytics_events", "creator_analytics_tracking"} {
			_, _ = db.Exec(`DELETE FROM `+table+` WHERE author_did=$1`, author)
		}
	})
	item := Item{URI: uri, Kind: "post", Title: "Hello", Engagement: &Engagement{Likes: 7}, RefreshedAt: now}
	if e = store.Save(ctx, author, []Item{item}, true, now); e != nil {
		t.Fatal(e)
	}
	event := Event{SubjectURI: uri, Event: "outbound_click", Surface: "social-feed"}
	if e = store.Record(ctx, author, author, Event{SubjectURI: uri, Event: "impression", Surface: "social-feed"}, now); e != nil {
		t.Fatal(e)
	}
	if e = store.Record(ctx, "did:plc:viewer", author, event, now); e != nil {
		t.Fatal(e)
	}
	event.Event = "impression"
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if e := store.Record(ctx, "did:plc:viewer", author, event, now); e != nil {
				t.Error(e)
			}
		}()
	}
	wg.Wait()
	event.Event = "outbound_click"
	if e = store.Record(ctx, "did:plc:viewer", author, event, now); e != nil {
		t.Fatal(e)
	}
	if e = store.Record(ctx, "did:plc:viewer", author, event, now); e != nil {
		t.Fatal(e)
	}
	summary, e := store.Summary(ctx, author, 30, 50, "", now)
	if e != nil {
		t.Fatal(e)
	}
	if summary.Totals.Tracking.Impressions != 1 || summary.Totals.Tracking.OutboundClicks != 1 || *summary.Totals.Tracking.CTR != 100 || summary.Totals.Engagement.Likes != 7 || summary.Coverage.EngagementKnownItems != 1 {
		t.Fatalf("bad totals %+v", summary)
	}
	other, e := store.Summary(ctx, "did:plc:other", 30, 50, "", now)
	if e != nil || len(other.Items) != 0 || other.Totals.Engagement != nil || other.Totals.Tracking.Impressions != 0 {
		t.Fatalf("account isolation %+v %v", other, e)
	}
	event.Event = "view"
	if e = store.Record(ctx, "did:plc:viewer", author, event, now.AddDate(0, 0, 1)); e != nil {
		t.Fatal(e)
	}
	summary, e = store.Summary(ctx, author, 30, 50, "", now.AddDate(0, 0, 1))
	if e != nil {
		t.Fatal(e)
	}
	if len(summary.Series) != 2 || summary.Series[1].Likes != nil || summary.Series[1].Views == nil || *summary.Series[1].Views != 1 {
		t.Fatalf("invented cumulative history %+v", summary.Series)
	}
	var key string
	if e = db.QueryRow(`SELECT viewer_key FROM creator_analytics_events WHERE author_did=$1 LIMIT 1`, author).Scan(&key); e != nil || strings.Contains(key, "viewer") || len(key) != 64 {
		t.Fatal("raw viewer identity", key, e)
	}
	if e = store.Save(ctx, author, nil, false, now.AddDate(0, 0, 1)); e != nil {
		t.Fatal(e)
	}
	summary, e = store.Summary(ctx, author, 30, 50, "", now)
	if e != nil || len(summary.Items) != 1 {
		t.Fatal("partial refresh erased inventory", e)
	}
	if e = store.Save(ctx, author, nil, true, now.AddDate(0, 0, 1)); e != nil {
		t.Fatal(e)
	}
	summary, e = store.Summary(ctx, author, 30, 50, "", now)
	if e != nil || len(summary.Items) != 0 || summary.Totals.Engagement != nil {
		t.Fatal("complete refresh retained deleted content", e)
	}
	page, e := store.Summary(ctx, author, 30, 1, "", now)
	if e != nil || len(page.Items) != 0 {
		t.Fatal(e)
	}
	if e = store.Save(ctx, author, []Item{item}, true, now.AddDate(0, 0, 2)); e != nil {
		t.Fatal(e)
	}
	if e = store.Save(ctx, author, nil, true, now); e != nil {
		t.Fatal(e)
	}
	page, e = store.Summary(ctx, author, 30, 50, "", now.AddDate(0, 0, 2))
	if e != nil || len(page.Items) != 1 {
		t.Fatal("older refresh replaced newer snapshot")
	}
	if e = (Store{DB: db, Secret: "short"}).Record(ctx, "viewer", author, event, now); e == nil {
		t.Fatal("missing pseudonym secret accepted")
	}
	if e = store.Cleanup(ctx, now.AddDate(0, 0, 94)); e != nil {
		t.Fatal(e)
	}
	summary, e = store.Summary(ctx, author, 90, 50, "", now.AddDate(0, 0, 94))
	if e != nil || len(summary.Items) != 0 || len(summary.Series) != 0 {
		t.Fatal("retention", summary, e)
	}
}
