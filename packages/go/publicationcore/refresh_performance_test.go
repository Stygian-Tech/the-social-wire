package publicationcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"reflect"
	"sync"
	"testing"
	"time"
)

type refreshLookupRepo struct {
	repoFixture
	mu                 sync.Mutex
	active, peak, gets int
	lists              map[string]int
	started            chan string
	release            <-chan struct{}
}

func (r *refreshLookupRepo) GetRecord(ctx context.Context, did, col, key, cid string) (*gatewaycore.RepoRecord, error) {
	r.mu.Lock()
	r.active++
	r.gets++
	r.peak = max(r.peak, r.active)
	r.mu.Unlock()
	defer func() { r.mu.Lock(); r.active--; r.mu.Unlock() }()
	if r.started != nil {
		r.started <- key
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return r.repoFixture.GetRecord(ctx, did, col, key, cid)
}
func (r *refreshLookupRepo) ListRecords(ctx context.Context, did, col, cursor string, limit int, reverse bool) (gatewaycore.RepoPage, error) {
	r.mu.Lock()
	if r.lists == nil {
		r.lists = map[string]int{}
	}
	r.lists[col]++
	r.mu.Unlock()
	return r.repoFixture.ListRecords(ctx, did, col, cursor, limit, reverse)
}
func refreshFixture(count int) repoFixture {
	r := repoFixture{records: map[string]gatewaycore.RepoRecord{}, pages: map[string][]gatewaycore.RepoRecord{}}
	for i := 0; i < count; i++ {
		id := fmt.Sprintf("at://did:plc:author/site.standard.publication/%03d", i)
		r.records[id] = record(id, map[string]any{"title": fmt.Sprintf("Title %03d", count-i), "url": "https://fresh.invalid/"})
		r.pages["viewer/site.standard.graph.subscription"] = append(r.pages["viewer/site.standard.graph.subscription"], record(fmt.Sprint(i), map[string]any{"publication": id}))
	}
	return r
}
func awaitLookup(t *testing.T, started <-chan string) {
	t.Helper()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("lookup workers did not start")
	}
}
func TestDiscoverBoundedSubscriptionLookups(t *testing.T) {
	gate := make(chan struct{})
	r := &refreshLookupRepo{repoFixture: refreshFixture(77), started: make(chan string, 77), release: gate}
	r.pages["viewer/site.standard.graph.subscription"] = append(r.pages["viewer/site.standard.graph.subscription"], r.pages["viewer/site.standard.graph.subscription"][0])
	done := make(chan struct{})
	var found DiscoveryContext
	var err error
	go func() {
		defer close(done)
		found, err = Discover(context.Background(), r, nil, "viewer", false, nil, time.Unix(100, 0))
	}()
	for i := 0; i < subscriptionResolutionConcurrency; i++ {
		awaitLookup(t, r.started)
	}
	r.mu.Lock()
	if r.active != 25 || r.gets != 25 {
		t.Errorf("dispatch exceeded bound: active=%d gets=%d", r.active, r.gets)
	}
	r.mu.Unlock()
	close(gate)
	<-done
	if err != nil || len(found.Subscribed) != 77 || r.peak != 25 || r.gets != 77 || r.active != 0 {
		t.Fatalf("rows=%d peak=%d gets=%d active=%d err=%v", len(found.Subscribed), r.peak, r.gets, r.active, err)
	}
	for i, row := range found.Subscribed {
		if row.Title != fmt.Sprintf("Title %03d", i+1) {
			t.Fatalf("nondeterministic title order at %d: %q", i, row.Title)
		}
	}
	for i, row := range found.UniqueRows {
		if row.PublicationID != fmt.Sprintf("at://did:plc:author/site.standard.publication/%03d", i) {
			t.Fatalf("nondeterministic ID order at %d: %q", i, row.PublicationID)
		}
	}
}
func TestDiscoverCancelsAndJoinsSubscriptionLookups(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := &refreshLookupRepo{repoFixture: refreshFixture(77), started: make(chan string, 77), release: make(chan struct{})}
	s := NewService(nil, r, nil)
	defer s.Close()
	done := make(chan error, 1)
	go func() { _, err := s.Refresh(ctx, gatewaycore.AuthContext{DID: "viewer"}); done <- err }()
	for i := 0; i < 25; i++ {
		awaitLookup(t, r.started)
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("canceled discovery did not join workers")
	}
	if r.active != 0 || r.gets != 25 || len(s.discoveries) != 0 {
		t.Fatalf("canceled work survived: active=%d gets=%d discoveries=%d", r.active, r.gets, len(s.discoveries))
	}
}
func TestRefreshFullSidebarFreshScopesAndRemovals(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:refresh%d", time.Now().UnixNano())
	at := time.Now().UTC()
	fixture := refreshFixture(3)
	fixture.pages[viewer+"/site.standard.graph.subscription"] = fixture.pages["viewer/site.standard.graph.subscription"]
	delete(fixture.pages, "viewer/site.standard.graph.subscription")
	id := func(n int) string { return fmt.Sprintf("at://did:plc:author/site.standard.publication/%03d", n) }
	folder := "at://" + viewer + "/app.thesocialwire.folder/news"
	fixture.pages[viewer+"/app.thesocialwire.folder"] = []gatewaycore.RepoRecord{record(folder, map[string]any{"name": "News"})}
	fixture.pages[viewer+"/app.thesocialwire.publicationPrefs"] = []gatewaycore.RepoRecord{record("pref-a", map[string]any{"publicationId": id(0), "folderId": folder}), record("pref-b", map[string]any{"publicationId": id(1), "folderId": "news"})}
	r := &refreshLookupRepo{repoFixture: fixture}
	s := NewService(db, r, nil)
	defer s.Close()
	s.Now = func() time.Time { return at }
	following := DiscoveredRow{PublicationID: "did:plc:followed", AuthorDID: "did:plc:followed", Title: "Retained Following", DiscoveredAt: at.Add(-time.Minute)}
	s.discoveries[viewer] = discoveryEntry{value: DiscoveryContext{Following: []DiscoveredRow{following}}, expires: at.Add(time.Minute)}
	t.Cleanup(func() {
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
			db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	old := SidebarRow{PublicationID: id(0), Title: "Old", AppViewScope: AppViewScope{AuthorDID: "did:plc:author", PublicationSiteURLs: []string{"https://stale.invalid/"}}}
	removed := SidebarRow{PublicationID: "removed", AppViewScope: AppViewScope{AuthorDID: "did:plc:removed"}}
	s.rows[viewer] = map[string]SidebarRow{id(0): old, "removed": removed}
	s.scopes[id(0)] = scopeEntry{value: old.AppViewScope, expires: at.Add(time.Hour)}
	s.scopes["removed"] = scopeEntry{value: removed.AppViewScope, expires: at.Add(time.Hour)}
	if err := (ProjectionStore{DB: db}).Persist(ctx, Sidebar{ViewerDID: viewer, AllPublicationRows: []SidebarRow{old, removed}, SubscribedUnfoldered: []SidebarRow{old, removed}, FollowingTabPublications: []SidebarRow{{PublicationID: following.PublicationID, AuthorDID: following.AuthorDID, AppViewScope: AppViewScope{AuthorDID: following.AuthorDID}}}}, true); err != nil {
		t.Fatal(err)
	}
	result, err := s.Refresh(ctx, gatewaycore.AuthContext{DID: viewer})
	s.Close()
	if err != nil {
		t.Fatal(err)
	}
	if len(result.AllPublicationRows) != 4 || len(result.FolderSections) != 1 || len(result.FolderSections[0].Publications) != 2 || len(result.SubscribedUnfoldered) != 1 || len(result.PublicationPrefs) != 2 || len(result.FollowingTabPublications) != 1 {
		t.Fatalf("incomplete sidebar: %+v", result)
	}
	fresh := s.SidebarRows(viewer, []string{id(0)})[0]
	if fresh.Title != "Title 003" || !fresh.DiscoveredAt.Equal(at) || !result.RefreshedAt.Equal(at) || !reflect.DeepEqual(fresh.AppViewScope.PublicationSiteURLs, []string{"https://fresh.invalid"}) {
		t.Fatalf("stale metadata/scope: %+v", fresh)
	}
	if !result.FollowingTabPublications[0].DiscoveredAt.Equal(following.DiscoveredAt) || len(s.SidebarRows(viewer, []string{"removed"})) != 0 {
		t.Fatal("Following provenance or row invalidation changed")
	}
	if _, ok := s.scopes["removed"]; ok {
		t.Fatal("removed scope survived invalidation")
	}
	for _, table := range []string{"appview_publication_scopes", "appview_feed_publications"} {
		var count int
		if err := db.QueryRowContext(ctx, "SELECT count(*) FROM "+table+" WHERE viewer_did=$1 AND publication_id='removed'", viewer).Scan(&count); err != nil || count != 0 {
			t.Fatalf("%s retained removal: count=%d err=%v", table, count, err)
		}
	}
	for _, col := range []string{"app.thesocialwire.folder", "app.thesocialwire.publicationPrefs", "site.standard.graph.subscription", "app.skyreader.feed.subscription"} {
		if r.lists[col] != 1 {
			t.Fatalf("discovery count for %s: %d", col, r.lists[col])
		}
	}
	if r.lists["app.bsky.graph.follow"] != 0 || r.gets != 3 {
		t.Fatalf("unexpected follow walk/rebuild or lookups: lists=%v gets=%d", r.lists, r.gets)
	}
}

func TestDiscoverRetainedFollowingUsesPreferencesWithoutEnrollingAuthors(t *testing.T) {
	r := refreshFixture(1)
	prior := []DiscoveredRow{{PublicationID: "hidden", AuthorDID: "did:plc:hidden"}, {PublicationID: "retained", AuthorDID: "did:plc:retained"}, {PublicationID: "at://did:plc:author/site.standard.publication/000", AuthorDID: "did:plc:author", Title: "Stale"}}
	r.pages["viewer/app.thesocialwire.publicationPrefs"] = []gatewaycore.RepoRecord{record("hidden-pref", map[string]any{"publicationId": "hidden", "hidden": true})}
	result, err := Discover(context.Background(), r, nil, "viewer", false, prior, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Following) != 1 || len(result.UniqueRows) != 2 || !reflect.DeepEqual(result.EnrollAuthorDIDs, []string{"did:plc:author"}) {
		t.Fatalf("retention affected hidden rows/enrollment: %+v", result)
	}
	for _, row := range result.UniqueRows {
		if row.Title == "Stale" || row.PublicationID == "hidden" {
			t.Fatalf("stale retained row won: %+v", row)
		}
	}
}

func TestRefreshColdReplicaPreservesDurableFollowing(t *testing.T) {
	for _, snapshot := range []bool{false, true} {
		t.Run(fmt.Sprint("snapshot=", snapshot), func(t *testing.T) {
			db := fixtureDB(t)
			ctx := context.Background()
			at := time.Now().UTC().Truncate(time.Second)
			viewer := fmt.Sprintf("did:plc:coldrefresh%d", time.Now().UnixNano())
			cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
			t.Cleanup(func() {
				cache.InvalidateSidebar(ctx, viewer)
				for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
					db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
				}
			})
			following := SidebarRow{PublicationID: "did:plc:retained", AuthorDID: "did:plc:retained", Title: "Stored Following", DiscoveredAt: at.Add(-time.Hour), AppViewScope: AppViewScope{AuthorDID: "did:plc:retained", PublicationSiteURLs: []string{"https://retained.invalid"}}}
			another := SidebarRow{PublicationID: "did:plc:another", AuthorDID: "did:plc:another", Title: "Another Following", DiscoveredAt: following.DiscoveredAt, AppViewScope: AppViewScope{AuthorDID: "did:plc:another"}}
			hidden := SidebarRow{PublicationID: "did:plc:hidden", AuthorDID: "did:plc:hidden", Title: "Hidden Following", AppViewScope: AppViewScope{AuthorDID: "did:plc:hidden"}}
			removed := SidebarRow{PublicationID: "rss:removed", AuthorDID: thinappviewcore.RSSAuthorDID, AppViewScope: AppViewScope{AuthorDID: thinappviewcore.RSSAuthorDID}}
			old := Sidebar{ViewerDID: viewer, FollowingTabPublications: []SidebarRow{following, another, hidden}, SubscribedUnfoldered: []SidebarRow{removed}, AllPublicationRows: []SidebarRow{following, another, hidden, removed}}
			if err := (ProjectionStore{DB: db}).Persist(ctx, old, true); err != nil {
				t.Fatal(err)
			}
			if snapshot {
				if err := cache.Store(ctx, viewer, BootstrapSnapshot{Version: 1, Priority: old}, at.Add(-2*time.Hour)); err != nil {
					t.Fatal(err)
				}
			}
			fixture := repoFixture{pages: map[string][]gatewaycore.RepoRecord{viewer + "/app.thesocialwire.publicationPrefs": {record("hidden-pref", map[string]any{"publicationId": hidden.PublicationID, "hidden": true})}}}
			r := &refreshLookupRepo{repoFixture: fixture}
			s := NewService(db, r, nil)
			defer s.Close()
			s.Cache = &cache
			s.Now = func() time.Time { return at }
			result, err := s.Refresh(ctx, gatewaycore.AuthContext{DID: viewer})
			s.Close()
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(result.RetainedFollowingPublicationIDs, []string{another.PublicationID, following.PublicationID}) {
				t.Fatalf("cold refresh did not authorize retained Following rows: %v", result.RetainedFollowingPublicationIDs)
			}
			wantRows := 0
			if snapshot {
				wantRows = 2
			}
			if len(result.FollowingTabPublications) != wantRows || len(result.AllPublicationRows) != wantRows || len(result.SubscribedUnfoldered) != 0 || len(result.EnrollAuthorDIDs) != 0 {
				t.Fatalf("cold refresh response: %+v", result)
			}
			if snapshot {
				row := result.FollowingTabPublications[0]
				if row.Title != following.Title || !row.DiscoveredAt.Equal(following.DiscoveredAt) {
					t.Fatalf("snapshot source metadata changed: %+v", row)
				}
			}
			for _, id := range []string{following.PublicationID, another.PublicationID, hidden.PublicationID, removed.PublicationID} {
				want := 0
				if id == following.PublicationID || id == another.PublicationID {
					want = 1
				}
				for _, table := range []string{"appview_publication_scopes", "appview_feed_publications"} {
					var count int
					if err := db.QueryRowContext(ctx, "SELECT count(*) FROM "+table+" WHERE viewer_did=$1 AND publication_id=$2", viewer, id).Scan(&count); err != nil || count != want {
						t.Fatalf("%s id=%s count=%d want=%d err=%v", table, id, count, want, err)
					}
				}
			}
			if r.lists["app.bsky.graph.follow"] != 0 {
				t.Fatalf("unexpected follow discovery: %v", r.lists)
			}
			cached, err := cache.Lookup(ctx, viewer, at, true)
			if err != nil || cached != nil {
				t.Fatalf("sidebar was not invalidated: %+v %v", cached, err)
			}
		})
	}
}

func TestRefreshReportsFailedAuthoritativePersistence(t *testing.T) {
	db := fixtureDB(t)
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	r := &refreshLookupRepo{repoFixture: refreshFixture(3)}
	s := NewService(db, r, nil)
	defer s.Close()
	result, err := s.Refresh(context.Background(), gatewaycore.AuthContext{DID: "viewer"})
	if err == nil || len(result.AllPublicationRows) != 0 {
		t.Fatalf("refresh reported success without persisting its authoritative replacement: %+v %v", result, err)
	}
	if r.gets != 3 || s.Repo != r || s.discoveries["viewer"].value.refresh != nil {
		t.Fatal("failed persistence repeated discovery reads or retained refresh-local metadata")
	}
}

func TestRetainedFollowingIDsAreAnOptionalRefreshField(t *testing.T) {
	for _, test := range []struct {
		name        string
		ids         []string
		wantPresent bool
	}{
		{name: "ordinary sidebar"},
		{name: "manual refresh retained membership", ids: []string{"did:plc:retained"}, wantPresent: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			raw, err := json.Marshal(Sidebar{RetainedFollowingPublicationIDs: test.ids})
			if err != nil {
				t.Fatal(err)
			}
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(raw, &fields); err != nil {
				t.Fatal(err)
			}
			_, present := fields["retainedFollowingPublicationIds"]
			if present != test.wantPresent {
				t.Fatalf("optional field presence=%v want=%v", present, test.wantPresent)
			}
		})
	}
}

