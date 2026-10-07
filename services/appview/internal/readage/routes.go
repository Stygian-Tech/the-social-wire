package readage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/readagecore"
)

type Routes struct {
	DB            *sql.DB
	Now           func() time.Time
	ResolveScopes func(context.Context, gatewaycore.AuthContext, appviewcore.ReadScopeSelector) ([]appviewcore.PublicationScope, error)
	RefreshCounts func(context.Context, string, []appviewcore.PublicationScope, time.Time) (map[string]int, error)
	Invalidate    func(context.Context, string, []string) error
}

func (a Routes) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /xrpc/app.thesocialwire.appview.getReadAgeOptions", a.options)
	mux.HandleFunc("POST /xrpc/app.thesocialwire.appview.markReadBefore", a.markBefore)
	for _, path := range []string{"/v1/appview/mark-all-read", "/xrpc/app.thesocialwire.appview.markAllRead"} {
		mux.HandleFunc("POST "+path, a.markAll)
	}
}
func (a Routes) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}
func auth(w http.ResponseWriter, req *http.Request) (gatewaycore.AuthContext, bool) {
	auth, ok := gatewaycore.AuthContextFrom(req.Context())
	if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
		fail(w, 401, "Authentication is required")
		return gatewaycore.AuthContext{}, false
	}
	return auth, true
}
func fail(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": http.StatusText(status), "message": message})
}
func writeJSON(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(body)
}
func decode(w http.ResponseWriter, req *http.Request, body any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, req.Body, 1<<20))
	if decoder.Decode(body) != nil {
		fail(w, 400, "Invalid request body")
		return false
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		fail(w, 400, "Invalid request body")
		return false
	}
	return true
}
func (a Routes) legacy(w http.ResponseWriter, req *http.Request, viewer string) bool {
	pds, err := (appviewcore.ReadStateStore{DB: a.DB}).PDSAuthority(req.Context(), viewer)
	if err != nil {
		fail(w, 503, "Read-state projection is unavailable")
		return false
	}
	if pds {
		fail(w, 409, "PDSReadStateRequired: Update your client to change PDS read state")
		return false
	}
	return true
}
func (a Routes) options(w http.ResponseWriter, req *http.Request) {
	viewer, ok := auth(w, req)
	if !ok {
		return
	}
	q := req.URL.Query()
	scope := appviewcore.ReadScopeSelector{Kind: q.Get("kind")}
	if value, present := q["publicationId"]; present {
		scope.PublicationID = &value[0]
	}
	if value, present := q["folderRkey"]; present {
		scope.FolderRKey = &value[0]
	}
	if scope.Validate() != nil {
		fail(w, 400, "Unsupported or incomplete read scope")
		return
	}
	now := a.now()
	accumulator, err := readagecore.NewAccumulator(q.Get("timeZone"), now)
	if err != nil {
		fail(w, 400, "timeZone must be an IANA time zone identifier")
		return
	}
	scopes, err := a.ResolveScopes(req.Context(), viewer, scope)
	if err != nil {
		fail(w, 503, "Publication projection is unavailable")
		return
	}
	stream := strings.Contains(req.Header.Get("Accept"), "application/x-ndjson")
	if stream {
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.Header().Set("Cache-Control", "no-cache")
	}
	err = (appviewcore.ContentReader{DB: a.DB}).WalkUnread(req.Context(), viewer.DID, scopes, 1000, now, func(entries []appviewcore.UnreadMutationEntry) error {
		dates := make([]time.Time, len(entries))
		for i, entry := range entries {
			dates[i] = entry.PublishedAt
		}
		accumulator.Append(dates)
		if stream {
			response := accumulator.Response()
			return writeEvent(w, map[string]any{"type": "options", "options": response.Options, "referenceDay": response.ReferenceDay})
		}
		return nil
	})
	if !stream {
		if err != nil {
			fail(w, 503, "Couldn't load read-age options.")
			return
		}
		writeJSON(w, accumulator.Response())
		return
	}
	if req.Context().Err() != nil {
		return
	}
	if err != nil {
		_ = writeEvent(w, map[string]string{"type": "error", "message": "Couldn't load read-age options."})
		return
	}
	_ = writeEvent(w, map[string]string{"type": "done"})
}
func writeEvent(w http.ResponseWriter, event any) error {
	if err := json.NewEncoder(w).Encode(event); err != nil {
		return err
	}
	return http.NewResponseController(w).Flush()
}

