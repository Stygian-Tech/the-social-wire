package publications

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"io"
	"net/http"
)

type Routes struct {
	Service  *publicationcore.Service
	Resolver publicationcore.Resolver
}

func (a Routes) Register(mux *http.ServeMux) {
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
	if a.Service.Enroller == nil {
		fail(w, 503, "Enrollment unavailable")
		return
	}
	n, e := a.Service.Enroller.Enroll(r.Context(), viewer, body.AuthorDIDs, body.FeedURLs, true)
	if e != nil {
		fail(w, 503, "Enrollment unavailable")
		return
	}
	if a.Service.Cache != nil {
		_ = a.Service.Cache.InvalidateSidebar(r.Context(), viewer.DID)
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
