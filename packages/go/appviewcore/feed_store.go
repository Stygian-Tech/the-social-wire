package appviewcore

import (
	"context"
	"database/sql"
	"errors"
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
	started := time.Now()
	page := FeedPage{Response: EntryPage{Entries: []Entry{}}}
	seen := map[string]bool{}
	publicationCursor := ""
	internalCursor := false
	hasCursor := cursor != ""
	accepted := 0
	// Avoid reading a large history slice from every scope for a small page.
	batchSize := max(32, limit+1)
	for {
		rows, err := s.DB.QueryContext(ctx, feedBatchQuery, batchSize, kind == "publication", viewer, kind, id, now, hasCursor, at, uri, publicationCursor, internalCursor)
		if err != nil {
			return nil, err
		}
		known, scanned := false, 0
		for rows.Next() {
			var updated time.Time
			var rowURI, render, publication, article sql.NullString
			var created sql.NullTime
			var read sql.NullBool
			if err := rows.Scan(&updated, &rowURI, &render, &created, &publication, &read, &article); err != nil {
				rows.Close()
				return nil, err
			}
			known = true
			page.MembershipUpdatedAt = updated
			if !rowURI.Valid {
				continue
			}
			scanned++
			at, uri, publicationCursor = created.Time, rowURI.String, publication.String
			if accepted > limit || seen[article.String] {
				continue
			}
			seen[article.String] = true
			if filter == "unread" && read.Bool || filter == "read" && !read.Bool {
				continue
			}
			// Match the SQL page limit before skipping malformed render payloads.
			accepted++
			entry, err := (ContentRow{URI: rowURI.String, CreatedAt: created.Time, RenderJSON: []byte(render.String)}).Entry()
			if err != nil {
				continue
			}
			entry.PublicationID = &publication.String
			entry.IsRead = read.Bool
			page.Response.Entries = append(page.Response.Entries, entry)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		if !known {
			return nil, nil
		}
		if accepted > limit || scanned < batchSize {
			break
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		hasCursor, internalCursor = true, true
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
