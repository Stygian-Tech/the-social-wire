package appviewcore

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"testing"
	"time"
)

// Run against disposable C and en_US-default databases to verify that SQL's
// native ordering is preserved. Unique authors keep fixture rows isolated while
// exercising the real content-to-article-identity projection trigger.
func TestFeedMergeMatchesSQLOracleUnderDatabaseCollation(t *testing.T) {
	db := fixtureDatabase(t)
	db.SetMaxOpenConns(1)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:collated-feed-%d", time.Now().UnixNano())
	author := viewer + "-author"
	publication := "at://" + author + "/site.standard.publication/main"
	at := time.Now().UTC().Truncate(time.Second)
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := db.ExecContext(ctx, query, args...); err != nil {
			t.Fatal(err)
		}
	}
	var locale string
	if err := db.QueryRow(`SELECT datcollate FROM pg_database WHERE datname=current_database()`).Scan(&locale); err != nil {
		t.Fatal(err)
	}
	t.Logf("database collation: %s", locale)
	t.Cleanup(func() {
		for _, table := range []string{"read_marks", "appview_unread_overrides", "appview_publication_read_floors", "appview_publication_scopes", "appview_viewer_feeds"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec("DELETE FROM content_items WHERE author_did=$1", author)
	})
	exec(`INSERT INTO appview_viewer_feeds VALUES($1,'subscribed','',$2)`, viewer, at)
	// Separate scoped streams share timestamps and interleave under SQL collation.
	for _, suffix := range []string{"main", "other"} {
		pub := "at://" + author + "/site.standard.publication/" + suffix
		exec(`INSERT INTO appview_publication_scopes(viewer_did,publication_id,author_did,publication_at_uri,scope_keys,updated_at) VALUES($1,$2,$3,$2,jsonb_build_array($2::text),$4)`, viewer, pub, author, at)
		exec(`INSERT INTO appview_feed_publications VALUES($1,'subscribed','',$2)`, viewer, pub)
	}
	rkeys := []string{"a", "A", "a-1", "a_1", "a.1", "a1", "a01", "a2", "a10", "Z", "z"}
	for i := 0; i < 132; i++ {
		uri := fmt.Sprintf("at://%s/site.standard.document/%s-%03d", author, rkeys[i%len(rkeys)], i)
		pub := publication
		if i%2 != 0 {
			pub = "at://" + author + "/site.standard.publication/other"
		}
		article := fmt.Sprintf("https://collated.invalid/article/%d", i)
		if i%5 == 0 {
			article = "https://collated.invalid/shared"
		}
		render := `{"title":"Article","articleUrl":"` + article + `"}`
		if i%29 == 0 {
			render = `{"title":42,"articleUrl":"` + article + `"}`
		}
		exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at) VALUES($1,'fixture',$2,'site.standard.document',$3,$3,$4,$5::jsonb,$3::timestamptz+interval '1 hour')`, uri, author, at, pub, render)
		if i%3 == 0 {
			exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, uri, at)
		}
	}
	// Locale names do not establish sort behavior across platform providers.
	// Compare the actual PostgreSQL order with Go's byte order; the full feed
	// oracle below runs in either case, including byte-ordered CI databases.
	rows, err := db.QueryContext(ctx, `SELECT uri FROM content_items WHERE author_did=$1 ORDER BY uri`, author)
	if err != nil {
		t.Fatal(err)
	}
	var databaseOrder []string
	for rows.Next() {
		var uri string
		if err := rows.Scan(&uri); err != nil {
			rows.Close()
			t.Fatal(err)
		}
		databaseOrder = append(databaseOrder, uri)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		t.Fatal(err)
	}
	byteOrder := append([]string(nil), databaseOrder...)
	sort.Strings(byteOrder)
	t.Logf("fixture PostgreSQL ordering differs from Go byte ordering: %t", !reflect.DeepEqual(databaseOrder, byteOrder))

	compareWithOracle := func(t *testing.T) {
		for _, filter := range []string{"all", "read", "unread"} {
			for _, limit := range []int{1, 7, 33} {
				t.Run(fmt.Sprintf("%s/limit%d", filter, limit), func(t *testing.T) {
					cursor := ""
					for pageIndex := 0; pageIndex < 140; pageIndex++ {
						page, err := (FeedStore{DB: db}).Feed(ctx, viewer, "subscribed", "", filter, cursor, limit, at)
						if err != nil {
							t.Fatal(err)
						}
						expected := referenceFeed(t, db, viewer, filter, cursor, limit, at)
						if page == nil || !reflect.DeepEqual(page.Response, expected.Response) {
							t.Fatalf("page %d differs from SQL oracle: got %#v want %#v", pageIndex, page, expected)
						}
						if page.Response.Cursor == nil {
							return
						}
						if *page.Response.Cursor == cursor {
							t.Fatal("cursor did not advance")
						}
						cursor = *page.Response.Cursor
					}
					t.Fatal("feed did not exhaust")
				})
			}
		}
	}
	t.Run("disjoint_scopes", compareWithOracle)
	t.Run("same_publication_exact_and_wildcard", func(t *testing.T) {
		// The same content is encountered twice for the exact site and once for
		// other sites. Publication attribution is unambiguous, so compare every
		// response field to the old SQL oracle without relaxing equality.
		exec(`DELETE FROM appview_feed_publications WHERE viewer_did=$1 AND publication_id<>$2`, viewer, publication)
		exec(`UPDATE appview_publication_scopes SET scope_keys=jsonb_build_array($2::text,'') WHERE viewer_did=$1 AND publication_id=$2`, viewer, publication)
		compareWithOracle(t)
	})
	t.Run("different_publication_floors_and_explicit_override", func(t *testing.T) {
		other := "at://" + author + "/site.standard.publication/other"
		exec(`INSERT INTO appview_feed_publications VALUES($1,'subscribed','',$2)`, viewer, other)
		exec(`DELETE FROM content_items WHERE author_did=$1`, author)
		exec(`DELETE FROM read_marks WHERE viewer_did=$1`, viewer)
		exec(`INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,generation) VALUES($1,$2,$4::timestamptz-interval '1 hour',1),($1,$3,$4::timestamptz+interval '1 hour',1)`, viewer, publication, other, at)
		newest := "at://" + author + "/site.standard.document/newest"
		older := "at://" + author + "/site.standard.document/older"
		exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at) VALUES
($1,'fixture',$3,'site.standard.document',$4,$4,$5,'{"title":"Newest","articleUrl":"https://collated.invalid/same"}'::jsonb,$4::timestamptz+interval '1 hour'),
($2,'fixture',$3,'site.standard.document',$4::timestamptz-interval '1 second',$4,$6,'{"title":"Older","articleUrl":"https://collated.invalid/same"}'::jsonb,$4::timestamptz+interval '1 hour')`, newest, older, author, at, other, publication)
		exec(`INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, older, at)
		assertPages := func(read bool) {
			t.Helper()
			for _, filter := range []string{"all", "read", "unread"} {
				page, err := (FeedStore{DB: db}).Feed(ctx, viewer, "subscribed", "", filter, "", 5, at)
				if err != nil || page == nil {
					t.Fatalf("%s: page=%#v error=%v", filter, page, err)
				}
				want := 1
				if filter == "read" && !read || filter == "unread" && read {
					want = 0
				}
				if len(page.Response.Entries) != want || page.Response.Cursor != nil {
					t.Fatalf("%s: expected %d entries without cursor, got %#v", filter, want, page.Response)
				}
				if want == 1 {
					entry := page.Response.Entries[0]
					if entry.EntryID != newest || entry.IsRead != read || entry.PublicationID == nil || *entry.PublicationID != other {
						t.Fatalf("%s: wrong URI, read flag, or descending-publication winner: %#v", filter, entry)
					}
				}
			}
		}
		// A single URI is in both publications. DESC publication chooses the
		// read floor of "other" before filtering. Its read winner masks the older
		// unread article copy; filtering before dedupe would resurrect that copy.
		assertPages(true)
		exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, newest, at)
		exec(`INSERT INTO appview_unread_overrides(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, newest, at)
		// Explicit unread wins both the selected read floor and a legacy mark.
		assertPages(false)
	})
}
