package publicationcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"time"
)

type FirstPage struct {
	Page                appviewcore.EntryPage
	Source              string
	CachedAt, ExpiresAt *time.Time
	Stale               bool
}

func decodePage(raw string) (appviewcore.EntryPage, error) {
	var value any
	err := json.Unmarshal([]byte(raw), &value)
	if err != nil {
		return appviewcore.EntryPage{}, err
	}
	pageDates(value)
	data, err := json.Marshal(value)
	if err != nil {
		return appviewcore.EntryPage{}, err
	}
	var page appviewcore.EntryPage
	err = json.Unmarshal(data, &page)
	return page, err
}
func pageDates(value any) {
	switch v := value.(type) {
	case map[string]any:
		for key, item := range v {
			if key == "publishedAt" || key == "feedPositionAt" {
				if seconds, ok := item.(float64); ok {
					v[key] = time.Unix(0, int64((seconds+978307200)*1e9)).UTC().Format(time.RFC3339Nano)
				}
			}
			pageDates(item)
		}
	case []any:
		for _, item := range v {
			pageDates(item)
		}
	}
}
func (c CacheStore) CachedPage(ctx context.Context, viewer, publication string, limit int, at time.Time) (*FirstPage, error) {
	for _, owner := range []string{viewer, thinappviewcore.SharedFirstPageViewer} {
		raw := ""
		var cached, expires time.Time
		stale := false
		if c.Redis != nil {
			hit, e := socialwireredis.LookupValue[string](ctx, c.Redis, c.Projection.Namespace.Key("firstpage", nil, []string{publication, owner}), at)
			if e != nil {
				return nil, e
			}
			if hit.State == socialwireredis.Miss {
				continue
			}
			raw = hit.Envelope.Value
			cached = time.UnixMilli(int64(*hit.Envelope.CachedAt))
			expires = time.UnixMilli(int64(*hit.Envelope.FreshUntil))
			stale = hit.State == socialwireredis.Stale
		} else {
			e := c.Projection.DB.QueryRowContext(ctx, `SELECT json_body::text,cached_at,expires_at FROM first_page_cache WHERE viewer_did=$1 AND publication_id=$2 AND expires_at>$3`, owner, publication, at).Scan(&raw, &cached, &expires)
			if e == sql.ErrNoRows {
				continue
			}
			if e != nil {
				return nil, e
			}
		}
		page, e := decodePage(raw)
		if e != nil || len(page.Entries) == 0 {
			continue
		}
		if len(page.Entries) > limit {
			last := page.Entries[limit-1]
			page.Entries = page.Entries[:limit]
			cursor := (appviewcore.EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
			page.Cursor = &cursor
		}
		for i := range page.Entries {
			page.Entries[i].PublicationID = &publication
			if page.Entries[i].FeedPositionAt.IsZero() {
				page.Entries[i].FeedPositionAt = page.Entries[i].PublishedAt
			}
		}
		states, e := (appviewcore.ReadStateStore{DB: c.Projection.DB}).ReadStates(ctx, viewer, page.Entries)
		if e != nil {
			return nil, e
		}
		for i := range page.Entries {
			page.Entries[i].IsRead = states[page.Entries[i].EntryID]
		}
		return &FirstPage{Page: page, Source: "projection_cache", CachedAt: &cached, ExpiresAt: &expires, Stale: stale}, nil
	}
	return nil, nil
}
func (s *Service) LivePage(ctx context.Context, auth gatewaycore.AuthContext, row SidebarRow, limit int) (*FirstPage, error) {
	scope := row.AppViewScope.ReadScope(row.PublicationID)
	page, e := (appviewcore.ContentReader{DB: s.DB}).ScopedEntries(ctx, auth.DID, []appviewcore.PublicationScope{scope}, "all", "", limit, s.Now())
	if e != nil {
		return nil, e
	}
	if len(page.Response.Entries) == 0 {
		return nil, nil
	}
	if s.Cache != nil {
		neutral := page.Response
		neutral.Entries = append([]appviewcore.Entry{}, page.Response.Entries...)
		for i := range neutral.Entries {
			neutral.Entries[i].IsRead = false
		}
		if raw, e := json.Marshal(neutral); e == nil {
			_ = s.Cache.Projection.StoreFirstPage(ctx, auth.DID, row.PublicationID, string(raw), s.Now())
		}
	}
	return &FirstPage{Page: page.Response, Source: "live_projection"}, nil
}
