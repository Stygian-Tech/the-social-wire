package operationsapi

import (
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/http"
	"strconv"
	"time"
	"unicode/utf8"
)

func (a *httpAPI) auditScope(r *http.Request, action, target string, id *string) *MutationAuditScope {
	auth, _ := gatewaycore.AuthContextFrom(r.Context())
	requestID := r.Header.Get("X-Request-ID")
	if requestID == "" {
		requestID, _ = randomUUID()
	}
	requestID = boundedText(requestID, 128)
	var header *string
	if r.Header.Get("Idempotency-Key") != "" {
		header = pointer(r.Header.Get("Idempotency-Key"))
	}
	return NewMutationAuditScope(auth.DID, requestID, action, target, id, header)
}
func (a *httpAPI) audited(r *http.Request, scope *MutationAuditScope, operation func() (apiResult, error)) (apiResult, error) {
	return AuditedMutation(r.Context(), scope, a.store.RecordAudit, operation, ErrorStatus)
}
func mutationID(r *http.Request, body OperatorMutationRequest) (string, error) {
	if isXRPC(r) {
		if body.ID == nil || *body.ID == "" {
			return "", HTTPError{400, "id is required"}
		}
		return *body.ID, nil
	}
	id := r.PathValue("id")
	if id == "" {
		return "", HTTPError{400, "id is required"}
	}
	return id, nil
}
func (a *httpAPI) registerMutations(mux *http.ServeMux) {
	a.register(mux, "PATCH", "/v1/operations/gaps/{id}", "updateGap", func(r *http.Request) (apiResult, error) {
		scope := a.auditScope(r, "gap.mutation_attempt", "gap", optionalPathID(r))
		return a.audited(r, scope, func() (apiResult, error) {
			var body OperatorMutationRequest
			if e := decodeRequest(r, &body, "status", "idempotencyKey", "expectedVersion"); e != nil {
				return apiResult{}, e
			}
			scope.Update(pointer("gap."+body.Status), &body.IdempotencyKey, body.ExpectedVersion, body.AuditNote)
			id, e := mutationID(r, body)
			if e != nil {
				return apiResult{}, e
			}
			scope.Audit.TargetID = &id
			if !knownGapStatus(body.Status) {
				return apiResult{}, HTTPError{400, "Unknown gap status"}
			}
			if e = validateMutation(a.config, r, body.IdempotencyKey, body.ExpectedVersion, body.AuditNote, body.EnvironmentConfirmation); e != nil {
				return apiResult{}, e
			}
			if e = requireCapability(a.capabilities(r).Recovery); e != nil {
				return apiResult{}, e
			}
			current, e := a.store.FetchGap(r.Context(), id)
			if e != nil {
				return apiResult{}, e
			}
			if current != nil {
				scope.Audit.Before = versionedState(current.Status, current.Version)
			}
			v, e := a.store.TransitionGap(r.Context(), id, body.Status, *body.ExpectedVersion, scope.Audit.OperatorDID, body.IdempotencyKey, &scope.Audit.RequestID, body.AuditNote, time.Now())
			return apiResult{value: v}, e
		})
	})
	a.register(mux, "POST", "/v1/operations/ingestion/reconnect", "reconnectIngestion", func(r *http.Request) (apiResult, error) {
		scope := a.auditScope(r, "jetstream.reconnect_requested", "command", nil)
		return a.audited(r, scope, func() (apiResult, error) {
			var body OperatorMutationRequest
			if e := decodeRequest(r, &body, "idempotencyKey", "expectedVersion"); e != nil {
				return apiResult{}, e
			}
			scope.Update(nil, &body.IdempotencyKey, body.ExpectedVersion, body.AuditNote)
			if e := validateMutation(a.config, r, body.IdempotencyKey, body.ExpectedVersion, body.AuditNote, body.EnvironmentConfirmation); e != nil {
				return apiResult{}, e
			}
			if e := requireCapability(a.capabilities(r).Recovery); e != nil {
				return apiResult{}, e
			}
			services, e := a.store.ListServiceStates(r.Context())
			if e != nil {
				return apiResult{}, e
			}
			state, e := a.store.FetchStreamState(r.Context(), "jetstream")
			if e != nil {
				return apiResult{}, e
			}
			streams := []StreamState{}
			if state != nil {
				streams = append(streams, *state)
			}
			authority := ResolveIngestionAuthority(services, streams, nil, time.Now())
			if authority.Source != nil && *authority.Source == DurableJetstreamV2AuthoritySource {
				return apiResult{}, HTTPError{409, "Legacy Jetstream reconnect is unavailable under durable ingestion authority"}
			}
			scope.Audit.Before = map[string]string{"connectionState": "unknown", "version": "0"}
			if state != nil {
				scope.Audit.Before = versionedState(state.ConnectionState, state.Version)
			}
			v, e := a.store.CreateCommand(r.Context(), "reconnect_jetstream", scope.Audit.OperatorDID, body.AuditNote, *body.ExpectedVersion, body.IdempotencyKey, &scope.Audit.RequestID, time.Now())
			return apiResult{value: v, status: 202}, e
		})
	})
	a.register(mux, "POST", "/v1/operations/backfills/dry-run", "dryRunBackfill", func(r *http.Request) (apiResult, error) {
		var body BackfillDryRunRequest
		if e := decodeRequest(r, &body, "sourceMode", "collections", "authorDids", "batchSize", "rateLimit", "maxConcurrency"); e != nil {
			return apiResult{}, e
		}
		normalized, e := validateDryRunFields(body)
		if e != nil {
			return apiResult{}, e
		}
		if e = requireMode(normalized.SourceMode, a.capabilities(r)); e != nil {
			return apiResult{}, e
		}
		v, e := a.store.EstimateBackfill(r.Context(), normalized, time.Now())
		return apiResult{value: v}, e
	})
	a.register(mux, "POST", "/v1/operations/backfills", "createBackfill", func(r *http.Request) (apiResult, error) {
		scope := a.auditScope(r, "backfill.queued", "backfill", nil)
		return a.audited(r, scope, func() (apiResult, error) {
			var body CreateBackfillRequest
			if e := decodeRequest(r, &body, "dryRun", "expectedEstimate", "idempotencyKey", "requestFingerprint"); e != nil {
				return apiResult{}, e
			}
			scope.Update(nil, &body.IdempotencyKey, body.ExpectedGapVersion, body.AuditNote)
			normalized, e := validateDryRunFields(body.DryRun)
			if e != nil {
				return apiResult{}, e
			}
			body.DryRun = normalized
			if e = validateMutationKey(a.config, r, body.IdempotencyKey, body.EnvironmentConfirmation); e != nil {
				return apiResult{}, e
			}
			if body.AuditNote != nil && utf8.RuneCountInString(*body.AuditNote) > 280 {
				return apiResult{}, HTTPError{400, "Audit note is too long"}
			}
			if body.RequestFingerprint == "" || normalized.GapID != nil && body.ExpectedGapVersion == nil || body.ExpectedGapVersion != nil && *body.ExpectedGapVersion < 0 {
				return apiResult{}, HTTPError{400, "Backfill fingerprint and gap version are required"}
			}
			if e = requireMode(normalized.SourceMode, a.capabilities(r)); e != nil {
				return apiResult{}, e
			}
			estimate, e := a.store.EstimateBackfill(r.Context(), normalized, time.Now())
			if e != nil {
				return apiResult{}, e
			}
			if len(estimate.Conflicts) > 0 || estimate.EstimatedCount != body.ExpectedEstimate {
				return apiResult{}, HTTPError{409, "Dry-run scope or estimate changed; review it again"}
			}
			if normalized.GapID != nil {
				gap, e := a.store.FetchGap(r.Context(), *normalized.GapID)
				if e != nil {
					return apiResult{}, e
				}
				if gap != nil {
					scope.Audit.Before = versionedState(gap.Status, gap.Version)
				}
			}
			v, e := a.store.CreateBackfill(r.Context(), body, scope.Audit.OperatorDID, &scope.Audit.RequestID, time.Now())
			return apiResult{value: v, status: 201}, e
		})
	})
	for _, action := range []struct{ path, method, status string }{{"pause", "pauseBackfill", "paused"}, {"resume", "resumeBackfill", "queued"}, {"cancel", "cancelBackfill", "cancelled"}} {
		a.registerAction(mux, "backfills", "backfill", action.path, action.method, action.status, 200, true)
	}
	for _, action := range []struct{ path, method, status string }{{"acknowledge", "acknowledgeAlert", "acknowledged"}, {"resolve", "resolveAlert", "resolved"}, {"retry", "retryAlert", "delivery_retry"}} {
		status := 200
		if action.path == "retry" {
			status = 202
		}
		a.registerAction(mux, "alerts", "alert", action.path, action.method, action.status, status, false)
	}
}
func (a *httpAPI) registerAction(mux *http.ServeMux, collection, target, path, method, status string, httpStatus int, recovery bool) {
	a.register(mux, "POST", "/v1/operations/"+collection+"/{id}/"+path, method, func(r *http.Request) (apiResult, error) {
		auditAction := path
		if path == "retry" {
			auditAction = "delivery_retry"
		}
		scope := a.auditScope(r, target+"."+auditAction, target, optionalPathID(r))
		return a.audited(r, scope, func() (apiResult, error) {
			var body OperatorMutationRequest
			if e := decodeRequest(r, &body, "idempotencyKey", "expectedVersion"); e != nil {
				return apiResult{}, e
			}
			scope.Update(nil, &body.IdempotencyKey, body.ExpectedVersion, body.AuditNote)
			id, e := mutationID(r, body)
			if e != nil {
				return apiResult{}, e
			}
			scope.Audit.TargetID = &id
			if e = validateMutation(a.config, r, body.IdempotencyKey, body.ExpectedVersion, body.AuditNote, body.EnvironmentConfirmation); e != nil {
				return apiResult{}, e
			}
			if recovery {
				if e = requireCapability(a.capabilities(r).Recovery); e != nil {
					return apiResult{}, e
				}
				current, e := a.store.FetchBackfill(r.Context(), id)
				if e != nil {
					return apiResult{}, e
				}
				if current != nil {
					scope.Audit.Before = versionedState(current.Status, current.Version)
				}
				v, e := a.store.TransitionBackfill(r.Context(), id, status, *body.ExpectedVersion, scope.Audit.OperatorDID, body.IdempotencyKey, &scope.Audit.RequestID, body.AuditNote, nil, time.Now())
				return apiResult{value: v, status: httpStatus}, e
			}
			current, e := a.store.FetchAlert(r.Context(), id)
			if e != nil {
				return apiResult{}, e
			}
			if current != nil {
				scope.Audit.Before = versionedState(current.Status, current.Version)
			}
			var v Alert
			if path == "retry" {
				v, e = a.store.RetryAlertDelivery(r.Context(), id, *body.ExpectedVersion, scope.Audit.OperatorDID, body.IdempotencyKey, &scope.Audit.RequestID, body.AuditNote, time.Now())
			} else {
				v, e = a.store.TransitionAlert(r.Context(), id, status, *body.ExpectedVersion, scope.Audit.OperatorDID, body.IdempotencyKey, &scope.Audit.RequestID, body.AuditNote, time.Now())
			}
			return apiResult{value: v, status: httpStatus}, e
		})
	})
}
func optionalPathID(r *http.Request) *string {
	if id := r.PathValue("id"); id != "" {
		return &id
	}
	return nil
}
func versionedState(status string, version int) map[string]string {
	return map[string]string{"status": status, "version": strconv.Itoa(version)}
}
func knownGapStatus(status string) bool {
	for _, s := range []string{"suspected", "confirmed", "backfill_queued", "backfilling", "verification_required", "resolved", "ignored"} {
		if status == s {
			return true
		}
	}
	return false
}
