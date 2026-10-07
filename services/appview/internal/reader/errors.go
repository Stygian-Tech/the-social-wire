package reader

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5/pgconn"
)

func respond(w http.ResponseWriter, body any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(body)
}

func fail(w http.ResponseWriter, r *http.Request, status int, code, message string, retryable bool) {
	w.Header().Set("Content-Type", "application/json")
	requestID := r.Header.Get("X-Request-ID")
	w.Header().Set("X-Request-ID", requestID)
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{"error": code, "message": message, "requestId": requestID, "retryable": retryable})
}

func databaseError(w http.ResponseWriter, r *http.Request, err error) {
	status, code, message, retry := 500, "internal_error", "The feed could not be loaded.", false
	var postgres *pgconn.PgError
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		status, code, retry = 504, "request_cancelled", true
	}
	if errors.As(err, &postgres) {
		if postgres.Code == "55000" && postgres.Message == "ReadStateProjectionNotReady" {
			status, code, message, retry = 503, "ReadStateProjectionNotReady", "Read-state projection is warming.", true
		} else if postgres.Code == "57014" {
			status, code, retry = 504, "database_unavailable", true
		} else if len(postgres.Code) >= 2 && (postgres.Code[:2] == "08" || postgres.Code == "53300") {
			status, code, retry = 503, "database_unavailable", true
		}
	}
	fail(w, r, status, code, message, retry)
}
