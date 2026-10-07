package appviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type UnreadMutationEntry struct {
	EntryID                     string
	PublishedAt, FeedPositionAt time.Time
	PublicationID               string
}
type UnreadMutationPage struct {
	Entries []UnreadMutationEntry
	Cursor  *string
}
type mutationScope struct {
	PublicationID string   `json:"publicationId"`
	AuthorDID     string   `json:"authorDid"`
	ScopeKeys     []string `json:"scopeKeys"`
	Position      int      `json:"position"`
	Unscoped      bool     `json:"unscoped"`
}

func (s ContentReader) UnreadSnapshot(ctx context.Context, viewer string, scopes []PublicationScope, cursor string, limit int, now time.Time) (UnreadMutationPage, error) {
	page := UnreadMutationPage{Entries: []UnreadMutationEntry{}}
	if limit < 1 || limit > 1000 {
		return page, errors.New("invalid unread snapshot limit")
	}
	if len(scopes) == 0 {
		return page, nil
	}
	ordered := append([]PublicationScope(nil), scopes...)
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].PublicationID < ordered[j].PublicationID })
	authors, unscoped, keys := []string{}, []string{}, []string{}
	broad, specific := map[string]bool{}, map[string]bool{}
	for _, scope := range ordered {
		authors = append(authors, scope.AuthorDID)
		scopeKeys := PublicationSiteKeys(scope)
		keys = append(keys, scopeKeys...)
		if len(scopeKeys) == 0 {
			unscoped = append(unscoped, scope.AuthorDID)
			broad[scope.AuthorDID] = true
		} else {
			specific[scope.AuthorDID] = true
		}
	}
	additional := []string{}
	overlap := []string{}
	for author := range broad {
		if specific[author] {
			overlap = append(overlap, author)
		}
	}
	if len(overlap) > 0 {
		rows, err := s.DB.QueryContext(ctx, `SELECT DISTINCT publication_site FROM content_items WHERE author_did=ANY($1::text[]) AND expires_at>$2 AND publication_site IS NOT NULL`, overlap, now)
		if err != nil {
			return page, err
		}
		for rows.Next() {
			var site string
			if err := rows.Scan(&site); err != nil {
				rows.Close()
				return page, err
			}
			additional = append(additional, site)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return page, err
		}
	}
	candidates := map[string]bool{}
	for _, site := range append(append([]string{}, keys...), additional...) {
		candidates[site] = true
	}
	requests := []mutationScope{}
	for position, scope := range ordered {
		matched := []string{}
		primary := ""
		if scope.PublicationATURI != nil {
			primary = *scope.PublicationATURI
		}
		for candidate := range candidates {
			if thinappviewcore.MatchesPublication(candidate, primary, scope.PublicationScopeATURIs, scope.PublicationSiteURLs) {
				matched = append(matched, candidate)
			}
		}
		sort.Strings(matched)
		requests = append(requests, mutationScope{scope.PublicationID, scope.AuthorDID, matched, position, len(PublicationSiteKeys(scope)) == 0})
	}
	material, err := json.Marshal(requests)
	if err != nil {
		return page, err
	}
	at, uri := now, ""
	if cursor != "" {
		position, err := DecodeEntryCursor(cursor)
		if err != nil {
			return page, err
		}
		at, uri = position.CreatedAt, position.URI
	}
	rows, err := s.DB.QueryContext(ctx, unreadSnapshotSQL, string(material), viewer, authors, unscoped, keys, now, cursor != "", at, uri, limit+1)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	for rows.Next() {
		var entry UnreadMutationEntry
		var published sql.NullString
		if err := rows.Scan(&entry.EntryID, &entry.FeedPositionAt, &published, &entry.PublicationID); err != nil {
			return page, err
		}
		entry.PublishedAt = entry.FeedPositionAt
		if published.Valid {
			if parsed, err := time.Parse(time.RFC3339Nano, published.String); err == nil {
				entry.PublishedAt = parsed
			}
		}
		page.Entries = append(page.Entries, entry)
	}
	if err := rows.Err(); err != nil {
		return page, err
	}
	if len(page.Entries) > limit {
		page.Entries = page.Entries[:limit]
		last := page.Entries[limit-1]
		encoded := (EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
		page.Cursor = &encoded
	}
	return page, nil
}

const unreadSnapshotSQL = `WITH requested_scopes AS (
 SELECT * FROM jsonb_to_recordset($1::jsonb) AS s("publicationId" text,"authorDid" text,"scopeKeys" jsonb,position integer,unscoped boolean))
 SELECT ci.uri,ci.created_at,ci.render_json->>'publishedAt',scope."publicationId"
 FROM content_items ci JOIN LATERAL (
 SELECT s."publicationId" FROM requested_scopes s WHERE s."authorDid"=ci.author_did
 AND (s.unscoped OR s."scopeKeys" ? ci.publication_site) ORDER BY s.position LIMIT 1) scope ON TRUE
 LEFT JOIN appview_publication_read_floors floor ON floor.viewer_did=$2 AND floor.publication_id=scope."publicationId"
 LEFT JOIN read_marks rm ON rm.viewer_did=$2 AND rm.subject_uri=ci.uri
 LEFT JOIN appview_unread_overrides uo ON uo.viewer_did=$2 AND uo.subject_uri=ci.uri
 LEFT JOIN LATERAL appview_effective_entry_read_state($2,ci.uri,ci.author_did,ci.publication_site,ci.created_at,rm.subject_uri,uo.subject_uri) read_state ON TRUE
 WHERE ci.author_did=ANY($3::text[]) AND (ci.author_did=ANY($4::text[]) OR ci.publication_site=ANY($5::text[]))
 AND ci.expires_at>$6 AND read_state.read_uri IS NULL
 AND (floor.read_floor_at IS NULL OR ci.created_at>floor.read_floor_at
 OR (floor.read_floor_uri IS NOT NULL AND ci.created_at=floor.read_floor_at AND ci.uri>floor.read_floor_uri) OR read_state.unread_uri IS NOT NULL)
 AND ($7::boolean=FALSE OR ci.created_at<$8 OR (ci.created_at=$8 AND ci.uri<$9))
 ORDER BY ci.created_at DESC,ci.uri DESC LIMIT $10`