func TestRefreshDiscoversUnsubscribedOwnPublicationWithoutFollows(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:ownrefresh%d", time.Now().UnixNano())
	at := time.Now().UTC()
	id := "at://" + viewer + "/site.standard.publication/own"
	publication := record(id, map[string]any{"title": "My Fresh Publication", "site": "https://own.invalid/"})
	r := &refreshLookupRepo{repoFixture: repoFixture{records: map[string]gatewaycore.RepoRecord{id: publication}, pages: map[string][]gatewaycore.RepoRecord{viewer + "/site.standard.publication": {publication}}}}
	s := NewService(db, r, nil)
	defer s.Close()
	s.Now = func() time.Time { return at }
	t.Cleanup(func() {
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
			db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	result, err := s.Refresh(ctx, gatewaycore.AuthContext{DID: viewer})
	s.Close()
	if err != nil {
		t.Fatal(err)
	}
	if len(result.MyPublications) != 1 || len(result.AllPublicationRows) != 1 || len(result.SubscribedUnfoldered) != 0 || len(result.FollowingTabPublications) != 0 {
		t.Fatalf("own publication dropped or misclassified: %+v", result)
	}
	row := result.MyPublications[0]
	if row.PublicationID != id || row.Title != "My Fresh Publication" || !row.DiscoveredAt.Equal(at) || !reflect.DeepEqual(row.AppViewScope.PublicationSiteURLs, []string{"https://own.invalid"}) {
		t.Fatalf("own metadata/scope not fresh: %+v", row)
	}
	if r.lists["app.bsky.graph.follow"] != 0 || r.lists["site.standard.publication"] != 1 || r.gets != 0 {
		t.Fatalf("own discovery exceeded bounded reads: lists=%v gets=%d", r.lists, r.gets)
	}
	var count int
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM appview_publication_scopes WHERE viewer_did=$1 AND publication_id=$2 AND section_keys ? 'my'`, viewer, id).Scan(&count); err != nil || count != 1 {
		t.Fatalf("own scope not persisted: count=%d err=%v", count, err)
	}
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM appview_feed_publications WHERE viewer_did=$1 AND publication_id=$2`, viewer, id).Scan(&count); err != nil || count != 0 {
		t.Fatalf("own publication joined a reading feed: count=%d err=%v", count, err)
	}
	// Initial bootstrap's default no-follow discovery still skips own-author reads.
	r.mu.Lock()
	r.lists = map[string]int{}
	r.mu.Unlock()
	if _, err := s.Discover(ctx, viewer, false); err != nil {
		t.Fatal(err)
	}
	if r.lists["site.standard.publication"] != 0 || len(r.lists) != 4 {
		t.Fatalf("default bootstrap discovery changed: %v", r.lists)
	}
}

func TestRefreshCannotResurrectFollowingRemovedByAnotherReplica(t *testing.T) {
	for _, snapshot := range []bool{false, true} {
		t.Run(fmt.Sprint("snapshot=", snapshot), func(t *testing.T) {
			db := fixtureDB(t)
			ctx := context.Background()
			at := time.Now().UTC()
			viewer := fmt.Sprintf("did:plc:stale-follow%d", at.UnixNano())
			row := SidebarRow{PublicationID: "did:plc:removed-follow", AuthorDID: "did:plc:removed-follow", Title: "Stale Following", DiscoveredAt: at.Add(-time.Minute), AppViewScope: AppViewScope{AuthorDID: "did:plc:removed-follow"}}
			stale := Sidebar{ViewerDID: viewer, FollowingTabPublications: []SidebarRow{row}, AllPublicationRows: []SidebarRow{row}}
			store := ProjectionStore{DB: db}
			cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
			t.Cleanup(func() {
				cache.InvalidateSidebar(ctx, viewer)
				for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
					db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
				}
			})
			if err := store.Persist(ctx, stale, true); err != nil {
				t.Fatal(err)
			}
			s := NewService(db, repoFixture{}, nil)
			defer s.Close()
			s.Now = func() time.Time { return at }
			if snapshot {
				s.Cache = &cache
				if err := cache.Store(ctx, viewer, BootstrapSnapshot{Version: 1, Priority: stale}, at); err != nil {
					t.Fatal(err)
				}
			} else {
				s.discoveries[viewer] = discoveryEntry{value: DiscoveryContext{Following: []DiscoveredRow{{PublicationID: row.PublicationID, AuthorDID: row.AuthorDID, Title: row.Title}}}, expires: at.Add(time.Minute)}
			}
			// A different replica's authoritative full discovery removes this follow,
			// while this process or snapshot still has its old display row.
			if err := store.Persist(ctx, Sidebar{ViewerDID: viewer}, true); err != nil {
				t.Fatal(err)
			}
			result, err := s.Refresh(ctx, gatewaycore.AuthContext{DID: viewer})
			if err != nil {
				t.Fatal(err)
			}
			if len(result.FollowingTabPublications) != 0 || len(result.AllPublicationRows) != 0 || len(result.RetainedFollowingPublicationIDs) != 0 || len(s.SidebarRows(viewer, []string{row.PublicationID})) != 0 {
				t.Fatalf("stale follow resurrected: %+v", result)
			}
			cached := s.discoveries[viewer].value
			if len(cached.Following) != 0 || len(cached.UniqueRows) != 0 {
				t.Fatalf("stale discovery survived refresh: %+v", cached)
			}
			priority, reused, err := s.Priority(ctx, gatewaycore.AuthContext{DID: viewer}, false)
			if err != nil || len(priority.FollowingTabPublications) != 0 || len(priority.AllPublicationRows) != 0 || reused.cacheToken != cached.cacheToken {
				t.Fatalf("cached Priority resurrected removed follow: %+v err=%v", priority, err)
			}
			if scope, err := store.Scope(ctx, viewer, row.PublicationID); err != nil || scope != nil {
				t.Fatalf("removed durable scope resurrected: %+v %v", scope, err)
			}
			if ids, err := store.FollowingPublicationIDs(ctx, viewer); err != nil || len(ids) != 0 {
				t.Fatalf("removed durable membership resurrected: %v %v", ids, err)
			}
		})
	}
}

