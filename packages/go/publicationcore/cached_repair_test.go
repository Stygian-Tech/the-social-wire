package publicationcore

import (
	"context"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"testing"
	"time"
)

func TestCachedRepairUsesExpiredSnapshotWithoutDiscovery(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	at := time.Now().UTC()
	viewer := fmt.Sprintf("did:plc:pubrepair%d", at.UnixNano())
	id := "at://did:plc:author/site.standard.publication/a"
	cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}, SidebarFresh: time.Minute}
	service := NewService(db, nil, nil)
	defer service.Close()
	service.Cache = &cache
	service.Now = func() time.Time { return at.Add(2 * time.Minute) }
	t.Cleanup(func() {
		cache.InvalidateSidebar(ctx, viewer)
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
			db.ExecContext(ctx, "DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	if service.RebuildFeedProjectionFromCachedSidebar(ctx, viewer) {
		t.Fatal("missing cache repaired")
	}
	row := SidebarRow{PublicationID: id, AuthorDID: "did:plc:author", AppViewScope: AppViewScope{AuthorDID: "did:plc:author", PublicationATURI: &id}, DiscoveredAt: at}
	sidebar := Sidebar{ViewerDID: viewer, RefreshedAt: at, AllPublicationRows: []SidebarRow{row}, SubscribedUnfoldered: []SidebarRow{row}}
	if e := cache.Store(ctx, viewer, BootstrapSnapshot{Version: 1, Priority: sidebar}, at); e != nil {
		t.Fatal(e)
	}
	if !service.RebuildFeedProjectionFromCachedSidebar(ctx, viewer) {
		t.Fatal("expired repair failed")
	}
	scope, e := (ProjectionStore{DB: db}).Scope(ctx, viewer, id)
	if e != nil || scope == nil {
		t.Fatal(scope, e)
	}
}
