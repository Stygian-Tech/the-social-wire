package appviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"
)

type feedChunk struct {
	id                        int
	publication, author, site string
	items                     []feedMetadata
	more                      bool
	size                      int
	cursor                    *EntryCursor
}
type feedMetadata struct {
	ID          int64     `json:"id"`
	Source      int       `json:"source"`
	URI         string    `json:"uri"`
	At          time.Time `json:"at"`
	Publication string    `json:"publication"`
	Author      string    `json:"author"`
	Site        string    `json:"site"`
	Frontier    bool      `json:"frontier"`
}
type feedChunkRequestValue struct {
	ID     int       `json:"id"`
	Author string    `json:"author"`
	Site   string    `json:"site"`
	At     time.Time `json:"at"`
	URI    string    `json:"uri"`
	Size   int       `json:"size"`
}

func (s FeedStore) filteredFeed(ctx context.Context, viewer, kind, id, filter, cursor string, limit int, now time.Time) (*FeedPage, error) {
	started := time.Now()
	var position *EntryCursor
	if cursor != "" {
		parsed, err := DecodeEntryCursor(cursor)
		if err != nil {
			return nil, err
		}
		position = &parsed
	}
	scopes, updated, known, err := s.feedChunks(ctx, viewer, kind, id, limit, position)
	if err != nil || !known {
		return nil, err
	}
	page := &FeedPage{Response: EntryPage{Entries: []Entry{}}, MembershipUpdatedAt: updated}
	if err := s.refillChunks(ctx, scopes, now); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	accepted := 0
	batchSize := max(32, limit+1)
	for {
		chosen, err := s.mergeChunks(ctx, scopes, batchSize, now)
		if err != nil {
			return nil, err
		}
		if len(chosen) == 0 {
			break
		}
		for i := range chosen {
			chosen[i].ID = int64(i)
		}
		raw, err := json.Marshal(chosen)
		if err != nil {
			return nil, err
		}
		rows, err := s.DB.QueryContext(ctx, feedHydrateQuery, string(raw), viewer)
		if err != nil {
			return nil, err
		}
		byID := make(map[int64]feedMetadata, len(chosen))
		for _, item := range chosen {
			byID[item.ID] = item
		}
		winners := []feedMetadata{}
		reads := map[int64]bool{}
		for rows.Next() {
			var key sql.NullString
			var itemID int64
			var read bool
			if err := rows.Scan(&itemID, &key, &read); err != nil {
				rows.Close()
				return nil, err
			}
			if !key.Valid || accepted > limit || seen[key.String] {
				continue
			}
			seen[key.String] = true
			if filter == "unread" && read || filter == "read" && !read {
				continue
			}
			accepted++
			winners = append(winners, byID[itemID])
			reads[itemID] = read
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		if len(winners) > 0 {
			payloads, err := json.Marshal(winners)
			if err != nil {
				return nil, err
			}
			bodyRows, err := s.DB.QueryContext(ctx, feedPayloadQuery, string(payloads))
			if err != nil {
				return nil, err
			}
			for bodyRows.Next() {
				var itemID int64
				var render string
				if err := bodyRows.Scan(&itemID, &render); err != nil {
					bodyRows.Close()
					return nil, err
				}
				item := byID[itemID]
				entry, err := (ContentRow{URI: item.URI, CreatedAt: item.At, RenderJSON: []byte(render)}).Entry()
				if err != nil {
					continue
				}
				entry.PublicationID = &item.Publication
				entry.IsRead = reads[itemID]
				page.Response.Entries = append(page.Response.Entries, entry)
			}
			err = bodyRows.Err()
			bodyRows.Close()
			if err != nil {
				return nil, err
			}
		}
		if accepted > limit {
			break
		}
		consumed := make(map[int]int)
		for _, item := range chosen {
			consumed[item.Source]++
		}
		for source, count := range consumed {
			scopes[source].items = scopes[source].items[count:]
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		batchSize = min(512, batchSize*2)
	}
	if len(page.Response.Entries) > limit {
		page.Response.Entries = page.Response.Entries[:limit]
		last := page.Response.Entries[limit-1]
		encoded := (EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
		page.Response.Cursor = &encoded
	}
	page.DatabaseDuration = time.Since(started)
	return page, nil
}

func (s FeedStore) feedChunks(ctx context.Context, viewer, kind, id string, limit int, cursor *EntryCursor) ([]*feedChunk, time.Time, bool, error) {
	rows, err := s.DB.QueryContext(ctx, feedScopeQuery+` SELECT definition.updated_at,scope.publication_id,scope.author_did,scope.scope_key
 FROM feed_definition definition LEFT JOIN matching_scope_keys scope ON TRUE WHERE definition.updated_at IS NOT NULL`, limit, kind == "publication", viewer, kind, id)
	if err != nil {
		return nil, time.Time{}, false, err
	}
	defer rows.Close()
	var updated time.Time
	known := false
	scopes := []*feedChunk{}
	for rows.Next() {
		var publication, author, site sql.NullString
		if err := rows.Scan(&updated, &publication, &author, &site); err != nil {
			return nil, updated, false, err
		}
		known = true
		if !publication.Valid {
			continue
		}
		scopes = append(scopes, &feedChunk{id: len(scopes), publication: publication.String, author: author.String, site: site.String, more: true, size: 16, cursor: cursor})
	}
	return scopes, updated, known, rows.Err()
}

func (s FeedStore) refillChunks(ctx context.Context, scopes []*feedChunk, now time.Time) error {
	if len(scopes) == 0 {
		return nil
	}
	requests := make([]feedChunkRequestValue, 0, len(scopes))
	byID := map[int]*feedChunk{}
	// Every refill cohort shares cursor presence: initial external cursor, or
	// subsequent strict per-scope continuations. Empty scopes are never refilled.
	hasCursor := scopes[0].cursor != nil
	for _, scope := range scopes {
		request := feedChunkRequestValue{ID: scope.id, Author: scope.author, Site: scope.site, Size: scope.size, At: now}
		if scope.cursor != nil {
			request.At = scope.cursor.CreatedAt
			request.URI = scope.cursor.URI
		}
		requests = append(requests, request)
		byID[scope.id] = scope
	}
	raw, err := json.Marshal(requests)
	if err != nil {
		return err
	}
	query := feedChunkFirstQuery
	if hasCursor {
		query = feedChunkCursorQuery
	}
	rows, err := s.DB.QueryContext(ctx, query, string(raw), now)
	if err != nil {
		return err
	}
	defer rows.Close()
	counts := map[int]int{}
	for rows.Next() {
		var source int
		var item feedMetadata
		if err := rows.Scan(&source, &item.URI, &item.At, &item.Site); err != nil {
			return err
		}
		scope := byID[source]
		item.Author = scope.author
		item.Source = source
		item.Publication = scope.publication
		scope.items = append(scope.items, item)
		scope.cursor = &EntryCursor{CreatedAt: item.At, URI: item.URI}
		counts[source]++
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, scope := range scopes {
		scope.more = counts[scope.id] == scope.size
		scope.size = min(512, scope.size*2)
	}
	return nil
}

func (s FeedStore) mergeChunks(ctx context.Context, scopes []*feedChunk, size int, now time.Time) ([]feedMetadata, error) {
	for {
		items := []feedMetadata{}
		for _, scope := range scopes {
			for i, item := range scope.items {
				item.ID = int64(len(items))
				item.Frontier = scope.more && i == len(scope.items)-1
				items = append(items, item)
			}
		}
		if len(items) == 0 {
			return nil, nil
		}
		raw, err := json.Marshal(items)
		if err != nil {
			return nil, err
		}
		rows, err := s.DB.QueryContext(ctx, feedMergeQuery, string(raw), size)
		if err != nil {
			return nil, err
		}
		chosen := []feedMetadata{}
		needed := map[int]bool{}
		for rows.Next() {
			var itemID int64
			var source int
			var frontier bool
			if err := rows.Scan(&itemID, &source, &frontier); err != nil {
				rows.Close()
				return nil, err
			}
			chosen = append(chosen, items[itemID])
			if frontier {
				needed[source] = true
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return nil, err
		}
		if len(needed) == 0 {
			return chosen, nil
		}
		refill := make([]*feedChunk, 0, len(needed))
		for source := range needed {
			refill = append(refill, scopes[source])
		}
		if err := s.refillChunks(ctx, refill, now); err != nil {
			return nil, err
		}
	}
}