func (a Routes) markBefore(w http.ResponseWriter, req *http.Request) {
	viewer, ok := auth(w, req)
	if !ok {
		return
	}
	var body struct {
		Scope  appviewcore.ReadScopeSelector `json:"scope"`
		Before string                        `json:"before"`
	}
	if !decode(w, req, &body) {
		return
	}
	now := a.now()
	cutoff, err := readagecore.Cutoff(body.Before, now)
	if body.Scope.Validate() != nil || err != nil {
		fail(w, 400, "Invalid scope or before timestamp")
		return
	}
	if !a.legacy(w, req, viewer.DID) {
		return
	}
	scopes, err := a.ResolveScopes(req.Context(), viewer, body.Scope)
	if err != nil {
		fail(w, 503, "Publication projection is unavailable")
		return
	}
	ids := []string{}
	err = (appviewcore.ContentReader{DB: a.DB}).WalkUnread(req.Context(), viewer.DID, scopes, 1000, now, func(entries []appviewcore.UnreadMutationEntry) error {
		for _, entry := range entries {
			if entry.PublishedAt.Before(cutoff) {
				ids = append(ids, entry.EntryID)
			}
		}
		return nil
	})
	if err != nil {
		fail(w, 503, "Read-state snapshot is unavailable")
		return
	}
	if err := (appviewcore.ReadMutationStore{DB: a.DB}).PutMany(req.Context(), viewer.DID, ids, now); err != nil {
		if errors.Is(err, appviewcore.ErrPDSReadStateRequired) {
			fail(w, 409, err.Error())
		} else {
			fail(w, 503, "Read marks could not be saved")
		}
		return
	}
	counts := map[string]int{}
	if a.RefreshCounts != nil {
		if refreshed, err := a.RefreshCounts(req.Context(), viewer.DID, scopes, now); err == nil {
			counts = refreshed
		}
	}
	// The marks are committed. Recount/invalidation failures must not discard
	// successful IDs or manufacture count claims; dirty counters repair later.
	if a.Invalidate != nil {
		for _, scope := range scopes {
			_ = a.Invalidate(req.Context(), viewer.DID, []string{scope.PublicationID})
		}
	}
	writeJSON(w, map[string]any{"marked": len(ids), "entryIds": ids, "readAt": readagecore.Timestamp(now), "unreadCounts": counts})
}

func (a Routes) markAll(w http.ResponseWriter, req *http.Request) {
	viewer, ok := auth(w, req)
	if !ok {
		return
	}
	var body struct {
		Scope appviewcore.ReadScopeSelector `json:"scope"`
	}
	if !decode(w, req, &body) {
		return
	}
	if !a.legacy(w, req, viewer.DID) {
		return
	}
	scopes, err := a.ResolveScopes(req.Context(), viewer, body.Scope)
	if err != nil {
		fail(w, 503, "Publication projection is unavailable")
		return
	}
	ids := []string{}
	for _, scope := range scopes {
		ids = append(ids, scope.PublicationID)
	}
	marked := 0
	if rows, err := a.DB.QueryContext(req.Context(), `SELECT unread_count FROM appview_unread_counters WHERE viewer_did=$1 AND publication_id=ANY($2::text[])`, viewer.DID, ids); err == nil {
		for rows.Next() {
			var count int
			if rows.Scan(&count) == nil {
				marked += count
			}
		}
		rows.Close()
	}
	now := a.now()
	result, err := (appviewcore.ReadMutationStore{DB: a.DB}).MarkAll(req.Context(), viewer.DID, scopes, now)
	if err != nil {
		if errors.Is(err, appviewcore.ErrPDSReadStateRequired) {
			fail(w, 409, err.Error())
		} else {
			fail(w, 503, "Read boundaries could not be saved")
		}
		return
	}
	if a.Invalidate != nil {
		if err := a.Invalidate(req.Context(), viewer.DID, ids); err != nil {
			fail(w, 503, "Read boundaries saved; projection refresh failed")
			return
		}
	}
	counts := map[string]int{}
	for _, counter := range result.Counters {
		counts[counter.PublicationID] = counter.UnreadCount
	}
	writeJSON(w, map[string]any{"marked": marked, "confirmedAt": now.UTC().Format(time.RFC3339), "boundaries": result.Boundaries, "unreadCounts": counts})
}