func TestRefreshMovesFollowingToSubscribed(t *testing.T) {
	for _, missingRecord := range []bool{false, true} {
		t.Run(fmt.Sprint("missing-record=", missingRecord), func(t *testing.T) {
			db := fixtureDB(t)
			ctx := context.Background()
			at := time.Now().UTC()
			viewer := fmt.Sprintf("did:plc:follow-to-sub%d", at.UnixNano())
			id := "at://did:plc:author/site.standard.publication/000"
			old := SidebarRow{PublicationID: id, AuthorDID: "did:plc:author", Title: "Old Following", AppViewScope: AppViewScope{AuthorDID: "did:plc:author"}}
			store := ProjectionStore{DB: db}
			t.Cleanup(func() {
				for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
					db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
				}
			})
			if err := store.Persist(ctx, Sidebar{ViewerDID: viewer, FollowingTabPublications: []SidebarRow{old}}, true); err != nil {
				t.Fatal(err)
			}
			fixture := refreshFixture(1)
			fixture.pages[viewer+"/site.standard.graph.subscription"] = fixture.pages["viewer/site.standard.graph.subscription"]
			delete(fixture.pages, "viewer/site.standard.graph.subscription")
			if missingRecord {
				delete(fixture.records, id)
			}
			s := NewService(db, fixture, nil)
			defer s.Close()
			s.Now = func() time.Time { return at }
			s.discoveries[viewer] = discoveryEntry{value: DiscoveryContext{Following: []DiscoveredRow{{PublicationID: id, AuthorDID: old.AuthorDID, Title: old.Title}}}, expires: at.Add(time.Minute)}
			result, err := s.Refresh(ctx, gatewaycore.AuthContext{DID: viewer})
			if err != nil {
				t.Fatal(err)
			}
			if len(result.FollowingTabPublications) != 0 || len(result.RetainedFollowingPublicationIDs) != 0 {
				t.Fatalf("subscribed publication remained in Following: %+v", result)
			}
			want := 1
			if missingRecord {
				want = 0
			}
			if len(result.SubscribedUnfoldered) != want || len(result.AllPublicationRows) != want {
				t.Fatalf("subscription rows: %+v", result)
			}
			if !missingRecord && result.SubscribedUnfoldered[0].Title != "Title 001" {
				t.Fatal("stale Following metadata won")
			}
			var count int
			if err := db.QueryRowContext(ctx, `SELECT count(*) FROM appview_feed_publications WHERE viewer_did=$1 AND feed_kind='following'`, viewer).Scan(&count); err != nil || count != 0 {
				t.Fatalf("durable following count=%d err=%v", count, err)
			}
			if err := db.QueryRowContext(ctx, `SELECT count(*) FROM appview_feed_publications WHERE viewer_did=$1 AND feed_kind='subscribed'`, viewer).Scan(&count); err != nil || count != want {
				t.Fatalf("durable subscribed count=%d want=%d err=%v", count, want, err)
			}
		})
	}
}

