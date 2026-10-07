package reader

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/listcore"
)

type Routes struct {
	EntryPage      func(context.Context, gatewaycore.AuthContext, appviewcore.EntryQuery, int, time.Time) (appviewcore.EntryPage, error)
	DB             *sql.DB
	Now            func() time.Time
	ListFeed       func(context.Context, gatewaycore.AuthContext, string, string, string, int, time.Time) (*appviewcore.FeedPage, error)
	RepairFeed     func(context.Context, string) bool
	InvalidateRead func(context.Context, string, string) error
	PurgeCircle    func(context.Context, string) error
	PurgeUnread    func(context.Context, string) error
}

func (a Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("DELETE /v1/appview/privacy/purge", a.purge)
	mux.HandleFunc("POST /xrpc/app.thesocialwire.appview.purgeViewerData", a.purge)
	for _, path := range []string{"/v1/appview/feed", "/xrpc/app.thesocialwire.appview.getFeed"} {
		mux.HandleFunc("GET "+path, a.feed)
	}
	for _, path := range []string{"/v1/appview/entries", "/xrpc/app.thesocialwire.appview.listEntries"} {
		mux.HandleFunc("GET "+path, a.entries)
	}
	for _, path := range []string{"/v1/appview/entry", "/xrpc/app.thesocialwire.appview.getEntry"} {
		mux.HandleFunc("GET "+path, a.entry)
	}
	for _, path := range []string{"POST /v1/appview/read-marks", "POST /xrpc/app.thesocialwire.appview.putReadMark"} {
		mux.HandleFunc(path, a.putRead)
	}
	for _, path := range []string{"DELETE /v1/appview/read-marks", "POST /xrpc/app.thesocialwire.appview.deleteReadMark"} {
		mux.HandleFunc(path, a.deleteRead)
	}
}

func (a Routes) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}
func auth(w http.ResponseWriter, r *http.Request) (gatewaycore.AuthContext, bool) {
	value, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || value.DID == "" || value.DID == gatewaycore.AnonymousDiscoveryDID {
		fail(w, r, 401, "unauthorized", "Authentication is required.", false)
		return gatewaycore.AuthContext{}, false
	}
	return value, true
}

func integer(r *http.Request, key string, def, min, max int) (int, error) {
	values, exists := r.URL.Query()[key]
	if !exists {
		return def, nil
	}
	if len(values) != 1 {
		return 0, errors.New("invalid integer")
	}
	n, err := strconv.Atoi(values[0])
	if err != nil || n < min || n > max {
		return 0, errors.New("invalid integer")
	}
	return n, nil
}

