package appviewcore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

type FeedStore struct{ DB *sql.DB }

type FeedPage struct {
	Response            EntryPage
	MembershipUpdatedAt time.Time
	DatabaseDuration    time.Duration
}

func (s FeedStore) Feed(ctx context.Context, viewer, kind, id, filter, cursor string, limit int, now time.Time) (*FeedPage, error) {
	if kind != "subscribed" && kind != "following" && kind != "folder" && kind != "publication" {
		return nil, errors.New("invalid feed kind")
	}
	if (kind == "folder" || kind == "publication") && id == "" {
		return nil, errors.New("feed id required")
	}
	if filter != "all" && filter != "read" && filter != "unread" {
		return nil, errors.New("invalid feed filter")
	}
	if limit < 1 || limit > 100 {
		return nil, errors.New("invalid feed limit")
	}
	at, uri := now, ""
	if cursor != "" {
		c, err := DecodeEntryCursor(cursor)
		if err != nil {
			return nil, err
		}
		at, uri = c.CreatedAt, c.URI
	}
	selection, ranking, source := "", "ROW_NUMBER() OVER (PARTITION BY content.article_key ORDER BY content.created_at DESC,content.uri DESC)", "matched_content"
	if filter == "all" {
		selection, ranking, source = feedSelectionAll, "1", "selected_content"
	}
	started := time.Now()
	rows, err := s.DB.QueryContext(ctx, fmt.Sprintf(feedQuery, selection, ranking, source), limit+1, kind == "publication", viewer, kind, id, now, cursor != "", at, uri, filter == "all", filter == "unread", filter == "read")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	page := FeedPage{Response: EntryPage{Entries: []Entry{}}}
	known := false
	for rows.Next() {
		var updated time.Time
		var rowURI, render, publication sql.NullString
		var created sql.NullTime
		var read sql.NullBool
		if err := rows.Scan(&updated, &rowURI, &render, &created, &publication, &read); err != nil {
			return nil, err
		}
		known = true
		page.MembershipUpdatedAt = updated
		if !rowURI.Valid || !render.Valid || !created.Valid || !publication.Valid {
			continue
		}
		entry, err := (ContentRow{URI: rowURI.String, CreatedAt: created.Time, RenderJSON: []byte(render.String)}).Entry()
		if err != nil {
			continue
		} // The Swift contract skips malformed stored render payloads.
		entry.PublicationID = &publication.String
		entry.IsRead = read.Bool
		page.Response.Entries = append(page.Response.Entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if !known {
		return nil, nil
	}
	if len(page.Response.Entries) > limit {
		page.Response.Entries = page.Response.Entries[:limit]
		last := page.Response.Entries[limit-1]
		encoded := (EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
		page.Response.Cursor = &encoded
	}
	page.DatabaseDuration = time.Since(started)
	return &page, nil
}
