package publicationcore

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"testing"
	"time"
)

func TestSidebarCacheFoundationDatesAndVersion(t *testing.T) {
	db := fixtureDB(t)
	viewer := fmt.Sprintf("did:plc:pubcache%d", time.Now().UnixNano())
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Second)
	cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}, SidebarFresh: time.Minute}
	t.Cleanup(func() { cache.InvalidateSidebar(ctx, viewer) })
	snapshot := BootstrapSnapshot{Version: 1, Priority: Sidebar{ViewerDID: viewer, RefreshedAt: at, AllPublicationRows: []SidebarRow{{PublicationID: "test", DiscoveredAt: at}}}}
	raw, e := snapshotJSON(snapshot)
	if e != nil {
		t.Fatal(e)
	}
	var fields map[string]any
	json.Unmarshal([]byte(raw), &fields)
	date := fields["priority"].(map[string]any)["refreshedAt"]
	if _, ok := date.(float64); !ok {
		t.Fatalf("not Swift reference date: %v", date)
	}
	if e = cache.Store(ctx, viewer, snapshot, at); e != nil {
		t.Fatal(e)
	}
	hit, e := cache.Lookup(ctx, viewer, at, false)
	if e != nil || hit == nil || !hit.Snapshot.Priority.RefreshedAt.Equal(at) || hit.Stale {
		t.Fatalf("hit %+v %v", hit, e)
	}
	hit, e = cache.Lookup(ctx, viewer, at.Add(2*time.Minute), false)
	if e != nil || hit != nil {
		t.Fatalf("expired must miss %+v %v", hit, e)
	}
	hit, e = cache.Lookup(ctx, viewer, at.Add(2*time.Minute), true)
	if e != nil || hit == nil || !hit.Stale {
		t.Fatalf("bulk-read stale snapshot %+v %v", hit, e)
	}
	snapshot.Version = 0
	if e = cache.Store(ctx, viewer, snapshot, at); e != nil {
		t.Fatal(e)
	}
	hit, e = cache.Lookup(ctx, viewer, at, false)
	if e != nil || hit != nil {
		t.Fatalf("legacy podcast sidebar restored %+v %v", hit, e)
	}
}