func (a Routes) feed(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	kind, id := q.Get("kind"), q.Get("id")
	if kind != "subscribed" && kind != "following" && kind != "folder" && kind != "publication" && kind != "list" {
		fail(w, r, 400, "invalid_request", "Query requires a valid `kind`", false)
		return
	}
	if (kind == "folder" || kind == "publication" || kind == "list") && id == "" {
		fail(w, r, 400, "invalid_request", "Query requires `id` for this feed kind", false)
		return
	}
	filter := "all"
	if values, present := q["filter"]; present {
		filter = values[0]
	}
	if filter != "all" && filter != "read" && filter != "unread" {
		fail(w, r, 400, "invalid_request", "Invalid `filter`", false)
		return
	}
	limit, err := integer(r, "limit", 50, 1, 100)
	if err != nil {
		fail(w, r, 400, "invalid_request", "Invalid `limit`", false)
		return
	}
	cursor := q.Get("cursor")
	if _, present := q["cursor"]; present && kind != "list" {
		if _, err := appviewcore.DecodeEntryCursor(cursor); err != nil {
			fail(w, r, 400, "invalid_request", "Invalid `cursor`", false)
			return
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	started := time.Now()
	var page *appviewcore.FeedPage
	if kind == "list" {
		if a.ListFeed == nil {
			fail(w, r, 503, "feed_projection_warming", "The list projection is warming. Refresh to retry.", true)
			return
		}
		page, err = a.ListFeed(ctx, viewer, id, filter, cursor, limit, a.now())
		if errors.Is(err, listcore.ErrWarming) {
			fail(w, r, 503, "feed_projection_warming", "The list projection is warming. Refresh to retry.", true)
			return
		}
		if errors.Is(err, listcore.ErrIdentity) || errors.Is(err, listcore.ErrCursor) {
			fail(w, r, 400, "invalid_request", "Invalid list identity or cursor.", false)
			return
		}
		if errors.Is(err, listcore.ErrMissing) {
			fail(w, r, 404, "not_found", "The list is not available to this viewer.", false)
			return
		}
	} else {
		page, err = (appviewcore.FeedStore{DB: a.DB}).Feed(ctx, viewer.DID, kind, id, filter, cursor, limit, a.now())
		if err == nil && page == nil && a.RepairFeed != nil && a.RepairFeed(ctx, viewer.DID) {
			page, err = (appviewcore.FeedStore{DB: a.DB}).Feed(ctx, viewer.DID, kind, id, filter, cursor, limit, a.now())
		}
	}
	if err != nil {
		databaseError(w, r, err)
		return
	}
	if page == nil {
		var known bool
		err = a.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM appview_viewer_feeds WHERE viewer_did=$1) OR EXISTS(SELECT 1 FROM appview_publication_scopes WHERE viewer_did=$1)`, viewer.DID).Scan(&known)
		if err != nil {
			databaseError(w, r, err)
			return
		}
		if known {
			fail(w, r, 404, "feed_unavailable", "Feed is not available to this viewer.", false)
		} else {
			fail(w, r, 503, "feed_projection_warming", "The viewer feed projection is warming.", true)
		}
		return
	}
	w.Header().Set("X-AppView-Feed-Source", "materialized_projection")
	w.Header().Set("X-AppView-Membership-Updated-At", page.MembershipUpdatedAt.UTC().Format(time.RFC3339))
	w.Header().Set("Server-Timing", fmt.Sprintf("db;dur=%.1f, appview_feed;dur=%.1f", float64(page.DatabaseDuration)/float64(time.Millisecond), float64(time.Since(started))/float64(time.Millisecond)))
	respond(w, page.Response)
}

func (a Routes) entries(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	author := q.Get("authorDid")
	if author == "" {
		fail(w, r, 400, "invalid_request", "Query requires `authorDid`", false)
		return
	}
	limit, err := integer(r, "limit", 50, 1, 100)
	if err != nil {
		fail(w, r, 400, "invalid_request", "Invalid `limit`", false)
		return
	}
	filter := "all"
	if values, present := q["filter"]; present {
		filter = values[0]
	}
	if filter != "all" && filter != "read" && filter != "unread" {
		fail(w, r, 400, "invalid_request", "Invalid `filter`", false)
		return
	}
	cursor := q.Get("cursor")
	if _, present := q["cursor"]; present {
		if _, err := appviewcore.DecodeEntryCursor(cursor); err != nil {
			fail(w, r, 400, "invalid_request", "Invalid `cursor`", false)
			return
		}
	}
	publication := q.Get("publicationAtUri")
	query := appviewcore.EntryQuery{ViewerDID: viewer.DID, AuthorDID: author, PublicationID: publication, PublicationATURI: publication, ScopeATURIs: split(q.Get("publicationScopeAtUris")), SiteURLs: split(q.Get("publicationSiteUrls")), Filter: filter, Cursor: cursor, Limit: limit}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	reader := appviewcore.ContentReader{DB: a.DB}
	var page appviewcore.EntryPage
	if _, present := q["maxEntries"]; present {
		maximum, parseErr := integer(r, "maxEntries", 0, 1, 500)
		if parseErr != nil {
			fail(w, r, 400, "invalid_request", "Invalid `maxEntries`", false)
			return
		}
		if a.EntryPage != nil {
			page, err = a.EntryPage(ctx, viewer, query, maximum, a.now())
		} else {
			page, err = reader.EntriesUpTo(ctx, query, maximum, a.now())
		}
	} else {
		if a.EntryPage != nil {
			page, err = a.EntryPage(ctx, viewer, query, 0, a.now())
		} else {
			page, err = reader.Entries(ctx, query, a.now())
		}
	}
	if err != nil {
		databaseError(w, r, err)
		return
	}
	respond(w, page)
}

func (a Routes) entry(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	id := r.URL.Query().Get("entryId")
	if id == "" {
		fail(w, r, 400, "invalid_request", "Query requires `entryId`", false)
		return
	}
	entry, err := (appviewcore.ContentReader{DB: a.DB}).Item(r.Context(), viewer.DID, id, a.now())
	if err != nil {
		databaseError(w, r, err)
		return
	}
	if entry == nil {
		fail(w, r, 404, "not_found", "Entry not found in AppView index", false)
		return
	}
	var renderJSON []byte
	if err := a.DB.QueryRowContext(r.Context(), `SELECT render_json::text FROM content_items WHERE uri=$1 AND expires_at>$2`, id, a.now()).Scan(&renderJSON); err != nil {
		databaseError(w, r, err)
		return
	}
	var render map[string]any
	if err := json.Unmarshal(renderJSON, &render); err != nil {
		databaseError(w, r, err)
		return
	}
	body := map[string]any{"entryId": entry.EntryID, "title": entry.Title, "publishedAt": entry.PublishedAt.UTC().Format(time.RFC3339), "isRead": entry.IsRead}
	if entry.Summary != nil {
		body["summary"] = *entry.Summary
	}
	if entry.ThumbnailURL != nil {
		body["thumbnailUrl"] = *entry.ThumbnailURL
	}
	if entry.OriginalURL != nil {
		body["originalUrl"] = *entry.OriginalURL
	}
	if value, ok := render["contentHtml"].(string); ok {
		body["contentHtml"] = value
	} else if value, ok := render["summary"].(string); ok {
		body["contentHtml"] = value
	}
	respond(w, body)
}

func (a Routes) putRead(w http.ResponseWriter, r *http.Request)    { a.mutateRead(w, r, true) }
func (a Routes) deleteRead(w http.ResponseWriter, r *http.Request) { a.mutateRead(w, r, false) }
func (a Routes) mutateRead(w http.ResponseWriter, r *http.Request, read bool) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	var body struct {
		SubjectURI string     `json:"subjectUri"`
		ReadAt     *time.Time `json:"readAt"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	if err := decoder.Decode(&body); err != nil || body.SubjectURI == "" {
		fail(w, r, 400, "invalid_request", "Invalid read mark", false)
		return
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		fail(w, r, 400, "invalid_request", "Invalid read mark", false)
		return
	}
	at := a.now()
	if body.ReadAt != nil {
		at = *body.ReadAt
	}
	err := (appviewcore.ReadMutationStore{DB: a.DB}).Put(r.Context(), viewer.DID, body.SubjectURI, read, at)
	if errors.Is(err, appviewcore.ErrPDSReadStateRequired) {
		fail(w, r, 409, "Conflict", err.Error(), false)
		return
	}
	if err != nil {
		databaseError(w, r, err)
		return
	}
	if a.InvalidateRead != nil {
		if err := a.InvalidateRead(r.Context(), viewer.DID, body.SubjectURI); err != nil {
			databaseError(w, r, err)
			return
		}
	}
	if strings.HasPrefix(r.URL.Path, "/xrpc/") {
		respond(w, struct{}{})
	} else {
		w.WriteHeader(http.StatusOK)
	}
}

func (a Routes) purge(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	if err := (appviewcore.ReadMutationStore{DB: a.DB}).Purge(r.Context(), viewer.DID); err != nil {
		if errors.Is(err, appviewcore.ErrPDSReadStateRequired) {
			fail(w, r, 409, "Conflict", err.Error(), false)
		} else {
			databaseError(w, r, err)
		}
		return
	}
	for _, callback := range []func(context.Context, string) error{a.PurgeCircle, a.PurgeUnread} {
		if callback != nil {
			if err := callback(r.Context(), viewer.DID); err != nil {
				databaseError(w, r, err)
				return
			}
		}
	}
	if strings.HasPrefix(r.URL.Path, "/xrpc/") {
		respond(w, struct{}{})
	} else {
		w.WriteHeader(200)
	}
}

func split(raw string) []string {
	values := []string{}
	for _, value := range strings.Split(raw, ",") {
		if value = strings.TrimSpace(value); value != "" {
			values = append(values, value)
		}
	}
	return values
}
