package operationsapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type HTTPError struct {
	Status  int
	Message string
}

func (e HTTPError) Error() string { return e.Message }
func ErrorStatus(err error) int {
	var h HTTPError
	if errors.As(err, &h) {
		return h.Status
	}
	for _, conflict := range []error{ErrVersionConflict, ErrInvalidTransition, ErrIdempotencyConflict, ErrOverlappingBackfill, ErrBackfillScopeChanged, ErrBackfillFingerprint, ErrLeaseConflict, ErrEnvironmentMismatch} {
		if errors.Is(err, conflict) {
			return 409
		}
	}
	if errors.Is(err, ErrNotFound) {
		return 404
	}
	if errors.Is(err, ErrInvalidProgress) || errors.Is(err, ErrInvalidPaginationCursor) {
		return 400
	}
	return http.StatusInternalServerError
}
func EventCursor(query, lastEventID string, queryPresent bool) (*int64, error) {
	raw := lastEventID
	if queryPresent {
		raw = query
	}
	if raw == "" && !queryPresent && lastEventID == "" {
		return nil, nil
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 0 {
		return nil, HTTPError{400, "Event cursor must be a non-negative integer"}
	}
	return &n, nil
}
func EventStreamCursor(requested *int64, bounds ChangeEventCursorBounds) (int64, error) {
	if requested == nil {
		return bounds.Latest, nil
	}
	if *requested > bounds.Latest {
		return 0, HTTPError{400, "The requested event cursor is ahead of the durable stream"}
	}
	if !bounds.CanResume(*requested) {
		return 0, HTTPError{410, "The requested event cursor has expired"}
	}
	return *requested, nil
}
func SSEFrame(event ChangeEvent) (string, error) {
	if strings.ContainsAny(event.EventType, "\r\n") {
		return "", errors.New("invalid event stream type")
	}
	event.OccurredAt = event.OccurredAt.UTC().Truncate(time.Second)
	if event.Payload == nil {
		event.Payload = map[string]string{}
	}
	body, err := json.Marshal(event)
	if err != nil {
		return "", err
	}
	var object map[string]json.RawMessage
	if err = json.Unmarshal(body, &object); err != nil {
		return "", err
	}
	body, err = json.Marshal(object)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("id: %d\nevent: %s\ndata: %s\n\n", event.Cursor, event.EventType, body), nil
}

type EventStore interface {
	ChangeEventCursorBounds(context.Context) (ChangeEventCursorBounds, error)
	ListChangeEvents(context.Context, int64, int) ([]ChangeEvent, error)
}

func EventStreamHandler(store EventStore) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			writeError(w, 503)
			return
		}
		values, present := r.URL.Query()["after"]
		query := ""
		if len(values) > 0 {
			query = values[0]
		}
		if !present && len(r.Header.Values("Last-Event-ID")) > 0 && r.Header.Get("Last-Event-ID") == "" {
			writeError(w, 400)
			return
		}
		requested, err := EventCursor(query, r.Header.Get("Last-Event-ID"), present)
		if err != nil {
			writeError(w, ErrorStatus(err))
			return
		}
		bounds, err := store.ChangeEventCursorBounds(r.Context())
		if err != nil {
			writeError(w, 503)
			return
		}
		cursor, err := EventStreamCursor(requested, bounds)
		if err != nil {
			writeError(w, ErrorStatus(err))
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache, no-store")
		w.Header().Set("X-Accel-Buffering", "no")
		if _, err = fmt.Fprint(w, "retry: 1000\n\n"); err != nil {
			return
		}
		flusher.Flush()
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		var heartbeat time.Time
		for {
			events, err := store.ListChangeEvents(r.Context(), cursor, 100)
			if err != nil {
				return
			}
			if len(events) == 0 {
				now := time.Now()
				if now.Sub(heartbeat) >= 15*time.Second {
					if _, err = fmt.Fprintf(w, ": heartbeat %s\n\n", now.UTC().Format(time.RFC3339)); err != nil {
						return
					}
					heartbeat = now
					flusher.Flush()
				}
			}
			for _, event := range events {
				frame, err := SSEFrame(event)
				if err != nil {
					return
				}
				if _, err = fmt.Fprint(w, frame); err != nil {
					return
				}
				flusher.Flush()
				cursor = event.Cursor
			}
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
			}
		}
	})
}
func writeError(w http.ResponseWriter, status int) {
	message := "The request is invalid."
	if status >= 500 {
		message = "The request could not be completed."
	}
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
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": name, "message": message})
}
