package listcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"sync/atomic"
	"testing"
	"time"
)

type detailReader struct {
	fixtureReader
	publication func(context.Context, string) (*PublicationRead, error)
}

func (r detailReader) Publication(ctx context.Context, id string) (*PublicationRead, error) {
	return r.publication(ctx, id)
}
func TestListPreparationFencesStaleSiteDetails(t *testing.T) {
	uri := "at://did:plc:author/site.standard.publication/a"
	started, finish := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	old, newURL := "https://old.publisher.social", "https://new.publisher.social"
	reader := detailReader{publication: func(ctx context.Context, id string) (*PublicationRead, error) {
		if calls.Add(1) == 1 {
			close(started)
			<-finish
			return &PublicationRead{SiteURL: &old, Details: &Publication{PublicationID: uri, Title: "Old"}}, nil
		}
		return &PublicationRead{SiteURL: &newURL, Details: &Publication{PublicationID: uri, Title: "New"}}, nil
	}}
	runtime := NewRuntime(nil, reader, nil)
	defer runtime.Close()
	list := List{URI: Identity{"did:plc:creator", "one"}.URI(), Publications: []string{uri}}
	done := make(chan []appviewcore.PublicationScope, 1)
	go func() { done <- runtime.ResolvedScopes(context.Background(), list, "viewer") }()
	<-started
	runtime.Invalidate("viewer")
	scopes := runtime.ResolvedScopes(context.Background(), list, "viewer")
	close(finish)
	<-done
	if len(scopes) != 1 || len(scopes[0].PublicationSiteURLs) != 1 || scopes[0].PublicationSiteURLs[0] != newURL {
		t.Fatalf("current scope %+v", scopes)
	}
	details := runtime.Enrich(context.Background(), "viewer", list).PublicationDetails
	if details == nil || len(*details) != 1 || (*details)[0].Title != "New" {
		t.Fatalf("stale detail escaped fence %+v", details)
	}
}
func TestPreparedListIsBoundedAndShutdownJoined(t *testing.T) {
	reader := detailReader{publication: func(ctx context.Context, id string) (*PublicationRead, error) { <-ctx.Done(); return nil, ctx.Err() }}
	runtime := NewRuntime(nil, reader, nil)
	list := List{URI: Identity{"did:plc:creator", "one"}.URI(), Publications: []string{"at://did:plc:author/site.standard.publication/a"}}
	runtime.Prepare(context.Background(), "viewer", list)
	if _, _, e := runtime.PreparedFeed(list.URI, "viewer"); e != ErrWarming {
		t.Fatal(e)
	}
	done := make(chan struct{})
	go func() { runtime.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("preparation did not join cancellation")
	}
}
func TestScopesSuppressPublicationWhenWholeAuthorIncluded(t *testing.T) {
	list := List{Users: []string{"did:plc:author"}, Publications: []string{"at://did:plc:author/site.standard.publication/a", "at://did:plc:second/site.standard.publication/b"}}
	scopes := ListScopes(list)
	if len(scopes) != 2 || scopes[0].PublicationATURI != nil || scopes[1].AuthorDID != "did:plc:second" {
		t.Fatalf("scopes %+v", scopes)
	}
}
