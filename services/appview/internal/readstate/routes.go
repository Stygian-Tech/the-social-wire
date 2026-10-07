package readstate

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"io"
	"net/http"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
	r "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
)

type Routes struct {
	Store         *pdsreadstatecore.Store
	DB            *sql.DB
	ResolveScopes func(context.Context, gatewaycore.AuthContext, appviewcore.ReadScopeSelector) ([]appviewcore.PublicationScope, error)
	Invalidate    func(context.Context, string) error
}

func (a Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /xrpc/app.thesocialwire.appview.getReadStateStatus", a.status)
	mux.HandleFunc("POST /xrpc/app.thesocialwire.appview.exportReadState", a.export)
	mux.HandleFunc("POST /xrpc/app.thesocialwire.appview.confirmReadState", a.confirm)
	mux.HandleFunc("POST /xrpc/app.thesocialwire.appview.prepareReadState", a.prepare)
}

func viewer(w http.ResponseWriter, req *http.Request) (string, bool) {
	auth, ok := gatewaycore.AuthContextFrom(req.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		respondError(w, 401, "Unauthorized", "Authentication is required.")
		return "", false
	}
	return auth.DID, true
}

func decode(w http.ResponseWriter, req *http.Request, body any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, req.Body, 1<<20))
	if err := decoder.Decode(body); err != nil {
		respondError(w, 400, "InvalidRequest", "Invalid request body")
		return false
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		respondError(w, 400, "InvalidRequest", "Invalid request body")
		return false
	}
	return true
}

func (a Routes) status(w http.ResponseWriter, req *http.Request) {
	did, ok := viewer(w, req)
	if !ok {
		return
	}
	status, err := a.Store.Status(req.Context(), did)
	finish(w, status, err)
}

func (a Routes) export(w http.ResponseWriter, req *http.Request) {
	did, ok := viewer(w, req)
	if !ok {
		return
	}
	var body struct {
		Cursor                 *string `json:"cursor"`
		ExpectedLegacyRevision *int64  `json:"expectedLegacyRevision"`
		Limit                  *int    `json:"limit"`
	}
	if !decode(w, req, &body) {
		return
	}
	limit := 100
	if body.Limit != nil {
		limit = min(max(*body.Limit, 1), 500)
	}
	page, err := a.Store.Export(req.Context(), did, body.Cursor, body.ExpectedLegacyRevision, limit)
	finish(w, page, err)
}

func (a Routes) confirm(w http.ResponseWriter, req *http.Request) {
	did, ok := viewer(w, req)
	if !ok {
		return
	}
	var body struct {
		ManifestCID            string `json:"manifestCid"`
		ExpectedLegacyRevision *int64 `json:"expectedLegacyRevision"`
	}
	if !decode(w, req, &body) {
		return
	}
	if body.ManifestCID == "" || len(body.ManifestCID) > 256 {
		respondError(w, 400, "InvalidRequest", "manifestCid is required")
		return
	}
	status, err := a.Store.Confirm(req.Context(), did, body.ManifestCID, body.ExpectedLegacyRevision)
	if err == nil && a.Invalidate != nil {
		err = a.Invalidate(req.Context(), did)
	}
	finish(w, status, err)
}

func finish(w http.ResponseWriter, body any, err error) {
	w.Header().Set("Cache-Control", "no-store")
	if err == nil {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(body)
		return
	}
	if errors.Is(err, pdsreadstatecore.ErrInvalidCursor) {
		respondError(w, 400, "InvalidRequest", "Invalid read-state cursor")
		return
	}
	if errors.Is(err, pdsreadstatecore.ErrLegacyScopeOverlap) {
		respondError(w, 409, "ReadStateMigrationScopeConflict", "Overlapping publications have different read boundaries. Your existing read state is preserved; reconcile those boundaries before retrying migration.")
		return
	}
	if errors.Is(err, pdsreadstatecore.ErrStaleGeneration) || errors.Is(err, pdsreadstatecore.ErrRevisionChanged) || errors.Is(err, pdsreadstatecore.ErrParityMismatch) || errors.Is(err, pdsreadstatecore.ErrAlreadyMigrated) || errors.Is(err, pdsreadstatecore.ErrLegacyScopeUnavailable) || errors.Is(err, r.ErrInvalidRecord) || errors.Is(err, r.ErrIncompleteGeneration) || errors.Is(err, r.ErrInvalidReference) || errors.Is(err, r.ErrSizeLimit) || errors.Is(err, r.ErrConflictingSequence) {
		respondError(w, 409, "Conflict", "Read-state generation is invalid, changed or incomplete")
		return
	}
	respondError(w, 503, "ServiceUnavailable", "Read-state verification is unavailable")
}

func respondError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": code, "message": message})
}
