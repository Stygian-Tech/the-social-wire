package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestHostEntriesSharedCacheReadOverlayAndScopedInvalidation(t *testing.T) {
	h := hostFixture(t, false, nil)
	ctx := context.Background()
	at := time.Now().UTC()
	viewer := fmt.Sprintf("did:plc:host-cache%d", at.UnixNano())
	other := viewer + "other"
	publication := "at://did:plc:author/site.standard.publication/host-cache"
	author := "did:plc:author"
	entries := []appviewcore.Entry{}
	for i := range 3 {
		position := at.Add(-time.Duration(i) * time.Second)
		entries = append(entries, appviewcore.Entry{EntryID: fmt.Sprintf("at://%s/site.standard.document/cache%d", author, i), Title: "cached entry", PublishedAt: position, FeedPositionAt: position})
	}
	cursor := (appviewcore.EntryCursor{CreatedAt: entries[2].FeedPositionAt, URI: entries[2].EntryID}).Encode()
	page := appviewcore.EntryPage{Entries: entries, Cursor: &cursor}
	raw, e := publicationcore.EncodeFirstPage(page)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		h.DB.Exec(`DELETE FROM first_page_cache WHERE publication_id=$1`, publication)
		h.DB.Exec(`DELETE FROM read_marks WHERE viewer_did=ANY($1::text[])`, []string{viewer, other})
		h.DB.Exec(`DELETE FROM unread_counts_cache WHERE viewer_did=ANY($1::text[])`, []string{viewer, other})
	})
	if e = h.Publications.Cache.Projection.StoreFirstPage(ctx, thinappviewcore.SharedFirstPageViewer, publication, string(raw), at); e != nil {
		t.Fatal(e)
	}
	if _, e = h.DB.Exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at)VALUES($1,$2,$3)`, viewer, entries[0].EntryID, at); e != nil {
		t.Fatal(e)
	}
	path := "/v1/appview/entries?authorDid=" + url.QueryEscape(author) + "&publicationAtUri=" + url.QueryEscape(publication) + "&limit=2"
	response := serveHost(h, "GET", path, viewer)
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	var result appviewcore.EntryPage
	if e = json.Unmarshal(response.Body.Bytes(), &result); e != nil {
		t.Fatal(e)
	}
	if len(result.Entries) != 2 || !result.Entries[0].IsRead || result.Entries[1].IsRead || result.Cursor == nil {
		t.Fatal(result)
	}
	position, e := appviewcore.DecodeEntryCursor(*result.Cursor)
	if e != nil || position.URI != entries[1].EntryID || absDuration(position.CreatedAt.Sub(entries[1].FeedPositionAt)) > time.Microsecond {
		t.Fatal(position, e)
	}
	response = serveHost(h, "GET", path, other)
	if response.Code != 200 || strings.Contains(response.Body.String(), `"isRead":true`) {
		t.Fatal("read overlay crossed viewers", response.Body.String())
	}
	response = serveHost(h, "GET", path+"&filter=unread", viewer)
	if response.Code != 200 || strings.Contains(response.Body.String(), "cached entry") {
		t.Fatal("filtered read unexpectedly used shared cache", response.Code, response.Body.String())
	}
	for _, owner := range []string{viewer, other} {
		if _, e = h.DB.Exec(`INSERT INTO unread_counts_cache(viewer_did,publication_id,unread_count,cached_at,expires_at)VALUES($1,$2,3,$3,$4)`, owner, publication, at, at.Add(time.Hour)); e != nil {
			t.Fatal(e)
		}
	}
	if e = h.invalidateUnread(ctx, h.Publications.Cache.Projection, viewer, publication); e != nil {
		t.Fatal(e)
	}
	var count int
	if e = h.DB.QueryRow(`SELECT COUNT(*) FROM unread_counts_cache WHERE viewer_did=ANY($1::text[])`, []string{viewer, other}).Scan(&count); e != nil || count != 1 {
		t.Fatal(count, e)
	}
	if hit, e := h.Publications.Cache.CachedPage(ctx, viewer, publication, 50, at); e != nil || hit == nil {
		t.Fatal("read invalidation evicted first page", e)
	}
}
func absDuration(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}
func TestEntryCachePrimaryPublicationSourcePrecedence(t *testing.T) {
	for _, test := range []struct {
		q    appviewcore.EntryQuery
		want string
	}{{appviewcore.EntryQuery{PublicationATURI: "at%3A%2F%2Fdid%3Aplc%3Aa%2Fsite.standard.publication%2Fone", ScopeATURIs: []string{"second"}}, "at://did:plc:a/site.standard.publication/one"}, {appviewcore.EntryQuery{ScopeATURIs: []string{"at://did:plc:a/site.standard.publication/two"}}, "at://did:plc:a/site.standard.publication/two"}, {appviewcore.EntryQuery{SiteURLs: []string{"https://feed.example/rss"}}, thinappviewcore.RSSPublicationID("https://feed.example/rss")}, {appviewcore.EntryQuery{AuthorDID: "did:plc:a"}, "did:plc:a"}} {
		if got := publicationID(test.q); got != test.want {
			t.Fatal(got, test.want)
		}
	}
}
func TestRedisConfiguredUnavailableDisablesCacheWithoutSQLiteFallback(t *testing.T) {
	h := hostFixture(t, false, map[string]string{"APPVIEW_CACHE_BACKEND": "redis", "REDIS_URL": "invalid://cache"})
	if h.Redis != nil || h.Publications.Cache != nil {
		t.Fatal("invalid disposable Redis selected durable fallback")
	}
	if w := serveHost(h, "GET", "/readyz", ""); w.Code != 200 {
		t.Fatal(w.Code)
	}
}
