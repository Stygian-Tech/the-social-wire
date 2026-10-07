package unreadcounts

import (
	"context"
	"database/sql"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"net/http"
	"strings"
	"time"
)

type Routes struct {
	DB           *sql.DB
	Publications *publicationcore.Service
	Now          func() time.Time
}

func (a Routes) Register(mux *http.ServeMux) {
	for _, path := range []string{"/v1/appview/unread-counts", "/xrpc/app.thesocialwire.appview.getUnreadCounts"} {
		mux.HandleFunc("GET "+path, a.handle)
	}
}
func split(raw string) []string {
	out := []string{}
	for _, s := range strings.Split(raw, ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}
func first(values map[string][]string, key string) *string {
	if v, ok := values[key]; ok && len(v) > 0 {
		return &v[0]
	}
	return nil
}
func (a Routes) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		failure(w, 401, "Authentication is required.")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	q := r.URL.Query()
	ids := []string{}
	for _, v := range q["publicationIds"] {
		ids = append(ids, split(v)...)
	}
	var out appviewcore.UnreadCountsResponse
	if len(ids) > 0 {
		snapshot, err := a.Publications.UnreadCountsByPublicationIDs(ctx, auth, ids)
		if err != nil {
			failure(w, 503, "Unread count projection unavailable.")
			return
		}
		out = appviewcore.UnreadCountsResponse{Counts: snapshot.Counts, Generation: &snapshot.Generation, Accuracy: &snapshot.Accuracy, CountedAt: &snapshot.CountedAt}
	} else {
		author := auth.DID
		if input := first(q, "authorDid"); input != nil {
			author = *input
		}
		uri := first(q, "publicationAtUri")
		scope := appviewcore.PublicationScope{AuthorDID: author, PublicationATURI: uri, PublicationScopeATURIs: split(q.Get("publicationScopeAtUris")), PublicationSiteURLs: split(q.Get("publicationSiteUrls"))}
		at := time.Now()
		if a.Now != nil {
			at = a.Now()
		}
		count, err := (appviewcore.ContentReader{DB: a.DB}).ScopedUnreadCount(ctx, auth.DID, scope, at)
		if err != nil {
			failure(w, 503, "Unread count projection unavailable.")
			return
		}
		key := author
		if uri != nil {
			key = *uri
		}
		out.Counts = map[string]int{key: count}
	}
	json.NewEncoder(w).Encode(out)
}
func failure(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": http.StatusText(status), "message": message})
}
