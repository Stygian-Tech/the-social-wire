package appviewcore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"strings"
	"time"
)

type ContentRow struct {
	URI             string
	CreatedAt       time.Time
	PublicationSite *string
	RenderJSON      []byte
}

func (r ContentRow) Entry() (Entry, error) {
	var render thinappviewcore.ContentRenderFields
	if err := json.Unmarshal(r.RenderJSON, &render); err != nil {
		return Entry{}, err
	}
	at, err := time.Parse(time.RFC3339Nano, render.PublishedAt)
	if err != nil {
		at = r.CreatedAt
	}
	return Entry{EntryID: r.URI, Title: thinappviewcore.DecodeRenderText(render.Title), Summary: decodeOptional(render.Summary), PublishedAt: at, ThumbnailURL: render.ThumbnailURL, OriginalURL: originalURL(r.URI, render), PublicationID: r.PublicationSite, FeedPositionAt: r.CreatedAt}, nil
}

func originalURL(uri string, render thinappviewcore.ContentRenderFields) *string {
	if render.ArticleURL != nil {
		if canonical := thinappviewcore.RSSCanonicalArticleURL(strings.TrimSpace(*render.ArticleURL)); canonical != "" {
			return &canonical
		}
	}
	_, stable := thinappviewcore.DecodeRSSEntryID(uri)
	for _, prefix := range []string{"link:", "guid:"} {
		if strings.HasPrefix(stable, prefix) {
			raw := strings.TrimPrefix(stable, prefix)
			if prefix == "guid:" && !strings.HasPrefix(strings.ToLower(raw), "http") {
				continue
			}
			if canonical := thinappviewcore.RSSCanonicalArticleURL(raw); canonical != "" {
				return &canonical
			}
		}
	}
	if render.Summary != nil && strings.HasPrefix(strings.ToLower(strings.TrimSpace(*render.Summary)), "http") {
		if canonical := thinappviewcore.RSSCanonicalArticleURL(strings.TrimSpace(*render.Summary)); canonical != "" {
			return &canonical
		}
	}
	return nil
}

func decodeOptional(raw *string) *string {
	if raw == nil {
		return nil
	}
	value := thinappviewcore.DecodeRenderText(*raw)
	return &value
}
