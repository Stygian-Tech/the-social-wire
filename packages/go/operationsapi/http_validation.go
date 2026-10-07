package operationsapi

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const maxOperationsRequestBytes = 1 << 20

func decodeRequest(r *http.Request, value any, required ...string) error {
	data, err := io.ReadAll(io.LimitReader(r.Body, maxOperationsRequestBytes+1))
	if err != nil || len(data) > maxOperationsRequestBytes {
		return HTTPError{400, "Request body is invalid or too large"}
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || fields == nil {
		return HTTPError{400, "Request body must be a JSON object"}
	}
	for _, key := range required {
		raw, ok := fields[key]
		if !ok || string(raw) == "null" {
			return HTTPError{400, key + " is required"}
		}
	}
	if json.Unmarshal(data, value) != nil {
		return HTTPError{400, "Request body has invalid fields"}
	}
	return nil
}
func requestLimit(r *http.Request, maximum int) (int, error) {
	raw, ok := r.URL.Query()["limit"]
	if !ok {
		return min(100, maximum), nil
	}
	if len(raw) != 1 {
		return 0, HTTPError{400, "limit is outside the supported range"}
	}
	n, err := strconv.Atoi(raw[0])
	if err != nil || n < 1 || n > maximum {
		return 0, HTTPError{400, "limit is outside the supported range"}
	}
	return n, nil
}
func requestBefore(r *http.Request) (*string, error) {
	raw, ok := r.URL.Query()["before"]
	if !ok {
		return nil, nil
	}
	if len(raw) != 1 {
		return nil, HTTPError{400, "Pagination cursor is malformed"}
	}
	if _, err := DecodePaginationCursor(raw[0]); err != nil {
		return nil, HTTPError{400, "Pagination cursor is malformed"}
	}
	return &raw[0], nil
}
func requestView(r *http.Request, allowed ...string) (string, error) {
	view := r.URL.Query().Get("view")
	if view == "" {
		view = "active"
	}
	if view == "needs_attention" {
		view = "attention"
	}
	for _, candidate := range allowed {
		if candidate == view {
			return view, nil
		}
	}
	return "", HTTPError{400, "Unknown lifecycle view"}
}
func requestResourceID(r *http.Request, key string) (string, error) {
	id := r.URL.Query().Get(key)
	if id == "" {
		id = r.PathValue(key)
	}
	if id == "" {
		return "", HTTPError{400, key + " is required"}
	}
	return id, nil
}
func requestDate(r *http.Request, key string) (*time.Time, error) {
	raw, ok := r.URL.Query()[key]
	if !ok {
		return nil, nil
	}
	if len(raw) != 1 {
		return nil, HTTPError{400, "Timestamp is not valid ISO-8601"}
	}
	date, err := time.Parse(time.RFC3339Nano, raw[0])
	if err != nil {
		return nil, HTTPError{400, "Timestamp is not valid ISO-8601"}
	}
	return &date, nil
}
func requireCapability(c Capability) error {
	if c.Enabled {
		return nil
	}
	reason := "The requested capability is unavailable"
	if c.DisabledReason != nil {
		reason = *c.DisabledReason
	}
	return HTTPError{503, reason}
}
func requireMode(mode string, c Capabilities) error {
	switch mode {
	case "tap_verified_resync":
		return requireCapability(c.RecoveryModes.TapVerifiedResync)
	case "jetstream_replay":
		return requireCapability(c.RecoveryModes.JetstreamReplay)
	case "pds_reconciliation":
		return requireCapability(c.RecoveryModes.PDSReconciliation)
	}
	return HTTPError{400, "Unknown backfill source mode"}
}
func validateMutation(config Config, r *http.Request, key string, version *int, note, confirmation *string) error {
	if version == nil || *version < 0 {
		return HTTPError{400, "expectedVersion must be non-negative"}
	}
	if note != nil && utf8.RuneCountInString(*note) > 280 {
		return HTTPError{400, "Audit note is too long"}
	}
	return validateMutationKey(config, r, key, confirmation)
}
func validateMutationKey(config Config, r *http.Request, key string, confirmation *string) error {
	trimmed := strings.TrimSpace(key)
	if trimmed == "" || utf8.RuneCountInString(trimmed) > 128 {
		return HTTPError{400, "Idempotency key is invalid"}
	}
	for _, ch := range trimmed {
		if ch > 127 || unicode.IsSpace(ch) {
			return HTTPError{400, "Idempotency key is invalid"}
		}
	}
	if r.Header.Get("Idempotency-Key") == "" || r.Header.Get("Idempotency-Key") != key {
		return HTTPError{400, "Idempotency-Key header must match the request body"}
	}
	if config.Environment == "prod" && (confirmation == nil || *confirmation != "PRODUCTION") {
		return HTTPError{400, "Production confirmation is required"}
	}
	return nil
}
func validateDryRunFields(r BackfillDryRunRequest) (BackfillDryRunRequest, error) {
	if r.Collections == nil || r.AuthorDIDs == nil {
		return r, HTTPError{400, "collections and authorDids are required"}
	}
	normalized, err := NormalizeBackfillRequest(r)
	if err != nil {
		return r, HTTPError{400, "Backfill scope is invalid"}
	}
	return normalized, nil
}
