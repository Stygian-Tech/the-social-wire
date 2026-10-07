package appviewcore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
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
	return Entry{EntryID: r.URI, Title: thinappviewcore.DecodeRenderText(render.Title), Summary: decodeOptional(render.Summary), PublishedAt: at, ThumbnailURL: render.ThumbnailURL, OriginalURL: render.ArticleURL, PublicationID: r.PublicationSite, FeedPositionAt: r.CreatedAt}, nil
}

func decodeOptional(raw *string) *string {
	if raw == nil {
		return nil
	}
	value := thinappviewcore.DecodeRenderText(*raw)
	return &value
}
