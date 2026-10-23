package publications

import (
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"io"
	"net/http"
	"time"
)

type Routes struct {
	Service  *publicationcore.Service
	Resolver publicationcore.Resolver
	Articles *publicationcore.ArticleResolver
}

func (a Routes) Register(mux *http.ServeMux) {
	for _, path := range []string{"/v1/publications/article-embed", "/xrpc/app.thesocialwire.publication.getArticleEmbed"} {
		mux.HandleFunc("GET "+path, a.articleEmbed)
	}
	for _, path := range []string{"/v1/publications/sidebar", "/xrpc/app.thesocialwire.publication.getSidebar"} {
		mux.HandleFunc("GET "+path, a.sidebar)
	}
	for _, path := range []string{"/v1/publications/refresh", "/xrpc/app.thesocialwire.publication.refreshSidebar"} {
		mux.HandleFunc("POST "+path, a.refresh)
	}
	for _, path := range []string{"/v1/publications/resolve", "/xrpc/app.thesocialwire.publication.resolvePublication"} {
		mux.HandleFunc("POST "+path, a.resolve)
	}
	for _, path := range []string{"/v1/appview/enroll", "/xrpc/app.thesocialwire.appview.enrollSources"} {
		mux.HandleFunc("POST "+path, a.enroll)
	}
	mux.HandleFunc("GET /v1/appview/bootstrap-stream", a.bootstrap)
}
func auth(w http.ResponseWriter, r *http.Request) (gatewaycore.AuthContext, bool) {
	v, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || v.DID == "" || v.DID == gatewaycore.AnonymousDiscoveryDID {
		fail(w, 401, "Authentication is required")
		return v, false
	}
	return v, true
}
func fail(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": http.StatusText(status), "message": message})
}
func write(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(value)
}
func decode(w http.ResponseWriter, r *http.Request, value any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	if d.Decode(value) != nil {
		fail(w, 400, "Invalid request body")
		return false
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		fail(w, 400, "Invalid request body")
		return false
	}
	return true
}
func (a Routes) sidebar(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	phase := r.URL.Query().Get("phase")
	if phase != "priority" && phase != "folderPublications" {
		phase = "full"
	}
	value, e := a.Service.Sidebar(r.Context(), viewer, phase)
	if e != nil {
		fail(w, 503, "Publication projection unavailable")
		return
	}
	write(w, value)
}
func (a Routes) refresh(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	value, e := a.Service.Refresh(r.Context(), viewer)
	if e != nil {
		fail(w, 503, "Publication projection unavailable")
		return
	}
	write(w, value)
}
func (a Routes) resolve(w http.ResponseWriter, r *http.Request) {
	_, ok := auth(w, r)
	if !ok {
		return
	}
	var body struct {
		Input string `json:"input"`
	}
	if !decode(w, r, &body) {
		return
	}
	write(w, a.Resolver.Resolve(r.Context(), body.Input))
}
func (a Routes) enroll(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	var body struct {
		AuthorDIDs []string `json:"authorDids"`
		FeedURLs   []string `json:"feedUrls"`
	}
	if !decode(w, r, &body) {
		return
	}
	started := time.Now()
	if a.Service.Enroller == nil {
		logEnrollmentFailure("enroll", started, len(body.AuthorDIDs), len(body.FeedURLs), 0, thinappviewcore.WrapEnrollmentFailure("unavailable", "", 0, errors.New("enroller unavailable")), r.Context().Err())
		fail(w, 503, "Enrollment unavailable")
		return
	}
	n, e := a.Service.Enroller.Enroll(r.Context(), viewer, body.AuthorDIDs, body.FeedURLs, true)
	enrollmentErr := e
	if enrollmentErr == nil {
		enrollmentErr = r.Context().Err()
	}
	logEnrollmentFailure("enroll", started, len(body.AuthorDIDs), len(body.FeedURLs), n, enrollmentErr, r.Context().Err())
	if r.Context().Err() != nil {
		fail(w, 503, "Enrollment unavailable")
		return
	}
	if a.Service.Cache != nil {
		_ = a.Service.Cache.InvalidateSidebar(r.Context(), viewer.DID)
	}
	started = time.Now()
	if e := a.Service.RefreshEnrollmentCounters(r.Context(), viewer.DID, body.AuthorDIDs, body.FeedURLs); e != nil {
		logEnrollmentFailure("counters", started, len(body.AuthorDIDs), len(body.FeedURLs), n, e, r.Context().Err())
		fail(w, 503, "Enrollment counters unavailable")
		return
	}
	// A failed source can leave other sources committed. Publish their fresh counts
	// before reporting partial failure so the reader can reconcile those articles.
	if e != nil {
		fail(w, 503, "Enrollment unavailable")
		return
	}
	write(w, map[string]int{"indexed": n})
}
func (a Routes) bootstrap(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-cache")
	controller := http.NewResponseController(w)
	_ = a.Service.Bootstrap(r.Context(), viewer, r.URL.Query().Get("includeLists") == "true", func(event map[string]any) error {
		if e := json.NewEncoder(w).Encode(event); e != nil {
			return e
		}
		return controller.Flush()
	})
}

func (a Routes) articleEmbed(w http.ResponseWriter, r *http.Request) {
	if _, ok := auth(w, r); !ok {
		return
	}
	if a.Articles == nil {
		fail(w, 503, "Article discovery unavailable")
		return
	}
	value, err := a.Articles.Resolve(r.Context(), r.URL.Query().Get("url"))
	if err != nil {
		status := 502
		if errors.Is(err, publicationcore.ErrArticleURL) {
			status = 400
		}
		if errors.Is(err, publicationcore.ErrArticleNotFound) {
			status = 404
		}
		fail(w, status, "Verified article unavailable")
		return
	}
	w.Header().Set("Cache-Control", "private, max-age=300")
	write(w, value)
}
