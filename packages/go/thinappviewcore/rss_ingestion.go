package thinappviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

type RSSIngestion struct {
	DB           *sql.DB
	HTTP         PublicGetter
	Cache        *ProjectionCache
	MaximumItems int
	Retention    time.Duration
	Now          func() time.Time
}

func (r RSSIngestion) Ingest(ctx context.Context, raw string) (int, error) {
	feed := NormalizeFeedURL(raw)
	if feed == nil {
		return 0, nil
	}

	if r.Cache != nil {
		lease, err := r.Cache.AcquireRefreshLease(ctx, "rss", *feed, 120*time.Second)
		if err == nil && lease == nil {
			return 0, nil
		}
		if err == nil && lease != nil {
			renewalCtx, stop := context.WithCancel(ctx)
			done := make(chan struct{})
			go func() {
				defer close(done)
				ticker := time.NewTicker(40 * time.Second)
				defer ticker.Stop()
				for {
					select {
					case <-renewalCtx.Done():
						return
					case <-ticker.C:
						ok, err := r.Cache.RenewRefreshLease(renewalCtx, *lease)
						if err != nil || !ok {
							return
						}
					}
				}
			}()
			defer func() {
				stop()
				<-done
				releaseCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
				defer cancel()
				_ = r.Cache.ReleaseRefreshLease(releaseCtx, *lease)
			}()
		}
	}
	now := r.Now
	if now == nil {
		now = time.Now
	}
	at := now()
	store := RSSStore{DB: r.DB}
	previous, _ := store.Metadata(ctx, *feed)
	if previous != nil && previous.BackoffUntil != nil && previous.BackoffUntil.After(at) {
		return 0, nil
	}
	headers := http.Header{"Accept": []string{"application/rss+xml, application/atom+xml, application/xml, text/xml, */*"}, "User-Agent": []string{"the-social-wire/thin-appview"}}
	if previous != nil {
		if previous.ETag != nil {
			headers.Set("If-None-Match", *previous.ETag)
		}
		if previous.LastModified != nil {
			headers.Set("If-Modified-Since", *previous.LastModified)
		}
	}
	client := r.HTTP
	if client == nil {
		client = PublicHTTP{}
	}
	requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	status, responseHeaders, body, err := client.Get(requestCtx, *feed, headers, 2*1024*1024, 5)
	failure := func() {
		m := RSSFetchMetadata{FeedURL: *feed, LastPollAt: &at, ConsecutiveErrors: 1}
		if previous != nil {
			m.ETag = previous.ETag
			m.LastModified = previous.LastModified
			m.ConsecutiveErrors = min(previous.ConsecutiveErrors+1, 8)
		}
		delay := min(6*time.Hour, 5*time.Minute*time.Duration(uint64(1)<<max(0, m.ConsecutiveErrors-1)))
		until := at.Add(delay)
		m.BackoffUntil = &until
		_ = store.StoreMetadata(ctx, m)
	}
	success := func() {
		m := RSSFetchMetadata{FeedURL: *feed, LastPollAt: &at}
		if previous != nil {
			m.ETag = previous.ETag
			m.LastModified = previous.LastModified
		}
		if value := strings.TrimSpace(responseHeaders.Get("ETag")); value != "" {
			m.ETag = &value
		}
		if value := strings.TrimSpace(responseHeaders.Get("Last-Modified")); value != "" {
			m.LastModified = &value
		}
		_ = store.StoreMetadata(ctx, m)
	}
	if err != nil {
		failure()
		return 0, nil
	}
	if status == 304 {
		success()
		return 0, nil
	}
	if status != 200 && status != 403 && status != 406 && status != 415 {
		failure()
		return 0, nil
	}
	parsed, err := ParseRSS(body, feed, at)
	if err != nil {
		failure()
		return 0, nil
	}
	limit := r.MaximumItems
	if limit <= 0 {
		limit = 100
	}
	retention := r.Retention
	if retention <= 0 {
		retention = 30 * 24 * time.Hour
	}
	content := ContentStore{DB: r.DB}
	identities := map[string]string{}
	indexed := 0
	for _, item := range parsed.Items[:min(limit, len(parsed.Items))] {
		uri := RSSEntryID(*feed, RSSStableItemKey(item))
		title := DecodeRenderText(item.Title)
		link := ""
		if item.Link != nil {
			link = strings.TrimSpace(*item.Link)
		}
		if title == "" || title == "Untitled" {
			title = link
		}
		if title == "" {
			title = "Untitled"
		}
		summary := ""
		if item.Summary != nil {
			summary = DecodeRenderText(*item.Summary)
		}
		if summary == "" && link != "" && link != DecodeRenderText(item.Title) {
			summary = link
		}
		html := RSSHTMLBody(item.ContentHTML, item.Summary)
		article := RSSCanonicalArticleURL(link)
		render := ContentRenderFields{Title: title, PublishedAt: item.PublishedAtISO, Summary: optional(summary), ThumbnailURL: item.ThumbnailURL, ContentHTML: &html, ArticleURL: optional(article)}
		for _, key := range RSSDedupeKeys(uri, render) {
			if existing := identities[key]; existing != "" && existing != uri {
				_ = content.Delete(ctx, existing)
			}
			identities[key] = uri
		}
		created, err := time.Parse(time.RFC3339Nano, item.PublishedAtISO)
		if err != nil {
			created = at
		}
		entry := IndexedContentItem{URI: uri, CID: RSSDeterministicCID(uri), AuthorDID: RSSAuthorDID, Collection: RSSEntryCollection, CreatedAt: created, IndexedAt: at, ExpiresAt: at.Add(retention), PublicationSite: feed, Render: render}
		if err := content.Upsert(ctx, entry); err != nil {
			return indexed, err
		}
		indexed++
	}
	if err := r.cleanupDuplicates(ctx, *feed); err != nil {
		return indexed, err
	}
	success()
	return indexed, nil
}
func (r RSSIngestion) cleanupDuplicates(ctx context.Context, feed string) error {
	rows, err := r.DB.QueryContext(ctx, `SELECT uri,render_json::text FROM content_items WHERE author_did=$1 AND publication_site=$2 AND expires_at>NOW() ORDER BY created_at DESC,uri DESC LIMIT 1000`, RSSAuthorDID, feed)
	if err != nil {
		return err
	}
	type entry struct {
		uri    string
		render ContentRenderFields
	}
	entries := []entry{}
	for rows.Next() {
		var e entry
		var raw string
		if err := rows.Scan(&e.uri, &raw); err != nil {
			rows.Close()
			return err
		}
		if json.Unmarshal([]byte(raw), &e.render) == nil {
			entries = append(entries, e)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	identities := map[string]string{}
	remove := map[string]bool{}
	titleTimes := map[string]bool{}
	score := func(uri string) int {
		_, key := DecodeRSSEntryID(uri)
		if strings.HasPrefix(key, "link:") || strings.HasPrefix(key, "post:") {
			return 2
		}
		if strings.HasPrefix(key, "guid:") {
			return 1
		}
		return 0
	}
	for _, e := range entries {
		keys := RSSDedupeKeys(e.uri, e.render)
		existing := ""
		for _, key := range keys {
			if identities[key] != "" {
				existing = identities[key]
				break
			}
		}
		if existing != "" {
			if score(e.uri) > score(existing) {
				remove[existing] = true
				for _, key := range keys {
					identities[key] = e.uri
				}
			} else {
				remove[e.uri] = true
			}
		} else {
			for _, key := range keys {
				identities[key] = e.uri
			}
		}
	}
	kept := map[string]bool{}
	for _, uri := range identities {
		kept[uri] = true
	}
	for _, e := range entries {
		if kept[e.uri] {
			if at, err := time.Parse(time.RFC3339Nano, e.render.PublishedAt); err == nil {
				titleTimes[strings.ToLower(strings.TrimSpace(e.render.Title))+"|"+at.UTC().Format(time.RFC3339)] = true
			}
		}
	}
	for _, e := range entries {
		if !remove[e.uri] && !kept[e.uri] {
			if at, err := time.Parse(time.RFC3339Nano, e.render.PublishedAt); err == nil && titleTimes[strings.ToLower(strings.TrimSpace(e.render.Title))+"|"+at.UTC().Format(time.RFC3339)] {
				remove[e.uri] = true
			}
		}
	}
	for uri := range remove {
		if err := (ContentStore{DB: r.DB}).Delete(ctx, uri); err != nil {
			return err
		}
	}
	return nil
}
