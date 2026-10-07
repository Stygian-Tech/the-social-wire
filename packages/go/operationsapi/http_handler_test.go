package operationsapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func TestHTTPValidationDoesNotRestartPaginationOrAcceptMissingVersions(t *testing.T) {
	for _, raw := range []string{"?limit=0", "?limit=251", "?limit=x", "?limit=1&limit=2", "?before=broken", "?before="} {
		r := httptest.NewRequest("GET", "/"+raw, nil)
		if _, _, e := pageQuery(r, 250); e == nil {
			t.Fatal("accepted", raw)
		}
	}
	for _, body := range []string{`{}`, `{"expectedVersion":null,"idempotencyKey":"key"}`, `{"expectedVersion":0,"idempotencyKey":false}`, `null`, `[]`, `{} {}`} {
		r := httptest.NewRequest("POST", "/", strings.NewReader(body))
		var v OperatorMutationRequest
		if e := decodeRequest(r, &v, "expectedVersion", "idempotencyKey"); e == nil {
			t.Fatal("accepted", body)
		}
	}
	r := httptest.NewRequest("POST", "/", nil)
	r.Header.Set("Idempotency-Key", "key")
	if e := validateMutation(Config{Environment: "prod"}, r, "key", pointer(0), nil, nil); e == nil {
		t.Fatal("missing production confirmation accepted")
	}
	if e := validateMutation(Config{Environment: "prod"}, r, "key", pointer(0), nil, pointer("PRODUCTION")); e != nil {
		t.Fatal(e)
	}
	now := time.Date(2026, 10, 7, 12, 1, 32, 0, time.UTC)
	r = httptest.NewRequest("GET", "/?from=2026-10-07T12:00:00Z&to=2026-10-07T13:00:00Z&resolution=1m", nil)
	_, to, _, _, e := metricRequest(r, now)
	if e != nil || !to.Equal(now.Truncate(time.Minute).Add(-time.Millisecond)) {
		t.Fatal(to, e)
	}
}
func TestHTTPTrustAndOperatorGatesDoNotExposeOperations(t *testing.T) {
	config := Config{Environment: "dev", InternalSecret: "fixture", OperatorDIDs: map[string]struct{}{"did:plc:operator": {}}}
	handler := NewHandler(nil, config, gatewaycore.AuthConfig{}, nil)
	for _, path := range []string{"/v1/operations/overview", "/xrpc/app.thesocialwire.operations.getOverview", "/v1/operations/events/stream"} {
		r := httptest.NewRequest("GET", path, nil)
		r.Header.Set("X-SocialWire-Gateway-DID", "did:plc:operator")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != 401 {
			t.Fatal(path, w.Code)
		}
	}
	r := httptest.NewRequest("GET", "/v1/operations/overview", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:not-operator"}))
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal(w.Code)
	}
	for _, path := range []string{"/health", "/livez"} {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != 200 {
			t.Fatal(path, w.Code)
		}
	}
}
func TestHTTPRESTAndXRPCShareAtomicAlertMutationAndFailureAudit(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool, e := pgxpool.New(ctx, url)
	if e != nil {
		t.Fatal(e)
	}
	defer pool.Close()
	tx, e := pool.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(context.Background())
	store, e := NewPostgresStore(tx, "dev")
	if e != nil {
		t.Fatal(e)
	}
	condition, _ := randomUUID()
	alert, e := store.OpenAlert(ctx, "fixture", condition, "warning", "Fixture", nil, "fixture", time.Now())
	if e != nil {
		t.Fatal(e)
	}
	config := Config{Environment: "dev", OperatorDIDs: map[string]struct{}{"did:plc:operator": {}}}
	handler := NewHandler(store, config, gatewaycore.AuthConfig{}, nil)
	send := func(method, path, body, key string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Idempotency-Key", key)
		r.Header.Set("X-Request-ID", "request-"+condition)
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: "did:plc:operator"}))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		return w
	}
	key := "ack-" + condition
	body := `{"expectedVersion":0,"idempotencyKey":"` + key + `"}`
	w := send("POST", "/v1/operations/alerts/"+alert.ID+"/acknowledge", body, key)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var result Alert
	if e = json.Unmarshal(w.Body.Bytes(), &result); e != nil || result.Status != "acknowledged" || result.Version != 1 {
		t.Fatal(result, e)
	}
	body = `{"id":"` + alert.ID + `","expectedVersion":0,"idempotencyKey":"` + key + `"}`
	w = send("POST", "/xrpc/app.thesocialwire.operations.acknowledgeAlert", body, key)
	if w.Code != 200 {
		t.Fatal("replay", w.Code, w.Body.String())
	}
	var replay Alert
	_ = json.Unmarshal(w.Body.Bytes(), &replay)
	if replay.Version != 1 {
		t.Fatal("not immutable", replay)
	}
	w = send("POST", "/xrpc/app.thesocialwire.operations.resolveAlert", `{"id":"`+alert.ID+`","idempotencyKey":"bad"}`, "bad")
	if w.Code != 400 {
		t.Fatal(w.Code, w.Body.String())
	}
	var count int
	if e = tx.QueryRow(ctx, `SELECT count(*) FROM operations_audit_events WHERE environment='dev' AND request_id=$1 AND outcome='rejected'`, "request-"+condition).Scan(&count); e != nil || count != 1 {
		t.Fatal("failure not audited", count, e)
	}
	for _, path := range []string{"/v1/operations/alerts?view=all", "/xrpc/app.thesocialwire.operations.listAlerts?view=all"} {
		w = send("GET", path, "", "")
		if w.Code != 200 || !strings.Contains(w.Body.String(), alert.ID) {
			t.Fatal(path, w.Code, w.Body.String())
		}
	}
	w = send("POST", "/v1/operations/alerts/"+alert.ID+"/resolve", `{"expectedVersion":0,"idempotencyKey":"stale"}`, "stale")
	if w.Code != 409 {
		t.Fatal("CAS", w.Code, w.Body.String())
	}
	current, e := store.FetchAlert(ctx, alert.ID)
	if e != nil || current.Status != "acknowledged" {
		t.Fatal(current, e)
	}
}
