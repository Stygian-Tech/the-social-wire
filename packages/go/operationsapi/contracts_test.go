package operationsapi

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestConfigurationPreservesReleaseGates(t *testing.T) {
	for _, env := range []string{"", "local", "production"} {
		if _, err := ConfigFromEnvironment(map[string]string{"APP_ENV": env, "DATABASE_URL": "postgres://test"}); err == nil {
			t.Fatalf("accepted %q", env)
		}
	}
	if _, err := ConfigFromEnvironment(map[string]string{"APP_ENV": "prod"}); err == nil {
		t.Fatal("accepted missing database")
	}
	c, err := ConfigFromEnvironment(map[string]string{"APP_ENV": " DEV ", "DATABASE_URL": "postgres://test", "OPERATIONS_OPERATOR_DIDS": " did:plc:one, ,did:plc:one,did:plc:two ", "GATEWAY_OPERATIONS_INTERNAL_SECRET": "internal", "OPERATIONS_UNREAD_COUNTS_P95_SECONDS": "1.75", "OPERATIONS_APPVIEW_5XX_RATIO": "2", "OPERATIONS_INDEX_FAILURE_RATIO": "NaN", "OPERATIONS_DISCONNECT_ALERT_SECONDS": "Inf"})
	if err != nil || c.Environment != "dev" || !c.Enabled || c.RecoveryEnabled || c.AlertDeliveryEnabled || len(c.OperatorDIDs) != 2 || c.FingerprintSecret != "internal" || c.UnreadCountsP95 != 1750*time.Millisecond || c.AppView5xxRatio != 0.02 || c.IndexFailureRatio != 0.01 || c.DisconnectAlert != 120*time.Second {
		t.Fatalf("configuration drift: %+v %v", c, err)
	}
}
func TestPaginationRejectsMalformedInputWithoutRestarting(t *testing.T) {
	date := time.Date(2026, 10, 7, 3, 4, 5, 123000000, time.UTC)
	raw := EncodePaginationCursor(date, "a|b")
	parsed, err := DecodePaginationCursor(raw)
	if err != nil || !parsed.Date.Equal(date) || parsed.ID != "a|b" {
		t.Fatal(parsed, err)
	}
	for _, bad := range []string{"", raw + "\n", raw + "=", strings.Repeat("a", 1025), base64.StdEncoding.EncodeToString([]byte("2026-10-07T03:04:05.123Z|")), base64.StdEncoding.EncodeToString([]byte("2026-10-07T03:04:05.123Z|bad\nkey")), base64.StdEncoding.EncodeToString([]byte("2026-10-07T03:04:05Z|key")), base64.StdEncoding.EncodeToString([]byte{255, '|', 'x'})} {
		if _, err := DecodePaginationCursor(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}
func TestRedactionNeverExportsCredentialsOrErrorMessages(t *testing.T) {
	out := BoundedAttributes(map[string]string{"AUTHORIZATION": "private", "dPoP": "private", "refreshToken": "private", "bodyPayload": "private", "ok": "世界abcd"}, 3)
	if len(out) != 1 || out["ok"] != "世界a" {
		t.Fatal(out)
	}
	if len(HashIdentity("private")) != 24 || HashIdentity("private") != HashIdentity("private") {
		t.Fatal("identity hash drift")
	}
	category := ErrorCategory(&pgconn.PgError{Code: "42P01", TableName: "appview-table", ColumnName: "private column", Message: "sensitive payload"})
	if category != "postgres_42p01_appview_table_private_column" || strings.Contains(category, "payload") {
		t.Fatal(category)
	}
	if strings.Contains(ErrorCategory(errors.New("private DID and cursor")), "private") {
		t.Fatal("error message exported")
	}
}
func TestOperatorAuthorizationRequiresValidatedAllowedIdentity(t *testing.T) {
	handler := OperatorAuthorization(map[string]struct{}{"did:plc:operator": {}})(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	for _, test := range []struct {
		did    string
		status int
	}{{"", 401}, {"did:plc:stranger", 403}, {"did:plc:operator", 204}} {
		r := httptest.NewRequest("GET", "/xrpc/app.thesocialwire.operations.getOverview", nil)
		r.Header.Set(gatewaycore.InternalDIDHeader, "did:plc:operator")
		if test.did != "" {
			r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: test.did}))
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != test.status {
			t.Fatal(test, w.Code)
		}
	}
}
func TestWebhookSignsExactPayloadAndRejectsFailures(t *testing.T) {
	var status = 204
	var bodySize = 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mac := hmac.New(sha256.New, []byte("test-secret"))
		mac.Write(body)
		if r.Header.Get("X-Social-Wire-Signature") != "sha256="+hex.EncodeToString(mac.Sum(nil)) || r.Header.Get("Content-Type") != "application/json" || r.Method != "POST" {
			t.Error("signature contract drift")
		}
		w.WriteHeader(status)
		if bodySize > 0 {
			_, _ = w.Write([]byte(strings.Repeat("x", bodySize)))
		}
	}))
	defer server.Close()
	delivery := WebhookDelivery{server.URL, "test-secret", server.Client()}
	if err := delivery.Deliver(context.Background(), map[string]string{"id": "fixture"}); err != nil {
		t.Fatal(err)
	}
	status = 503
	if !errors.Is(delivery.Deliver(context.Background(), map[string]string{}), ErrWebhookRejected) {
		t.Fatal("accepted non-2xx")
	}
	status = 200
	bodySize = 65537
	if delivery.Deliver(context.Background(), map[string]string{}) == nil {
		t.Fatal("accepted oversized body")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if delivery.Deliver(ctx, map[string]string{}) == nil {
		t.Fatal("ignored cancellation")
	}
}
func TestEventCursorRetentionAndExactInt64Frame(t *testing.T) {
	bounds := ChangeEventCursorBounds{10, 20}
	for _, test := range []struct {
		cursor *int64
		want   int64
		status int
	}{{nil, 20, 0}, {ptr64(0), 0, 0}, {ptr64(9), 9, 0}, {ptr64(8), 0, 410}, {ptr64(21), 0, 400}} {
		actual, err := EventStreamCursor(test.cursor, bounds)
		if actual != test.want || (test.status == 0 && err != nil) || (test.status != 0 && (err == nil || ErrorStatus(err) != test.status)) {
			t.Fatal(test, actual, err)
		}
	}
	for _, bad := range []string{"", "-1", "1.2", "9223372036854775808"} {
		if _, err := EventCursor(bad, "12", true); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	requested, err := EventCursor("11", "12", true)
	if err != nil || *requested != 11 {
		t.Fatal(requested, err)
	}
	frame, err := SSEFrame(ChangeEvent{Environment: "dev", Cursor: 9007199254740993, EventType: "fixture.changed", EntityType: "fixture", Payload: map[string]string{"note": "line\nbreak"}, OccurredAt: time.Date(2026, 10, 7, 3, 0, 0, 123000000, time.UTC)})
	if err != nil || !strings.Contains(frame, `"cursor":9007199254740993`) || !strings.Contains(frame, "id: 9007199254740993\nevent: fixture.changed\n") || !strings.Contains(frame, `"occurredAt":"2026-10-07T03:00:00Z"`) {
		t.Fatal(frame, err)
	}
	for _, line := range strings.Split(frame, "\n") {
		if strings.HasPrefix(line, "data: ") {
			var data map[string]json.RawMessage
			if json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &data) != nil {
				t.Fatal("invalid data JSON")
			}
		}
	}
	if _, err = SSEFrame(ChangeEvent{EventType: "bad\nevent: injected"}); err == nil {
		t.Fatal("accepted SSE injection")
	}
}
func ptr64(n int64) *int64 { return &n }
func TestFailedMutationIsDurablyAuditedDespiteRequestCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	scope := &MutationAuditScope{Audit: MutationAudit{OperatorDID: "did:plc:operator", Action: "fixture.update"}}
	operationError := HTTPError{409, "stale"}
	var saved MutationAudit
	_, err := AuditedMutation(ctx, scope, func(ctx context.Context, a MutationAudit) error {
		if ctx.Err() != nil {
			t.Fatal("audit inherited canceled request")
		}
		saved = a
		return nil
	}, func() (string, error) { return "", operationError }, ErrorStatus)
	if !errors.Is(err, operationError) || saved.Outcome != "rejected" || saved.After["httpStatus"] != "409" {
		t.Fatal(err, saved)
	}
	_, err = AuditedMutation(ctx, scope, func(context.Context, MutationAudit) error { return errors.New("database unavailable") }, func() (string, error) { return "", operationError }, ErrorStatus)
	if !errors.Is(err, ErrMutationAuditUnavailable) {
		t.Fatal("audit failure did not close request")
	}
}

