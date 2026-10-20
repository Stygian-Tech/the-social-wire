package publicationcore

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func TestEnrollmentCounterRowsSelectRequestedSourcesForViewer(t *testing.T) {
	s := NewService(nil, nil, nil)
	defer s.Close()
	row := func(id, author string, sites ...string) SidebarRow {
		return SidebarRow{PublicationID: id, AuthorDID: author, AppViewScope: AppViewScope{AuthorDID: author, PublicationSiteURLs: sites}}
	}
	a := row("a", "did:plc:author")
	s.rows["viewer"] = map[string]SidebarRow{
		"a": a, "encoded-alias": a,
		"b":         row("b", "did:plc:author"),
		"other":     row("other", "did:plc:other", "https://feed.invalid/rss"),
		"rss":       row("rss", thinappviewcore.RSSAuthorDID, "https://feed.invalid/rss"),
		"rss-other": row("rss-other", thinappviewcore.RSSAuthorDID, "https://other.invalid/rss"),
	}
	s.rows["another-viewer"] = map[string]SidebarRow{"private": row("private", "did:plc:author")}
	for _, test := range []struct {
		name                 string
		authors, feeds, want []string
	}{
		{"authors", []string{" did:plc:author ", "did:plc:author", thinappviewcore.RSSAuthorDID}, nil, []string{"a", "b"}},
		{"feeds", nil, []string{" http://user:pass@feed.invalid/rss/#fragment ", "https://feed.invalid/rss"}, []string{"rss"}},
		{"combined", []string{"did:plc:author"}, []string{"https://feed.invalid/rss"}, []string{"a", "b", "rss"}},
		{"rss author alone", []string{thinappviewcore.RSSAuthorDID}, nil, []string{}},
		{"empty", nil, nil, []string{}},
		{"unknown", []string{"did:plc:unknown"}, []string{"https://unknown.invalid/rss"}, []string{}},
	} {
		t.Run(test.name, func(t *testing.T) {
			rows, err := s.enrollmentCounterRows(context.Background(), "viewer", test.authors, test.feeds)
			if err != nil {
				t.Fatal(err)
			}
			got := []string{}
			for _, row := range rows {
				got = append(got, row.PublicationID)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("selected %v, want %v", got, test.want)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := s.RefreshEnrollmentCounters(ctx, "viewer", nil, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation lost: %v", err)
	}
}

func TestRefreshEnrollmentCountersRecountsAndCachesAcrossReplicas(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Second)
	viewer := fmt.Sprintf("did:plc:enrollment%d", time.Now().UnixNano())
	otherViewer, author := viewer+"other", viewer+"author"
	feed := "https://" + viewer[len("did:plc:"):] + ".invalid/rss"
	otherFeed := feed + "-other"
	row := func(id, did, site string) SidebarRow {
		return SidebarRow{PublicationID: id, AuthorDID: did, AppViewScope: AppViewScope{AuthorDID: did, PublicationScopeATURIs: []string{}, PublicationSiteURLs: []string{site}}}
	}
	a, rss, outside := row("author", author, "https://author.invalid"), row("rss", thinappviewcore.RSSAuthorDID, feed), row("outside", thinappviewcore.RSSAuthorDID, otherFeed)
	cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
	t.Cleanup(func() {
		for _, who := range []string{viewer, otherViewer} {
			for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes", "appview_unread_counters", "unread_counts_cache"} {
				db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", who)
			}
		}
		db.Exec(`DELETE FROM content_items WHERE author_did=$1 OR publication_site=$2 OR publication_site=$3`, author, feed, otherFeed)
	})
	if err := (ProjectionStore{DB: db}).Persist(ctx, Sidebar{ViewerDID: viewer, AllPublicationRows: []SidebarRow{a, rss, outside}}, true); err != nil {
		t.Fatal(err)
	}
	if err := (ProjectionStore{DB: db}).Persist(ctx, Sidebar{ViewerDID: otherViewer, AllPublicationRows: []SidebarRow{row("private", author, "https://author.invalid")}}, true); err != nil {
		t.Fatal(err)
	}
	for _, who := range []string{viewer, otherViewer} {
		if err := cache.storeUnread(ctx, who, map[string]int{"author": 17, "rss": 17, "outside": 17}, at); err != nil {
			t.Fatal(err)
		}
		for _, id := range []string{"author", "rss", "outside"} {
			if _, err := db.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at) VALUES($1,$2,17,1,'exact',FALSE,$3)`, who, id, at); err != nil {
				t.Fatal(err)
			}
		}
	}
	for i, r := range []SidebarRow{a, rss, outside} {
		site := r.AppViewScope.PublicationSiteURLs[0]
		item := thinappviewcore.IndexedContentItem{URI: fmt.Sprintf("at://%s/site.standard.document/%s-%d", r.AuthorDID, viewer, i), CID: "fixture", AuthorDID: r.AuthorDID, Collection: "site.standard.document", CreatedAt: at, IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &site, Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: at.Format(time.RFC3339)}}
		if err := (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, item); err != nil {
			t.Fatal(err)
		}
	}
	// A contended lease must not turn enrollment into a stale snapshot read.
	lease, err := cache.Projection.AcquireRefreshLease(ctx, "unread", viewer, time.Minute)
	if err != nil || lease == nil {
		t.Fatalf("lease: %v %v", lease, err)
	}
	defer cache.Projection.ReleaseRefreshLease(ctx, *lease)
	s := NewService(db, nil, nil) // This replica has no process sidebar rows.
	defer s.Close()
	s.Cache = &cache
	s.Now = func() time.Time { return at.Add(time.Second) }
	if err := s.RefreshEnrollmentCounters(ctx, viewer, []string{author, thinappviewcore.RSSAuthorDID}, []string{feed + "/#fragment"}); err != nil {
		t.Fatal(err)
	}
	for _, who := range []string{viewer, otherViewer} {
		counts, _, _, err := cache.unread(ctx, who, []string{"author", "rss", "outside", "private"}, s.Now())
		if err != nil {
			t.Fatal(err)
		}
		want := map[string]int{"author": 17, "rss": 17, "outside": 17}
		if who == viewer {
			want["author"], want["rss"] = 1, 1
		}
		if !reflect.DeepEqual(counts, want) {
			t.Fatalf("viewer %s cache %v, want %v", who, counts, want)
		}
		for id, n := range want {
			var actual int
			if err := db.QueryRow(`SELECT unread_count FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=$2`, who, id).Scan(&actual); err != nil || actual != n {
				t.Fatalf("viewer %s counter %s = %d, want %d: %v", who, id, actual, n, err)
			}
		}
	}
	// Cache persistence is part of successful enrollment, not best effort.
	brokenDB := fixtureDB(t)
	brokenDB.Close()
	s.Cache = &CacheStore{Projection: thinappviewcore.ProjectionCache{DB: brokenDB}}
	if err := s.RefreshEnrollmentCounters(ctx, viewer, []string{author}, nil); err == nil {
		t.Fatal("cache write failure reported success")
	}
}
