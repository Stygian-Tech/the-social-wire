package operationsapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

type httpAPI struct {
	store  *PostgresStore
	config Config
}
type apiResult struct {
	value  any
	status int
}
type apiEndpoint func(*http.Request) (apiResult, error)

// All control-plane routes share the same validated OAuth/DPoP or signed Gateway
// trust and operator allowlist. Health endpoints expose no control-plane data.
func NewHandler(store *PostgresStore, config Config, auth gatewaycore.AuthConfig, client *http.Client) http.Handler {
	api := &httpAPI{store: store, config: config}
	protected := api.protectedRoutes()
	secured := gatewaycore.InternalTrustMiddleware(config.InternalSecret, false)(gatewaycore.AuthMiddleware(auth, client)(OperatorAuthorization(config.OperatorDIDs)(protected)))
	public := http.NewServeMux()
	for _, path := range []string{"/health", "/livez", "/readyz", "/freshness"} {
		public.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
			state := "ok"
			switch r.URL.Path {
			case "/livez":
				state = "live"
			case "/readyz":
				if err := store.Ping(r.Context()); err != nil {
					respondError(w, r, HTTPError{503, "Database unavailable"})
					return
				}
				state = "ready"
			case "/freshness":
				value, err := store.FetchStreamState(r.Context(), "jetstream")
				if err != nil {
					respondError(w, r, err)
					return
				}
				respondJSON(w, 200, map[string]any{"state": value, "checkedAt": time.Now()})
				return
			}
			respondJSON(w, 200, map[string]string{"status": state, "service": "operations"})
		})
	}
	public.Handle("/", secured)
	return public
}
func respondJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		writeError(w, 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}
func respondError(w http.ResponseWriter, r *http.Request, err error) {
	status := ErrorStatus(err)
	name := "InternalServerError"
	switch status {
	case 400, 409:
		name = "InvalidRequest"
	case 401:
		name = "AuthRequired"
	case 403:
		name = "Forbidden"
	case 404:
		name = "NotFound"
	case 429:
		name = "RateLimitExceeded"
	case 503:
		name = "ServiceUnavailable"
	}
	message := "The request is invalid."
	if status >= 500 {
		message = "The request could not be completed."
	}
	respondJSON(w, status, map[string]string{"error": name, "message": message})
}
func (a *httpAPI) register(mux *http.ServeMux, method, path, xrpc string, endpoint apiEndpoint) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result, err := endpoint(r)
		if err != nil {
			respondError(w, r, err)
			return
		}
		if result.status == 0 {
			result.status = 200
		}
		respondJSON(w, result.status, result.value)
	})
	mux.Handle(method+" "+path, handler)
	if xrpc != "" {
		xrpcMethod := method
		if method == "PATCH" {
			xrpcMethod = "POST"
		}
		mux.Handle(xrpcMethod+" /xrpc/app.thesocialwire.operations."+xrpc, handler)
	}
}
func (a *httpAPI) capabilities(r *http.Request) Capabilities {
	return ResolveCapabilities(r.Context(), a.store, a.config, time.Now())
}
func (a *httpAPI) protectedRoutes() http.Handler {
	mux := http.NewServeMux()
	a.register(mux, "GET", "/v1/operations/capabilities", "getCapabilities", func(r *http.Request) (apiResult, error) { return apiResult{value: a.capabilities(r)}, nil })
	a.register(mux, "GET", "/v1/operations/overview", "getOverview", func(r *http.Request) (apiResult, error) {
		c := a.capabilities(r)
		v, e := a.store.Overview(r.Context(), time.Now(), &c)
		return apiResult{value: v}, e
	})
	a.register(mux, "GET", "/v1/operations/services", "listServices", func(r *http.Request) (apiResult, error) {
		v, e := a.store.ListServiceStates(r.Context())
		return apiResult{value: map[string]any{"services": v, "evidence": ServiceEvidence(v, time.Now())}}, e
	})
	a.register(mux, "GET", "/v1/operations/appview", "getAppView", func(r *http.Request) (apiResult, error) {
		v, e := a.store.ListServiceStates(r.Context())
		if e != nil {
			return apiResult{}, e
		}
		selected := []ServiceState{}
		for _, s := range v {
			if s.Service == "gateway" || s.Service == "appview" {
				selected = append(selected, s)
			}
		}
		return apiResult{value: map[string]any{"services": selected, "evidence": ServiceEvidenceFor(selected, []string{"gateway", "appview"}, "operations_service_state.appview", time.Now(), 45*time.Second)}}, nil
	})
	a.register(mux, "GET", "/v1/operations/ingestion", "getIngestion", func(r *http.Request) (apiResult, error) {
		states, e := a.store.ListServiceStates(r.Context())
		if e != nil {
			return apiResult{}, e
		}
		streams, e := a.store.ListStreamStates(r.Context())
		if e != nil {
			return apiResult{}, e
		}
		snapshot, e := a.store.FetchIngestionDurabilitySnapshot(r.Context(), time.Now())
		var d *DurabilitySnapshot
		if e == nil {
			d = &snapshot
		}
		authority := ResolveIngestionAuthority(states, streams, d, time.Now())
		value := map[string]any{"sources": streams, "evidence": authority.Evidence}
		if authority.State != nil {
			value["state"] = authority.State
		}
		if d != nil {
			value["durability"] = d
		}
		return apiResult{value: value}, nil
	})
	a.register(mux, "GET", "/v1/operations/ingestion/durability", "getIngestionDurability", func(r *http.Request) (apiResult, error) {
		v, e := a.store.FetchIngestionDurabilitySnapshot(r.Context(), time.Now())
		return apiResult{value: v}, e
	})
	a.register(mux, "GET", "/v1/operations/ingestion/incidents", "listIngestionIncidents", func(r *http.Request) (apiResult, error) {
		limit, before, e := pageQuery(r, 250)
		if e != nil {
			return apiResult{}, e
		}
		page, e := a.store.ListIngestionIncidents(r.Context(), limit, before)
		var oldest *time.Time
		for _, v := range page.Items {
			if oldest == nil || v.UpdatedAt.Before(*oldest) {
				oldest = pointer(v.UpdatedAt.Time)
			}
		}
		return apiResult{value: pageResponse("incidents", page, "appview_ingestion_incidents", oldest, 5*time.Second, "No durable ingestion incidents are recorded.")}, e
	})
	a.register(mux, "GET", "/v1/operations/ingestion/endpoints", "listIngestionEndpoints", func(r *http.Request) (apiResult, error) {
		limit, before, e := pageQuery(r, 250)
		if e != nil {
			return apiResult{}, e
		}
		page, e := a.store.ListJetstreamEndpoints(r.Context(), limit, before)
		var oldest *time.Time
		for _, v := range page.Items {
			if oldest == nil || v.UpdatedAt.Before(*oldest) {
				oldest = pointer(v.UpdatedAt.Time)
			}
		}
		return apiResult{value: pageResponse("endpoints", page, "appview_jetstream_endpoints", oldest, 45*time.Second, "No Jetstream endpoint observations are available.")}, e
	})
	a.register(mux, "GET", "/v1/operations/commands", "listCommands", func(r *http.Request) (apiResult, error) {
		limit, before, e := pageQuery(r, 250)
		if e != nil {
			return apiResult{}, e
		}
		page, e := a.store.ListCommands(r.Context(), limit, before)
		return apiResult{value: pageResponse("commands", page, "operations_commands", pointer(time.Now()), 5*time.Second, "No command records are available.")}, e
	})
	a.register(mux, "GET", "/v1/operations/gaps", "listGaps", func(r *http.Request) (apiResult, error) {
		view, e := requestView(r, "active", "history", "all")
		if e != nil {
			return apiResult{}, e
		}
		limit, before, e := pageQuery(r, 250)
		if e != nil {
			return apiResult{}, e
		}
		page, e := a.store.ListGaps(r.Context(), view, limit, before)
		return apiResult{value: pageResponse("gaps", page, "appview_ingestion_gaps."+view, pointer(time.Now()), 5*time.Second, "No gap records exist in this lifecycle view.")}, e
	})
	a.register(mux, "GET", "/v1/operations/gaps/{id}/investigation", "getGapInvestigation", func(r *http.Request) (apiResult, error) {
		id, e := requestResourceID(r, "id")
		if e != nil {
			return apiResult{}, e
		}
		v, e := a.store.InvestigateGap(r.Context(), id)
		if e == nil && v == nil {
			e = ErrNotFound
		}
		return apiResult{value: v}, e
	})
	a.register(mux, "GET", "/v1/operations/backfills", "listBackfills", func(r *http.Request) (apiResult, error) {
		view, e := requestView(r, "active", "attention", "history", "all")
		if e != nil {
			return apiResult{}, e
		}
		limit, before, e := pageQuery(r, 250)
		if e != nil {
			return apiResult{}, e
		}
		page, e := a.store.ListBackfills(r.Context(), view, limit, before)
		return apiResult{value: pageResponse("backfills", page, "appview_backfill_jobs."+view, pointer(time.Now()), 5*time.Second, "No backfill jobs exist in this lifecycle view.")}, e
	})
	a.register(mux, "GET", "/v1/operations/backfills/{id}", "getBackfill", func(r *http.Request) (apiResult, error) {
		id, e := requestResourceID(r, "id")
		if e != nil {
			return apiResult{}, e
		}
		v, e := a.store.FetchBackfill(r.Context(), id)
		if e == nil && v == nil {
			e = ErrNotFound
		}
		return apiResult{value: v}, e
	})
	a.register(mux, "GET", "/v1/operations/alerts", "listAlerts", func(r *http.Request) (apiResult, error) {
		view, e := requestView(r, "active", "history", "all")
		if e != nil {
			return apiResult{}, e
		}
		limit, before, e := pageQuery(r, 250)
		if e != nil {
			return apiResult{}, e
		}
		page, e := a.store.ListAlerts(r.Context(), view, limit, before)
		return apiResult{value: pageResponse("alerts", page, "operations_alerts."+view, pointer(time.Now()), 5*time.Second, "No alerts exist in this lifecycle view.")}, e
	})
	a.registerTelemetry(mux)
	a.registerMutations(mux)
	mux.Handle("GET /v1/operations/events/stream", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c := a.capabilities(r)
		if !c.EventStream.Enabled {
			respondError(w, r, HTTPError{503, "The durable ordered event log is unavailable."})
			return
		}
		EventStreamHandler(a.store).ServeHTTP(w, r)
	}))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { respondError(w, r, HTTPError{404, "Not found"}) })
	return mux
}
func pageQuery(r *http.Request, max int) (int, *string, error) {
	limit, err := requestLimit(r, max)
	if err != nil {
		return 0, nil, err
	}
	before, err := requestBefore(r)
	return limit, before, err
}
func pageResponse[T any](key string, page Page[T], source string, indexed *time.Time, validity time.Duration, empty string) map[string]any {
	result := map[string]any{key: page.Items, "totalCount": page.TotalCount, "evidence": ListEvidence(source, len(page.Items), page.TotalCount, indexed, validity, empty, time.Now())}
	if page.NextCursor != nil {
		result["nextCursor"] = page.NextCursor
	}
	return result
}
func ListEvidence(source string, count, total int, indexed *time.Time, validity time.Duration, empty string, now time.Time) EvidenceMetadata {
	evidence := EvidenceMetadata{Source: source, Accuracy: "unavailable", GeneratedAt: WireTime{now}, ValidUntil: WireTime{now}, Coverage: pointer(0.0), DegradedReason: &empty}
	if indexed == nil {
		return evidence
	}
	evidence.Accuracy = "exact"
	evidence.IndexedThrough = pointer(WireTime{*indexed})
	evidence.LastSuccessfulAt = evidence.IndexedThrough
	evidence.AgeSeconds = max(0, now.Sub(*indexed).Seconds())
	evidence.ValidUntil = WireTime{indexed.Add(validity)}
	evidence.Coverage = pointer(evidenceCoverage(count, total))
	evidence.DegradedReason = nil
	if count < total {
		evidence.Accuracy = "sampled"
		reason := "The response is a paginated subset of the matching records."
		evidence.DegradedReason = &reason
	}
	return evidence
}
func isXRPC(r *http.Request) bool { return strings.HasPrefix(r.URL.Path, "/xrpc/") }
