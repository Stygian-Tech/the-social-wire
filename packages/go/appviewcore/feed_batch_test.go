package appviewcore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestFeedBatchesPreserveGlobalDedupeFiltersAndCursor(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:batch-%d", time.Now().UnixNano())
	author := viewer + "-author"
	publication := "at://" + author + "/site.standard.publication/a"
	at := time.Now().UTC().Truncate(time.Second)
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_publication_scopes", "appview_viewer_feeds"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec("DELETE FROM content_items WHERE author_did=$1", author)
	})
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.ExecContext(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`INSERT INTO appview_viewer_feeds VALUES($1,'subscribed','',$2)`, viewer, at)
	exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,scope_keys,updated_at) VALUES($1,$2,$3,$2,jsonb_build_array($2::text),$4)`, viewer, publication, author, at)
	exec(`INSERT INTO appview_feed_publications VALUES($1,'subscribed','',$2)`, viewer, publication)
	// The newest duplicate is read; hundreds of its older copies are unread.
	// A subsequent read-only run crosses several batches before unique unread rows.
	exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at)
 SELECT 'at://'||$1||'/site.standard.document/'||i,'fixture',$1,'site.standard.document',
 $3::timestamptz-i*interval '1 second',$3,$2,
 jsonb_build_object('title','Article '||i,'publishedAt',$3::text,'articleUrl',CASE WHEN i<=400 THEN 'https://fixture.invalid/duplicate' ELSE 'https://fixture.invalid/'||i END),$3::timestamptz+interval '1 hour'
 FROM generate_series(1,900)i`, author, publication, at)
	exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) SELECT $1,uri,$3 FROM content_items WHERE author_did=$2 AND ((render_json->>'title')='Article 1' OR substring(uri from '[0-9]+$')::int BETWEEN 401 AND 800)`, viewer, author, at)
	for _, filter := range []string{"all", "unread", "read"} {
		t.Run(filter, func(t *testing.T) {
			cursor := ""
			for pageIndex := 0; pageIndex < 3; pageIndex++ {
				page, err := (FeedStore{DB: db}).Feed(ctx, viewer, "subscribed", "", filter, cursor, 17, at)
				if err != nil {
					t.Fatal(err)
				}
				expected := referenceFeed(t, db, viewer, filter, cursor, 17, at)
				if page == nil || len(page.Response.Entries) != len(expected.Response.Entries) {
					t.Fatalf("page size differs: %#v %#v", page, expected)
				}
				for i, entry := range expected.Response.Entries {
					if page.Response.Entries[i].EntryID != entry.EntryID || page.Response.Entries[i].IsRead != entry.IsRead {
						t.Fatalf("entry %d differs: %#v %#v", i, page.Response.Entries[i], entry)
					}
				}
				if (page.Response.Cursor == nil) != (expected.Response.Cursor == nil) {
					t.Fatal("cursor presence differs")
				}
				if page.Response.Cursor == nil {
					break
				}
				if *page.Response.Cursor != *expected.Response.Cursor {
					t.Fatal("cursor differs")
				}
				cursor = *page.Response.Cursor
			}
		})
	}
	// Every candidate is now read. Exhaustion must finish, not invent a cap/cursor.
	exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) SELECT $1,uri,$3 FROM content_items WHERE author_did=$2 ON CONFLICT DO NOTHING`, viewer, author, at)
	deadline, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	empty, err := (FeedStore{DB: db}).Feed(deadline, viewer, "subscribed", "", "unread", "", 17, at)
	if err != nil || empty == nil || len(empty.Response.Entries) != 0 || empty.Response.Cursor != nil {
		t.Fatalf("empty exhaustion: %#v %v", empty, err)
	}
	// A large unrelated publication must not be scanned to fetch this scope.
	exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at)
 SELECT 'at://'||$1||'/site.standard.document/unrelated-'||i,'fixture',$1,'site.standard.document',
 $3::timestamptz-i*interval '1 second',$3,$2,'{}'::jsonb,$3::timestamptz+interval '1 hour'
 FROM generate_series(1,20000)i`, author, publication+"-unrelated", at)
	// Physical plan assertions use representative statistics, independent of
	// autovacuum timing in the disposable fixture.
	for _, table := range []string{"content_items", "appview_publication_scopes", "appview_publication_scope_keys", "appview_feed_publications", "read_marks"} {
		exec("ANALYZE " + table)
	}
	exec("VACUUM (ANALYZE) content_items")
	// The candidate stage uses ordered index seeks capped before payload hydration.
	rows, err := db.QueryContext(ctx, "EXPLAIN (ANALYZE,BUFFERS,TIMING OFF) "+feedBatchQuery, 128, false, viewer, "subscribed", "", at, false, at, "", "", false)
	if err != nil {
		t.Fatal(err)
	}
	var plan strings.Builder
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		plan.WriteString(line)
		plan.WriteByte('\n')
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plan.String(), "idx_content_items_author_site_feed_cover") || strings.Contains(plan.String(), "Seq Scan on content_items") || !strings.Contains(plan.String(), "Limit") {
		t.Fatalf("missing bounded index seeks:\n%s", plan.String())
	}
	t.Log(plan.String())
	var rawPlan []byte
	if err := db.QueryRowContext(ctx, "EXPLAIN (ANALYZE,FORMAT JSON,TIMING OFF) "+feedBatchQuery, 51, false, viewer, "subscribed", "", at, false, at, "", "", false).Scan(&rawPlan); err != nil {
		t.Fatal(err)
	}
	var document []map[string]any
	if err := json.Unmarshal(rawPlan, &document); err != nil {
		t.Fatal(err)
	}
	found := false
	var visit func(map[string]any)
	visit = func(node map[string]any) {
		if node["Index Name"] == "idx_content_items_author_site_feed_cover" {
			found = true
			// Other package fixtures can hold older snapshots during VACUUM.
			// Even then, heap visibility checks must stay within this batch.
			if node["Node Type"] != "Index Only Scan" || node["Heap Fetches"].(float64) > 51 {
				t.Fatalf("candidate scan fetched history beyond its batch: %s", rawPlan)
			}
		}
		if children, ok := node["Plans"].([]any); ok {
			for _, child := range children {
				visit(child.(map[string]any))
			}
		}
	}
	visit(document[0]["Plan"].(map[string]any))
	if !found {
		t.Fatalf("covering candidate index not used: %s", rawPlan)
	}
}

func referenceFeed(t *testing.T, db *sql.DB, viewer, filter, cursor string, limit int, at time.Time) *FeedPage {
	t.Helper()
	position, uri := at, ""
	if cursor != "" {
		parsed, err := DecodeEntryCursor(cursor)
		if err != nil {
			t.Fatal(err)
		}
		position, uri = parsed.CreatedAt, parsed.URI
	}
	selection, ranking, source := "", "ROW_NUMBER() OVER (PARTITION BY content.article_key ORDER BY content.created_at DESC,content.uri DESC)", "matched_content"
	if filter == "all" {
		selection, ranking, source = feedSelectionAll, "1", "selected_content"
	}
	rows, err := db.QueryContext(context.Background(), fmt.Sprintf(feedQuery, selection, ranking, source), limit+1, false, viewer, "subscribed", "", at, cursor != "", position, uri, filter == "all", filter == "unread", filter == "read")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	page := &FeedPage{Response: EntryPage{Entries: []Entry{}}}
	for rows.Next() {
		var updated time.Time
		var uri, render, pub sql.NullString
		var created sql.NullTime
		var read sql.NullBool
		if err := rows.Scan(&updated, &uri, &render, &created, &pub, &read); err != nil {
			t.Fatal(err)
		}
		page.MembershipUpdatedAt = updated
		if !uri.Valid {
			continue
		}
		entry, err := (ContentRow{URI: uri.String, CreatedAt: created.Time, RenderJSON: []byte(render.String)}).Entry()
		if err != nil {
			continue
		}
		entry.PublicationID = &pub.String
		entry.IsRead = read.Bool
		page.Response.Entries = append(page.Response.Entries, entry)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(page.Response.Entries) > limit {
		page.Response.Entries = page.Response.Entries[:limit]
		last := page.Response.Entries[limit-1]
		encoded := (EntryCursor{CreatedAt: last.FeedPositionAt, URI: last.EntryID}).Encode()
		page.Response.Cursor = &encoded
	}
	return page
}

func TestFeedBatchCursorTraversesSameURIInManyPublications(t *testing.T) {
	db := fixtureDatabase(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:batch-tie-%d", time.Now().UnixNano())
	author := viewer + "-author"
	at := time.Now().UTC().Truncate(time.Second)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.ExecContext(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		for _, table := range []string{"appview_publication_scopes", "appview_viewer_feeds"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec("DELETE FROM content_items WHERE author_did=$1", author)
	})
	exec(`INSERT INTO appview_viewer_feeds VALUES($1,'subscribed','',$2)`, viewer, at)
	exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,scope_keys,updated_at) SELECT $1,'pub-'||i,$2,'["site"]'::jsonb,$3 FROM generate_series(1,140)i`, viewer, author, at)
	exec(`INSERT INTO appview_feed_publications SELECT $1,'subscribed','',publication_id FROM appview_publication_scopes WHERE viewer_did=$1`, viewer)
	exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at) SELECT 'at://'||$1||'/site.standard.document/'||i,'fixture',$1,'site.standard.document',$2::timestamptz-i*interval '1 second',$2,'site',jsonb_build_object('title','Entry '||i),$2::timestamptz+interval '1 hour' FROM generate_series(1,3)i`, author, at)
	page, err := (FeedStore{DB: db}).Feed(ctx, viewer, "subscribed", "", "all", "", 2, at)
	if err != nil || page == nil || len(page.Response.Entries) != 2 || page.Response.Cursor == nil {
		t.Fatalf("same URI batches: %#v %v", page, err)
	}
	next, err := (FeedStore{DB: db}).Feed(ctx, viewer, "subscribed", "", "all", *page.Response.Cursor, 2, at)
	if err != nil || next == nil || len(next.Response.Entries) != 1 || next.Response.Cursor != nil {
		t.Fatalf("same URI continuation: %#v %v", next, err)
	}
	// Malformed render values count toward the SQL page limit before decoding.
	exec(`UPDATE content_items SET render_json='{"title":42}'::jsonb WHERE author_did=$1 AND uri LIKE '%/1'`, author)
	page, err = (FeedStore{DB: db}).Feed(ctx, viewer, "subscribed", "", "all", "", 1, at)
	if err != nil || page == nil || len(page.Response.Entries) != 1 || page.Response.Cursor != nil || !strings.HasSuffix(page.Response.Entries[0].EntryID, "/2") {
		t.Fatalf("malformed render changed page semantics: %#v %v", page, err)
	}
}
