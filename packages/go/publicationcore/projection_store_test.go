package publicationcore

import (
	"context"
	"database/sql"
	"fmt"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"os"
	"testing"
	"time"
)

func fixtureDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("canonical PostgreSQL fixture required")
	}
	db, e := sql.Open("pgx", dsn)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	return db
}
func TestProjectionReplacementAndReadingMemberships(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:pubscope%d", time.Now().UnixNano())
	store := ProjectionStore{DB: db}
	t.Cleanup(func() {
		for _, table := range []string{"appview_feed_publications", "appview_viewer_feeds", "appview_publication_scopes"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	row := func(id string) SidebarRow {
		return SidebarRow{PublicationID: id, AuthorDID: viewer, AppViewScope: AppViewScope{AuthorDID: viewer, PublicationScopeATURIs: []string{}, PublicationSiteURLs: []string{"https://publisher.invalid/"}}}
	}
	mine, folder, follow := row("mine"), row("folder"), row("follow")
	sidebar := Sidebar{ViewerDID: viewer, MyPublications: []SidebarRow{mine}, FollowingTabPublications: []SidebarRow{follow}, FolderSections: []FolderSection{{FolderRKey: "one", Publications: []SidebarRow{folder}}}}
	if e := store.Persist(ctx, sidebar, true); e != nil {
		t.Fatal(e)
	}
	var count int
	if e := db.QueryRow(`SELECT count(*) FROM appview_feed_publications WHERE viewer_did=$1 AND feed_kind='subscribed'`, viewer).Scan(&count); e != nil || count != 1 {
		t.Fatalf("own publications must not join subscribed reading feed: %d %v", count, e)
	}
	scope, e := store.Scope(ctx, viewer, "folder")
	if e != nil || scope == nil || scope.AuthorDID != viewer {
		t.Fatalf("scope %v %v", scope, e)
	}
	if e = store.Persist(ctx, Sidebar{ViewerDID: viewer, MyPublications: []SidebarRow{mine}}, false); e != nil {
		t.Fatal(e)
	}
	scope, e = store.Scope(ctx, viewer, "follow")
	if e != nil || scope == nil {
		t.Fatalf("priority erased full scope %v %v", scope, e)
	}
	if e = store.Persist(ctx, Sidebar{ViewerDID: viewer, MyPublications: []SidebarRow{mine}}, true); e != nil {
		t.Fatal(e)
	}
	scope, e = store.Scope(ctx, viewer, "follow")
	if e != nil || scope != nil {
		t.Fatalf("full replacement retained removed scope %v %v", scope, e)
	}
}
func TestCounterMissingReadMarksAndFloor(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	viewer := fmt.Sprintf("did:plc:pubcount%d", time.Now().UnixNano())
	author := viewer + "author"
	at := time.Now().UTC().Truncate(time.Second)
	site := "https://counter.invalid/"
	store := CounterStore{DB: db}
	scopes := []appviewcore.PublicationScope{{PublicationID: "fixture", AuthorDID: author, PublicationSiteURLs: []string{site}}}
	t.Cleanup(func() {
		for _, table := range []string{"appview_publication_read_floors", "appview_unread_counters", "read_marks", "appview_unread_overrides"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec(`DELETE FROM content_items WHERE author_did=$1`, author)
	})
	snapshot, e := store.Snapshot(ctx, viewer, scopes, at)
	if e != nil || !snapshot.Dirty || snapshot.Accuracy != "estimated" || len(snapshot.MissingPublicationIDs) != 1 {
		t.Fatalf("missing snapshot %+v %v", snapshot, e)
	}
	uris := []string{}
	for i := 0; i < 3; i++ {
		uri := fmt.Sprintf("at://%s/site.standard.document/%d", author, i)
		uris = append(uris, uri)
		item := thinappviewcore.IndexedContentItem{URI: uri, CID: "fixture", AuthorDID: author, Collection: "site.standard.document", CreatedAt: at.Add(-time.Duration(i) * time.Second), IndexedAt: at, ExpiresAt: at.Add(time.Hour), PublicationSite: &site, Render: thinappviewcore.ContentRenderFields{Title: "Fixture", PublishedAt: at.Format(time.RFC3339)}}
		if e = (thinappviewcore.ContentStore{DB: db}).Upsert(ctx, item); e != nil {
			t.Fatal(e)
		}
	}
	snapshot, e = store.Refresh(ctx, viewer, scopes, at)
	if e != nil || snapshot.Counts["fixture"] != 3 || snapshot.Dirty {
		t.Fatalf("fresh %+v %v", snapshot, e)
	}
	if _, e = db.Exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at) VALUES($1,$2,$3)`, viewer, uris[0], at); e != nil {
		t.Fatal(e)
	}
	snapshot, e = store.Refresh(ctx, viewer, scopes, at)
	if e != nil || snapshot.Counts["fixture"] != 2 {
		t.Fatalf("explicit mark %+v %v", snapshot, e)
	}
	if _, e = db.Exec(`INSERT INTO appview_publication_read_floors(viewer_did,publication_id,read_floor_at,read_floor_uri,generation) VALUES($1,'fixture',$2,$3,1)`, viewer, at.Add(-time.Second), uris[1]); e != nil {
		t.Fatal(e)
	}
	snapshot, e = store.Refresh(ctx, viewer, scopes, at)
	if e != nil || snapshot.Counts["fixture"] != 0 {
		t.Fatalf("floor %+v %v", snapshot, e)
	}
}
