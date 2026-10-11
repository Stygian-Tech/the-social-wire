package analytics

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/analyticscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"strconv"
	"time"
)

type Storage interface {
	Save(context.Context, string, []analyticscore.Item, bool, time.Time) error
	Record(context.Context, string, string, analyticscore.Event, time.Time) error
	Summary(context.Context, string, int, int, string, time.Time) (analyticscore.Summary, error)
}
type Content interface {
	Inventory(context.Context, string, time.Time) ([]analyticscore.Item, bool, error)
	Validate(context.Context, string) error
}
type Routes struct {
	Store    Storage
	Provider Content
	Now      func() time.Time
	Limits   *Limits
}

func (a Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/analytics/summary", a.handle)
	mux.HandleFunc("POST /v1/analytics/refresh", a.handle)
	mux.HandleFunc("POST /v1/analytics/events", a.handle)
}
func failure(w http.ResponseWriter, status int, message string) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
func (a Routes) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		failure(w, 401, "Authentication Required")
		return
	}
	now := time.Now()
	if a.Now != nil {
		now = a.Now()
	}
	maximum := 120
	if r.URL.Path == "/v1/analytics/refresh" {
		maximum = 1
	}
	if a.Limits != nil && !a.Limits.Allow(auth.DID+"\x00"+r.URL.Path, now, maximum) {
		failure(w, 429, "Analytics Request Limit Reached")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	if r.URL.Path == "/v1/analytics/events" {
		var event analyticscore.Event
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&event) != nil || event.Event != "impression" && event.Event != "view" && event.Event != "outbound_click" || event.Surface != "social-feed" && event.Surface != "article-feed" && event.Surface != "post-viewer" && event.Surface != "article-reader" && event.Surface != "messages" {
			failure(w, 400, "Invalid Analytics Observation")
			return
		}
		author, _, _, e := analyticscore.Subject(event.SubjectURI)
		if e != nil {
			failure(w, 400, "Invalid Subject")
			return
		}
		if author == auth.DID {
			w.WriteHeader(202)
			return
		}
		if e = a.Provider.Validate(ctx, event.SubjectURI); e != nil {
			failure(w, 422, "Canonical Content Unavailable")
			return
		}
		if e = a.Store.Record(ctx, auth.DID, author, event, now); e != nil {
			if errors.Is(e, analyticscore.ErrRateLimit) {
				failure(w, 429, "Analytics Observation Limit Reached")
			} else {
				failure(w, 503, "Analytics Unavailable")
			}
			return
		}
		w.WriteHeader(202)
		return
	}
	days, limit := 30, 50
	for key, target := range map[string]*int{"days": &days, "limit": &limit} {
		if raw := r.URL.Query().Get(key); raw != "" {
			n, e := strconv.Atoi(raw)
			maximum := 90
			if key == "limit" {
				maximum = 100
			}
			if e != nil || n < 1 || n > maximum {
				failure(w, 400, "Invalid Analytics Range")
				return
			}
			*target = n
		}
	}
	cursor := r.URL.Query().Get("cursor")
	if cursor != "" {
		owner, _, _, e := analyticscore.Subject(cursor)
		if e != nil || owner != auth.DID {
			failure(w, 400, "Invalid Analytics Cursor")
			return
		}
	}
	if r.URL.Path == "/v1/analytics/refresh" {
		items, complete, e := a.Provider.Inventory(ctx, auth.DID, now)
		if e != nil {
			failure(w, 502, "Analytics Provider Unavailable")
			return
		}
		if e = a.Store.Save(ctx, auth.DID, items, complete, now); e != nil {
			failure(w, 503, "Analytics Unavailable")
			return
		}
	}
	out, e := a.Store.Summary(ctx, auth.DID, days, limit, cursor, now)
	if e != nil {
		failure(w, 503, "Analytics Unavailable")
		return
	}
	_ = json.NewEncoder(w).Encode(out)
}