type fixtureEvents struct {
	cancel context.CancelFunc
	after  []int64
}

func (s *fixtureEvents) ChangeEventCursorBounds(context.Context) (ChangeEventCursorBounds, error) {
	return ChangeEventCursorBounds{1, 3}, nil
}
func (s *fixtureEvents) ListChangeEvents(_ context.Context, after int64, limit int) ([]ChangeEvent, error) {
	s.after = append(s.after, after)
	s.cancel()
	return []ChangeEvent{{Environment: "dev", Cursor: 4, EventType: "fixture.changed", EntityType: "fixture", Payload: map[string]string{}, OccurredAt: time.Now()}}, nil
}
func TestEventStreamReplaysCursorAndStopsOnCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	store := &fixtureEvents{cancel: cancel}
	r := httptest.NewRequest("GET", "/v1/operations/events/stream?after=2", nil).WithContext(ctx)
	r.Header.Set("Last-Event-ID", "1")
	w := httptest.NewRecorder()
	EventStreamHandler(store).ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Content-Type") != "text/event-stream" || w.Header().Get("Cache-Control") != "no-cache, no-store" || len(store.after) != 1 || store.after[0] != 2 || !strings.HasPrefix(w.Body.String(), "retry: 1000\n\n") || !strings.Contains(w.Body.String(), "id: 4\nevent: fixture.changed") {
		t.Fatal(w.Code, w.Header(), store.after, w.Body.String())
	}
}
