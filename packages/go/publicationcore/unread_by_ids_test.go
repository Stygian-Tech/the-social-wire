package publicationcore

import (
	"context"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestUnreadIDsColdReplicaUsesExpiredViewerSidebarAndCanonicalCounts(t *testing.T) {
	db := fixtureDB(t)
	ctx := context.Background()
	at := time.Now().UTC()
	viewer := fmt.Sprintf("did:plc:unreadids%d", at.UnixNano())
	id := "at://did:plc:author/site.standard.publication/a"
	cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}, SidebarFresh: time.Minute}
	service := NewService(db, nil, nil)
	defer service.Close()
	service.Cache = &cache
	service.Now = func() time.Time { return at.Add(2 * time.Minute) }
	row := SidebarRow{PublicationID: id, AuthorDID: "did:plc:author", AppViewScope: AppViewScope{AuthorDID: "did:plc:author", PublicationATURI: &id}, DiscoveredAt: at}
	sidebar := Sidebar{ViewerDID: viewer, AllPublicationRows: []SidebarRow{row}, RefreshedAt: at}
	t.Cleanup(func() {
		cache.InvalidateSidebar(ctx, viewer)
		for _, table := range []string{"appview_unread_counters", "unread_counts_cache"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	if e := cache.Store(ctx, viewer, BootstrapSnapshot{Version: 1, Priority: sidebar}, at); e != nil {
		t.Fatal(e)
	}
	if _, e := db.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)VALUES($1,$2,7,123,'exact',false,$3)`, viewer, id, at); e != nil {
		t.Fatal(e)
	}
	out, e := service.UnreadCountsByPublicationIDs(ctx, gatewaycore.AuthContext{DID: viewer}, []string{url.QueryEscape(id), id})
	if e != nil || out.Counts[id] != 7 || out.Accuracy != "exact" || len(out.Counts) != 1 {
		t.Fatalf("%+v %v", out, e)
	}
	service.rows[viewer] = map[string]SidebarRow{id: row}
	service.Cache = nil
	out, e = service.UnreadCountsByPublicationIDs(ctx, gatewaycore.AuthContext{DID: viewer}, []string{id})
	if e != nil || out.Counts[id] != 7 {
		t.Fatal(out, e)
	}
}
func TestUnreadCounterFailureReturnsEstimatedWithoutInventingExactness(t *testing.T) {
	db := fixtureDB(t)
	service := NewService(db, nil, nil)
	defer service.Close()
	viewer := "did:plc:closedcounter"
	service.rows[viewer] = map[string]SidebarRow{"a": {PublicationID: "a", AppViewScope: AppViewScope{AuthorDID: "did:plc:author"}}}
	db.Close()
	out, e := service.UnreadCountsByPublicationIDs(context.Background(), gatewaycore.AuthContext{DID: viewer}, []string{"a"})
	if e != nil || out.Accuracy != "estimated" || !out.Dirty || out.Counts["a"] != 0 {
		t.Fatal(out, e)
	}
}

type canceledUnreadRepo struct{ active, calls atomic.Int32 }

func (r *canceledUnreadRepo) GetRecord(ctx context.Context, _ string, _ string, _ string, _ string) (*gatewaycore.RepoRecord, error) {
	return nil, nil
}
func (r *canceledUnreadRepo) ListRecords(ctx context.Context, _ string, _ string, _ string, _ int, _ bool) (gatewaycore.RepoPage, error) {
	r.active.Add(1)
	r.calls.Add(1)
	defer r.active.Add(-1)
	<-ctx.Done()
	return gatewaycore.RepoPage{}, ctx.Err()
}
func (r *canceledUnreadRepo) ResolvePDS(context.Context, string) (string, error) {
	return "https://pds.invalid", nil
}
func (r *canceledUnreadRepo) ResolveDID(_ context.Context, did string) (string, error) {
	return did, nil
}

type unreadGraphTransport struct{}

func (unreadGraphTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"follows":[]}`)), Header: http.Header{}}, nil
}
func TestUnreadIDsRejectMismatchedCachedViewerAndJoinColdDiscovery(t *testing.T) {
	db := fixtureDB(t)
	at := time.Now()
	viewer := fmt.Sprintf("did:plc:unreadprivacy%d", at.UnixNano())
	id := "at://did:plc:author/site.standard.publication/a"
	cache := CacheStore{Projection: thinappviewcore.ProjectionCache{DB: db}}
	repo := &canceledUnreadRepo{}
	service := NewService(db, repo, &http.Client{Transport: unreadGraphTransport{}})
	defer service.Close()
	service.Cache = &cache
	t.Cleanup(func() { cache.InvalidateSidebar(context.Background(), viewer) })
	wrong := Sidebar{ViewerDID: "did:plc:other", RefreshedAt: at, AllPublicationRows: []SidebarRow{{PublicationID: id}}}
	if err := cache.Store(context.Background(), viewer, BootstrapSnapshot{Version: 1, Priority: wrong}, at); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	_, err := service.UnreadCountsByPublicationIDs(ctx, gatewaycore.AuthContext{DID: viewer}, []string{id})
	if !errors.Is(err, context.DeadlineExceeded) || repo.active.Load() != 0 || repo.calls.Load() > int32(5+len(publicationCollections)+len(contentCollections)) || repo.calls.Load() < 4 {
		t.Fatal("cold viewer lookup escaped bounds", err, repo.active.Load(), repo.calls.Load())
	}
}
