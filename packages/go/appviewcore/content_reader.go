package appviewcore

import (
	"context"
	"database/sql"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"time"
)

type ContentReader struct{ DB *sql.DB }

func (s ContentReader) Item(ctx context.Context, viewer, uri string, now time.Time) (*Entry, error) {
	var row ContentRow
	err := s.DB.QueryRowContext(ctx, `SELECT uri,render_json::text,created_at,publication_site FROM content_items WHERE uri=$1 AND expires_at>$2 LIMIT 1`, uri, now).Scan(&row.URI, &row.RenderJSON, &row.CreatedAt, &row.PublicationSite)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	entry, err := row.Entry()
	if err != nil {
		return nil, nil
	}
	states, err := (ReadStateStore{DB: s.DB}).ReadStates(ctx, viewer, []Entry{entry})
	if err != nil {
		return nil, err
	}
	entry.IsRead = states[entry.EntryID]
	return &entry, nil
}

func (s ContentReader) Entries(ctx context.Context, q EntryQuery, now time.Time) (EntryPage, error) {
	if q.AuthorDID == "" || q.Limit < 1 || q.Limit > 100 {
		return EntryPage{}, errors.New("invalid entry query")
	}
	if q.Filter != "all" && q.Filter != "read" && q.Filter != "unread" {
		return EntryPage{}, errors.New("invalid entry filter")
	}
	var cursor *EntryCursor
	if q.Cursor != "" {
		c, err := DecodeEntryCursor(q.Cursor)
		if err != nil {
			return EntryPage{}, err
		}
		cursor = &c
	}
	scoped := q.PublicationATURI != "" || len(q.ScopeATURIs) > 0 || len(q.SiteURLs) > 0
	batch := q.Limit + 1
	if scoped {
		batch = max(batch, 100)
	}
	page := EntryPage{Entries: []Entry{}}
	seen := map[string]bool{}
	for len(page.Entries) <= q.Limit {
		at, uri := now, ""
		if cursor != nil {
			at, uri = cursor.CreatedAt, cursor.URI
		}
		rows, err := s.DB.QueryContext(ctx, `SELECT ci.uri,ci.render_json::text,ci.created_at,ci.publication_site
 FROM content_items ci WHERE ci.author_did=$1 AND ci.expires_at>$2
 AND ($3::boolean=FALSE OR (ci.created_at,ci.uri)<($4::timestamptz,$5::text))
 ORDER BY ci.created_at DESC,ci.uri DESC LIMIT $6`, q.AuthorDID, now, cursor != nil, at, uri, batch)
		if err != nil {
			return EntryPage{}, err
		}
		items := []Entry{}
		count := 0
		for rows.Next() {
			var row ContentRow
			if err := rows.Scan(&row.URI, &row.RenderJSON, &row.CreatedAt, &row.PublicationSite); err != nil {
				rows.Close()
				return EntryPage{}, err
			}
			count++
			cursor = &EntryCursor{CreatedAt: row.CreatedAt, URI: row.URI}
			site := ""
			if row.PublicationSite != nil {
				site = *row.PublicationSite
			}
			if !thinappviewcore.MatchesPublication(site, q.PublicationATURI, q.ScopeATURIs, q.SiteURLs) {
				continue
			}
			entry, err := row.Entry()
			if err != nil {
				continue
			}
			if q.PublicationID != "" {
				publication := q.PublicationID
				entry.PublicationID = &publication
			}
			items = append(items, entry)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return EntryPage{}, err
		}
		states, err := (ReadStateStore{DB: s.DB}).ReadStates(ctx, q.ViewerDID, items)
		if err != nil {
			return EntryPage{}, err
		}
		for _, entry := range items {
			entry.IsRead = states[entry.EntryID]
			if q.Filter == "read" && !entry.IsRead || q.Filter == "unread" && entry.IsRead {
				continue
			}
			key := entry.EntryID
			if entry.OriginalURL != nil {
				key = thinappviewcore.RSSCanonicalArticleURL(*entry.OriginalURL)
			}
			if seen[key] {
				continue
			}
			seen[key] = true
			page.Entries = append(page.Entries, entry)
		}
		if len(page.Entries) > q.Limit {
			page.Entries = page.Entries[:q.Limit]
			last := page.Entries[q.Limit-1]
			encoded := (EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
			page.Cursor = &encoded
			return page, nil
		}
		if count < batch {
			return page, nil
		}
		if err := ctx.Err(); err != nil {
			return EntryPage{}, err
		}
	}
	return page, nil
}
