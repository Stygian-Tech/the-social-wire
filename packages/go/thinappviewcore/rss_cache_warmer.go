package thinappviewcore

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
)

const SharedFirstPageViewer = "__shared_first_page__"

type rssCachedEntry struct {
	EntryID        string  `json:"entryId"`
	Title          string  `json:"title"`
	Summary        *string `json:"summary,omitempty"`
	PublishedAt    string  `json:"publishedAt"`
	ThumbnailURL   *string `json:"thumbnailUrl,omitempty"`
	OriginalURL    *string `json:"originalUrl,omitempty"`
	FeedPositionAt string  `json:"feedPositionAt"`
	IsRead         bool    `json:"isRead"`
}
type rssCacheRow struct {
	uri     string
	render  ContentRenderFields
	created time.Time
}
type rssCachedPage struct {
	Entries []rssCachedEntry `json:"entries"`
	Cursor  *string          `json:"cursor,omitempty"`
}

// WarmRSSFirstPage caches the canonical shared all-entry page. Swift's query
// DTO defaults isRead=false; the viewer read-state overlay remains a read-path concern.
func (c ProjectionCache) WarmRSSFirstPage(ctx context.Context, feed string, at time.Time) error {
	normalized := NormalizeFeedURL(feed)
	if normalized == nil {
		return nil
	}
	rows, err := c.DB.QueryContext(ctx, `SELECT uri,render_json::text,created_at FROM content_items WHERE author_did=$1 AND publication_site=$2 AND expires_at>$3 ORDER BY created_at DESC,uri DESC LIMIT 51`, RSSAuthorDID, *normalized, at)
	if err != nil {
		return err
	}
	candidates := []rssCacheRow{}
	var last rssCacheRow
	scanned := 0
	for rows.Next() {
		var raw string
		var item rssCacheRow
		if err := rows.Scan(&item.uri, &raw, &item.created); err != nil {
			rows.Close()
			return err
		}
		last = item
		scanned++
		if json.Unmarshal([]byte(raw), &item.render) == nil {
			candidates = append(candidates, item)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	page := rssCachedPage{Entries: []rssCachedEntry{}}
	var lastReturned rssCacheRow
	for _, item := range dedupeRSSCacheRows(candidates) {
		published, err := time.Parse(time.RFC3339Nano, item.render.PublishedAt)
		if err != nil {
			published = item.created
		}
		title := DecodeRenderText(item.render.Title)
		if len(page.Entries) == 50 {
			cursor := lastReturned.created.UTC().Format(time.RFC3339) + "|" + lastReturned.uri
			page.Cursor = &cursor
			break
		}
		original := rssOriginalURL(item.uri, item.render)
		var summary *string
		if item.render.Summary != nil {
			decoded := DecodeRenderText(*item.render.Summary)
			summary = &decoded
		}
		page.Entries = append(page.Entries, rssCachedEntry{EntryID: item.uri, Title: title, Summary: summary, PublishedAt: published.UTC().Format(time.RFC3339), ThumbnailURL: item.render.ThumbnailURL, OriginalURL: optional(original), FeedPositionAt: item.created.UTC().Format(time.RFC3339)})
		lastReturned = item
	}
	if page.Cursor == nil && scanned == 51 {
		cursor := last.created.UTC().Format(time.RFC3339) + "|" + last.uri
		page.Cursor = &cursor
	}
	page.Entries = dedupeRSSCachedEntries(page.Entries)
	if len(page.Entries) == 0 {
		return nil
	}
	payload, err := json.Marshal(page)
	if err != nil {
		return err
	}
	return c.StoreFirstPage(ctx, SharedFirstPageViewer, RSSPublicationID(*normalized), string(payload), at)
}
func rssOriginalURL(uri string, render ContentRenderFields) string {
	if render.ArticleURL != nil {
		if canonical := RSSCanonicalArticleURL(*render.ArticleURL); canonical != "" {
			return canonical
		}
	}
	_, key := DecodeRSSEntryID(uri)
	for _, prefix := range []string{"link:", "guid:"} {
		if strings.HasPrefix(key, prefix) {
			raw := strings.TrimPrefix(key, prefix)
			if strings.HasPrefix(strings.ToLower(raw), "http") {
				if canonical := RSSCanonicalArticleURL(raw); canonical != "" {
					return canonical
				}
			}
		}
	}
	if render.Summary != nil && strings.HasPrefix(strings.ToLower(strings.TrimSpace(*render.Summary)), "http") {
		return RSSCanonicalArticleURL(strings.TrimSpace(*render.Summary))
	}
	return ""
}
func (c ProjectionCache) StoreFirstPage(ctx context.Context, viewer, publication, payload string, at time.Time) error {
	if c.Redis != nil {
		client := socialwireredis.NewCacheClient(socialwireredis.RedisCommands{Client: c.Redis})
		fresh, hard := c.FirstPageFresh, c.FirstPageHard
		if fresh <= 0 {
			fresh = 5 * time.Minute
		}
		if hard <= 0 {
			hard = 30 * time.Minute
		}
		return socialwireredis.StoreValue(ctx, client, c.Namespace.Key("firstpage", nil, []string{publication, viewer}), payload, socialwireredis.CachePolicy{FreshDuration: fresh, HardDuration: hard, MaximumJitterFraction: .1}, at)
	}
	_, err := c.DB.ExecContext(ctx, `INSERT INTO first_page_cache(viewer_did,publication_id,json_body,cached_at,expires_at)VALUES($1,$2,$3::jsonb,$4,$5)ON CONFLICT(viewer_did,publication_id)DO UPDATE SET json_body=EXCLUDED.json_body,cached_at=EXCLUDED.cached_at,expires_at=EXCLUDED.expires_at`, viewer, publication, payload, at, at.Add(5*time.Minute))
	return err
}

func dedupeRSSCacheRows(rows []rssCacheRow) []rssCacheRow {
	result := []rssCacheRow{}
	ids := map[string]bool{}
	keys := map[string]int{}
	titles := map[string]bool{}
	for _, item := range rows {
		if ids[item.uri] {
			continue
		}
		ids[item.uri] = true
		identity := RSSDedupeKeys(item.uri, item.render)
		existing := -1
		for _, key := range identity {
			if index, ok := keys[key]; ok && existing < 0 {
				existing = index
			}
		}
		if existing >= 0 {
			for _, key := range identity {
				keys[key] = existing
			}
			if (result[existing].render.ThumbnailURL == nil || *result[existing].render.ThumbnailURL == "") && item.render.ThumbnailURL != nil && *item.render.ThumbnailURL != "" {
				result[existing] = item
			}
			continue
		}
		if len(identity) == 0 {
			published, err := time.Parse(time.RFC3339Nano, item.render.PublishedAt)
			if err != nil {
				published = item.created
			}
			key := strings.ToLower(strings.TrimSpace(item.render.Title)) + "|" + strconv.FormatInt(published.Unix(), 10)
			if titles[key] {
				continue
			}
			titles[key] = true
		}
		for _, key := range identity {
			keys[key] = len(result)
		}
		result = append(result, item)
	}
	return result
}

func dedupeRSSCachedEntries(entries []rssCachedEntry) []rssCachedEntry {
	result := []rssCachedEntry{}
	ids := map[string]bool{}
	identities := map[string]int{}
	titles := map[string]bool{}
	for _, item := range entries {
		if ids[item.EntryID] {
			continue
		}
		ids[item.EntryID] = true
		keys := RSSDedupeKeys(item.EntryID, ContentRenderFields{})
		if link := rssOriginalURL(item.EntryID, ContentRenderFields{Summary: item.Summary}); link != "" {
			keys = append(keys, "url:"+link)
			if post := rssPostIdentity(link); post != "" {
				keys = append(keys, post)
			}
		}
		existing := -1
		for _, key := range keys {
			if index, ok := identities[key]; ok && existing < 0 {
				existing = index
			}
		}
		if existing >= 0 {
			for _, key := range keys {
				identities[key] = existing
			}
			if (result[existing].ThumbnailURL == nil || *result[existing].ThumbnailURL == "") && item.ThumbnailURL != nil && *item.ThumbnailURL != "" {
				result[existing] = item
			}
			continue
		}
		if len(keys) == 0 {
			published, _ := time.Parse(time.RFC3339Nano, item.PublishedAt)
			key := strings.ToLower(strings.TrimSpace(item.Title)) + "|" + strconv.FormatInt(published.Unix(), 10)
			if titles[key] {
				continue
			}
			titles[key] = true
		}
		for _, key := range keys {
			identities[key] = len(result)
		}
		result = append(result, item)
	}
	return result
}
