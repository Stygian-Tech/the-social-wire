package appviewcore

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func (s ContentReader) ScopedEntries(ctx context.Context, viewer string, scopes []PublicationScope, filter, cursor string, limit int, now time.Time) (FeedPage, error) {
	started := time.Now()
	page := FeedPage{Response: EntryPage{Entries: []Entry{}}, MembershipUpdatedAt: now}
	if limit < 1 || limit > 100 || filter != "all" && filter != "read" && filter != "unread" {
		return page, errors.New("invalid scoped entry query")
	}
	ordered := append([]PublicationScope(nil), scopes...)
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].PublicationID < ordered[j].PublicationID })
	if len(ordered) == 0 {
		return page, nil
	}
	authors, unscoped, keys := []string{}, []string{}, []string{}
	for _, scope := range ordered {
		authors = append(authors, scope.AuthorDID)
		scopeKeys := PublicationSiteKeys(scope)
		if len(scopeKeys) == 0 {
			unscoped = append(unscoped, scope.AuthorDID)
		}
		keys = append(keys, scopeKeys...)
	}
	var position *EntryCursor
	if cursor != "" {
		parsed, err := DecodeEntryCursor(cursor)
		if err != nil {
			return page, err
		}
		position = &parsed
	}
	seen := map[string]bool{}
	batch := max(100, min(1000, limit*4))
	for len(page.Response.Entries) <= limit {
		at, uri := now, ""
		if position != nil {
			at, uri = position.CreatedAt, position.URI
		}
		rows, err := s.DB.QueryContext(ctx, `SELECT uri,author_did,publication_site,created_at,render_json::text FROM content_items WHERE author_did=ANY($1::text[]) AND expires_at>$2 AND (author_did=ANY($3::text[]) OR publication_site=ANY($4::text[])) AND ($5::boolean=FALSE OR (created_at,uri)<($6::timestamptz,$7::text)) ORDER BY created_at DESC,uri DESC LIMIT $8`, authors, now, unscoped, keys, position != nil, at, uri, batch)
		if err != nil {
			return page, err
		}
		items := []Entry{}
		count := 0
		for rows.Next() {
			var row ContentRow
			var author string
			if err := rows.Scan(&row.URI, &author, &row.PublicationSite, &row.CreatedAt, &row.RenderJSON); err != nil {
				rows.Close()
				return page, err
			}
			count++
			position = &EntryCursor{CreatedAt: row.CreatedAt, URI: row.URI}
			site := ""
			if row.PublicationSite != nil {
				site = *row.PublicationSite
			}
			for _, scope := range ordered {
				primary := ""
				if scope.PublicationATURI != nil {
					primary = *scope.PublicationATURI
				}
				if scope.AuthorDID != author || !thinappviewcore.MatchesPublication(site, primary, scope.PublicationScopeATURIs, scope.PublicationSiteURLs) {
					continue
				}
				entry, err := row.Entry()
				if err != nil {
					break
				}
				publication := scope.PublicationID
				entry.PublicationID = &publication
				items = append(items, entry)
				break
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return page, err
		}
		states, err := (ReadStateStore{DB: s.DB}).ReadStates(ctx, viewer, items)
		if err != nil {
			return page, err
		}
		for _, entry := range items {
			entry.IsRead = states[entry.EntryID]
			if filter == "read" && !entry.IsRead || filter == "unread" && entry.IsRead {
				continue
			}
			render := thinappviewcore.ContentRenderFields{Summary: entry.Summary, ArticleURL: entry.OriginalURL}
			identity := thinappviewcore.RSSDedupeKeys(entry.EntryID, render)
			if len(identity) == 0 {
				identity = []string{"uri:" + entry.EntryID}
			}
			duplicate := false
			for _, key := range identity {
				duplicate = duplicate || seen[key]
			}
			if duplicate {
				continue
			}
			for _, key := range identity {
				seen[key] = true
			}
			page.Response.Entries = append(page.Response.Entries, entry)
		}
		if len(page.Response.Entries) > limit {
			page.Response.Entries = page.Response.Entries[:limit]
			last := page.Response.Entries[limit-1]
			encoded := (EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
			page.Response.Cursor = &encoded
			break
		}
		if count < batch {
			break
		}
		if err := ctx.Err(); err != nil {
			return page, err
		}
	}
	page.DatabaseDuration = time.Since(started)
	return page, nil
}
