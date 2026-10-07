package thinappviewcore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"testing"
	"time"
)

func TestRSSSharedFirstPageWarmingCanonicalPayloadAndFreshness(t *testing.T) {
	db := inboxDatabase(t)
	nonce, err := inboxLeaseToken()
	if err != nil {
		t.Fatal(err)
	}
	feed := "https://publisher.social/" + nonce + "/rss"
	pub := RSSPublicationID(feed)
	at := time.Now().UTC().Truncate(time.Second)
	ctx := context.Background()
	t.Cleanup(func() {
		db.Exec("DELETE FROM content_items WHERE author_did=$1 AND publication_site=$2", RSSAuthorDID, feed)
		db.Exec("DELETE FROM first_page_cache WHERE viewer_did=$1 AND publication_id=$2", SharedFirstPageViewer, pub)
	})
	store := ContentStore{DB: db}
	for i := 0; i < 51; i++ {
		article := fmt.Sprintf("https://publisher.social/%s/%02d?tracking=discard", nonce, i)
		uri := RSSEntryID(feed, "link:"+article)
		summary := "Summary &amp; Detail"
		image := "https://images.publisher.social/cover.jpg"
		if err := store.Upsert(ctx, IndexedContentItem{URI: uri, CID: RSSDeterministicCID(uri), AuthorDID: RSSAuthorDID, Collection: RSSEntryCollection, PublicationSite: &feed, CreatedAt: at.Add(-time.Duration(i) * time.Second), IndexedAt: at, ExpiresAt: at.Add(time.Hour), Render: ContentRenderFields{Title: fmt.Sprintf("Episode %d &amp; More", i), Summary: &summary, PublishedAt: at.Format(time.RFC3339), ThumbnailURL: &image, ArticleURL: &article}}); err != nil {
			t.Fatal(err)
		}
	}
	cache := ProjectionCache{DB: db}
	if err := cache.WarmRSSFirstPage(ctx, feed, at); err != nil {
		t.Fatal(err)
	}
	var payload string
	var cached, expires time.Time
	if err := db.QueryRow(`SELECT json_body::text,cached_at,expires_at FROM first_page_cache WHERE viewer_did=$1 AND publication_id=$2`, SharedFirstPageViewer, pub).Scan(&payload, &cached, &expires); err != nil {
		t.Fatal(err)
	}
	if expires.Sub(cached) != 5*time.Minute {
		t.Fatalf("freshness %s", expires.Sub(cached))
	}
	var page rssCachedPage
	if err := json.Unmarshal([]byte(payload), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Entries) != 50 || page.Cursor == nil {
		t.Fatalf("page %d %v", len(page.Entries), page.Cursor)
	}
	first := page.Entries[0]
	if first.Title != "Episode 0 & More" || first.Summary == nil || *first.Summary != "Summary & Detail" || first.IsRead || first.ThumbnailURL == nil || first.OriginalURL == nil || *first.OriginalURL != fmt.Sprintf("https://publisher.social/%s/00", nonce) {
		t.Fatalf("canonical entry %+v", first)
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(payload), &raw); err != nil {
		t.Fatal(err)
	}
	entry := raw["entries"].([]any)[0].(map[string]any)
	for _, key := range []string{"entryId", "title", "summary", "publishedAt", "thumbnailUrl", "originalUrl", "feedPositionAt", "isRead"} {
		if _, ok := entry[key]; !ok {
			t.Fatalf("missing payload key %s", key)
		}
	}
	if *page.Cursor != at.Add(-49*time.Second).Format(time.RFC3339)+"|"+page.Entries[49].EntryID {
		t.Fatal("cursor skipped returned-page boundary")
	}
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	defer client.Close()
	namespace := socialwireredis.NewKeyNamespace("dev", "")
	cache.Redis = client
	cache.Namespace = namespace
	if err := cache.WarmRSSFirstPage(ctx, feed, at); err != nil {
		t.Fatal(err)
	}
	key := namespace.Key("firstpage", nil, []string{pub, SharedFirstPageViewer})
	commands := socialwireredis.NewCacheClient(socialwireredis.RedisCommands{Client: client})
	lookup, err := socialwireredis.LookupValue[string](ctx, commands, key, at.Add(4*time.Minute))
	if err != nil || lookup.State != socialwireredis.Fresh {
		t.Fatalf("redis fresh %v %v", lookup.State, err)
	}
	lookup, err = socialwireredis.LookupValue[string](ctx, commands, key, at.Add(6*time.Minute))
	if err != nil || lookup.State != socialwireredis.Stale {
		t.Fatalf("redis stale %v %v", lookup.State, err)
	}
}

func TestRSSWarmDedupeRetainsArtworkFromDuplicate(t *testing.T) {
	feed := "https://publisher.social/rss"
	article := "https://publisher.social/article"
	image := "https://images.publisher.social/cover.jpg"
	first := rssCacheRow{uri: RSSEntryID(feed, "guid:"+article), render: ContentRenderFields{Title: "Episode", ArticleURL: &article}, created: time.Unix(100, 0)}
	second := rssCacheRow{uri: RSSEntryID(feed, "link:"+article), render: ContentRenderFields{Title: "Episode", ArticleURL: &article, ThumbnailURL: &image}, created: time.Unix(99, 0)}
	rows := dedupeRSSCacheRows([]rssCacheRow{first, second})
	if len(rows) != 1 || rows[0].uri != second.uri || rows[0].render.ThumbnailURL == nil {
		t.Fatalf("duplicate artwork dropped %+v", rows)
	}
}

func TestRSSFirstPageRedisPolicyOverrides(t *testing.T) {
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	defer client.Close()
	namespace := socialwireredis.NewKeyNamespace("dev", "")
	cache := ProjectionCache{Redis: client, Namespace: namespace, FirstPageFresh: time.Minute, FirstPageHard: 3 * time.Minute}
	at := time.Now()
	if err := cache.StoreFirstPage(context.Background(), "viewer", "publication", `{"entries":[]}`, at); err != nil {
		t.Fatal(err)
	}
	key := namespace.Key("firstpage", nil, []string{"publication", "viewer"})
	commands := socialwireredis.NewCacheClient(socialwireredis.RedisCommands{Client: client})
	lookup, err := socialwireredis.LookupValue[string](context.Background(), commands, key, at.Add(2*time.Minute))
	if err != nil || lookup.State != socialwireredis.Stale {
		t.Fatalf("override %v %v", lookup.State, err)
	}
	lookup, err = socialwireredis.LookupValue[string](context.Background(), commands, key, at.Add(4*time.Minute))
	if err != nil || lookup.State != socialwireredis.Miss {
		t.Fatalf("hard override %v %v", lookup.State, err)
	}
}
