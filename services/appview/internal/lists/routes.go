package lists

import (
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/listcore"
	"io"
	"net/http"
)

type Routes struct{ Runtime *listcore.Runtime }

func (a Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/lists", a.list)
	mux.HandleFunc("GET /v1/lists/search", a.search)
	mux.HandleFunc("POST /v1/lists/resolve", a.resolve)
	mux.HandleFunc("POST /v1/lists/refresh", a.refresh)
}
func auth(w http.ResponseWriter, r *http.Request) (gatewaycore.AuthContext, bool) {
	auth, ok := gatewaycore.AuthContextFrom(r.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		fail(w, 401, "Authentication is required")
		return auth, false
	}
	return auth, true
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
func failure(w http.ResponseWriter, e error) {
	switch {
	case errors.Is(e, listcore.ErrInvalidInput):
		fail(w, 400, "Enter a Standard Reader list URL or canonical list AT URI.")
	case errors.Is(e, listcore.ErrNotFound):
		fail(w, 404, "List was not found or its record is invalid.")
	default:
		fail(w, 503, "Lists projection unavailable")
	}
}
func (a Routes) list(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	response, e := a.Runtime.Service.Lists(r.Context(), viewer.DID, false)
	if e != nil {
		failure(w, e)
		return
	}
	write(w, response)
}
func (a Routes) refresh(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	response, e := a.Runtime.Service.Lists(r.Context(), viewer.DID, true)
	if e != nil {
		failure(w, e)
		return
	}
	write(w, response)
}
func (a Routes) search(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	creator, present := r.URL.Query()["creator"]
	if !present || len(creator) != 1 {
		fail(w, 400, "Query requires creator handle or DID.")
		return
	}
	response, e := a.Runtime.Service.Search(r.Context(), creator[0], viewer.DID)
	if e != nil {
		failure(w, e)
		return
	}
	write(w, response)
}
func (a Routes) resolve(w http.ResponseWriter, r *http.Request) {
	viewer, ok := auth(w, r)
	if !ok {
		return
	}
	var body struct {
		Input string `json:"input"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	if decoder.Decode(&body) != nil {
		fail(w, 400, "Invalid request body")
		return
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		fail(w, 400, "Invalid request body")
		return
	}
	list, e := a.Runtime.Service.Resolve(r.Context(), body.Input, viewer.DID)
	if e != nil {
		failure(w, e)
		return
	}
	write(w, map[string]any{"list": list})
}