func TestOlderSidebarBuildDoesNotPruneNewerDiscovery(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	at := time.Now().UTC()
	viewer := fmt.Sprintf("did:plc:discovery-token%d", at.UnixNano())
	s := NewService(db, repoFixture{}, nil)
	defer s.Close()
	s.Now = func() time.Time { return at }
	t.Cleanup(func() {
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
			db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	s.discoveries[viewer] = discoveryEntry{value: DiscoveryContext{Following: []DiscoveredRow{{PublicationID: "did:plc:retained", AuthorDID: "did:plc:retained"}}}, expires: at.Add(time.Minute)}
	older, err := s.Discover(ctx, viewer, false)
	if err != nil {
		t.Fatal(err)
	}
	newer, err := s.Discover(ctx, viewer, false)
	if err != nil {
		t.Fatal(err)
	}
	if older.cacheToken == nil || newer.cacheToken == older.cacheToken {
		t.Fatal("discoveries did not receive distinct cache tokens")
	}
	// The older build finishes after another discovery has replaced the cache.
	result, err := s.BuildSidebar(ctx, older, "full", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.FollowingTabPublications) != 0 {
		t.Fatal("older build did not prune absent durable Following")
	}
	cached := s.discoveries[viewer].value
	if cached.cacheToken != newer.cacheToken || len(cached.Following) != 1 || len(cached.UniqueRows) != 1 {
		t.Fatalf("older build overwrote newer discovery: %+v", cached)
	}
}
