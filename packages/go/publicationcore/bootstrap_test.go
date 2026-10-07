package publicationcore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"testing"
	"time"
)

func TestCachedBootstrapSparseReplacementAndReadOverlay(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:bootstrap%d", time.Now().UnixNano())
	at := time.Now().UTC().Truncate(time.Second)
	id := "fixture"
	uri := "at://" + viewer + "/site.standard.document/a"
	service := NewService(db, repoFixture{}, nil)
	defer service.Close()
	service.Now = func() time.Time { return at }
	cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
	service.Cache = &cache
	t.Cleanup(func() {
		for _, table := range []string{"sidebar_projection_cache", "first_page_cache", "appview_unread_counters", "unread_counts_cache", "read_marks"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	row := SidebarRow{PublicationID: id, AuthorDID: viewer, DiscoveredAt: at, AppViewScope: AppViewScope{AuthorDID: viewer, PublicationScopeATURIs: []string{}, PublicationSiteURLs: []string{}}}
	snapshot := BootstrapSnapshot{Version: 1, Priority: Sidebar{ViewerDID: viewer, AllPublicationRows: []SidebarRow{row}, MyPublications: []SidebarRow{row}, SubscribedUnfoldered: []SidebarRow{}, FollowingTabPublications: []SidebarRow{}, RefreshedAt: at}, FolderPayload: &FolderPayload{FolderSections: []FolderSection{}, AllPublicationRows: []SidebarRow{}}}
	if e := cache.Store(ctx, viewer, snapshot, at); e != nil {
		t.Fatal(e)
	}
	if _, e := db.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)VALUES($1,$2,1,1,'exact',FALSE,$3)`, viewer, id, at); e != nil {
		t.Fatal(e)
	}
	page := appviewcore.EntryPage{Entries: []appviewcore.Entry{{EntryID: uri, Title: "Fixture", PublishedAt: at, FeedPositionAt: at}}}
	raw, _ := json.Marshal(page)
	if e := cache.Projection.StoreFirstPage(ctx, viewer, id, string(raw), at); e != nil {
		t.Fatal(e)
	}
	if _, e := db.Exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at)VALUES($1,$2,$3)`, viewer, uri, at); e != nil {
		t.Fatal(e)
	}
	cached, e := cache.CachedPage(ctx, viewer, id, 50, at)
	if e != nil || cached == nil || !cached.Page.Entries[0].IsRead {
		t.Fatalf("cached read overlay %+v %v", cached, e)
	}
	events := []map[string]any{}
	e = service.Bootstrap(ctx, gatewaycore.AuthContext{DID: viewer}, false, func(event map[string]any) error { events = append(events, event); return nil })
	if e != nil {
		t.Fatal(e)
	}
	kinds := []string{}
	for _, event := range events {
		kinds = append(kinds, event["kind"].(string))
	}
	if fmt.Sprint(kinds) != "[sidebarPriority sidebarFolders unreadCounts selectedPublication entriesPage done]" {
		t.Fatalf("event phases %v", kinds)
	}
	counts := events[2]["unreadCounts"].(map[string]any)
	if counts["accuracy"] != "exact" || fmt.Sprint(counts["replacePublicationIds"]) != "[fixture]" {
		t.Fatalf("counts metadata %+v", counts)
	}
	done := events[5]["done"].(map[string]any)
	if done["source"] != "projection_cache" || done["refreshedAt"] != at.Format(time.RFC3339) {
		t.Fatalf("cache provenance %+v", done)
	}
}
func TestSelectedEnrollmentDoesNotBlockColdStream(t *testing.T) {
	db := fixtureDB(t)
	s := NewService(db, repoFixture{}, nil)
	defer s.Close()
	row := SidebarRow{PublicationID: "empty", AppViewScope: AppViewScope{AuthorDID: "did:web:unavailable.social"}}
	start := time.Now()
	page, e := s.SelectedPage(context.Background(), gatewaycore.AuthContext{DID: "viewer"}, row)
	if e != nil || page.Source != "unavailable" || len(page.Page.Entries) != 0 || time.Since(start) > time.Second {
		t.Fatalf("cold selection blocked or overstated: %+v %v", page, e)
	}
}
func TestResolverInputAndAlternatesPreserveSource(t *testing.T) {
	r := Resolver{Repo: repoFixture{}}
	ctx := context.Background()
	if response := r.Resolve(ctx, "  "); response.Error == nil {
		t.Fatal("empty input accepted")
	}
	if response := r.Resolve(ctx, "at://did:plc:author/site.standard.publication/a"); response.Result == nil || response.Result.Kind != "standard-site" {
		t.Fatalf("publication %+v", response)
	}
	if response := r.Resolve(ctx, "at://did:plc:author/site.standard.document/a"); response.Error == nil {
		t.Fatal("document accepted as publication")
	}
}

type trackingRepo struct {
	repoFixture
	followRequests int
}

func (r *trackingRepo) ListRecords(ctx context.Context, did, col, cursor string, limit int, reverse bool) (gatewaycore.RepoPage, error) {
	if col == "app.bsky.graph.follow" {
		r.followRequests++
	}
	return r.repoFixture.ListRecords(ctx, did, col, cursor, limit, reverse)
}
func TestColdBootstrapDoesNotWalkFollowGraph(t *testing.T) {
	db := fixtureDB(t)
	viewer := fmt.Sprintf("did:plc:coldbootstrap%d", time.Now().UnixNano())
	uri := "at://" + viewer + "-author/site.standard.publication/a"
	repo := &trackingRepo{repoFixture: repoFixture{records: map[string]gatewaycore.RepoRecord{uri: record(uri, map[string]any{"title": "Publisher"})}, pages: map[string][]gatewaycore.RepoRecord{viewer + "/site.standard.graph.subscription": {record("at://"+viewer+"/site.standard.graph.subscription/a", map[string]any{"publication": uri})}}}}
	service := NewService(db, repo, nil)
	defer service.Close()
	service.Cache = &CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
	t.Cleanup(func() {
		for _, table := range []string{"sidebar_projection_cache", "appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes", "appview_unread_counters", "unread_counts_cache"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	kinds := []string{}
	if e := service.Bootstrap(context.Background(), gatewaycore.AuthContext{DID: viewer}, false, func(event map[string]any) error { kinds = append(kinds, event["kind"].(string)); return nil }); e != nil {
		t.Fatal(e)
	}
	if repo.followRequests != 0 {
		t.Fatal("cold stream fanout walked follows")
	}
	if len(kinds) < 4 || kinds[0] != "sidebarPriority" || kinds[len(kinds)-1] != "done" {
		t.Fatalf("phases %v", kinds)
	}
}
func TestServiceShutdownJoinsBackgroundTasks(t *testing.T) {
	s := NewService(nil, repoFixture{}, nil)
	started, joined := make(chan struct{}), make(chan struct{})
	if !s.launch("fixture", func(ctx context.Context) { close(started); <-ctx.Done(); close(joined) }) {
		t.Fatal("did not launch")
	}
	<-started
	s.Close()
	select {
	case <-joined:
	default:
		t.Fatal("background tasks not joined")
	}
	if s.launch("after", func(context.Context) {}) {
		t.Fatal("launched after shutdown")
	}
}
