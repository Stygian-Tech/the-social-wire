package readstate

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
)

func TestScopeConflictPreservesRetryAndTraceContract(t *testing.T) {
	w := httptest.NewRecorder()
	w.Header().Set("X-Request-ID", "scope-conflict-fixture")
	finish(w, nil, pdsreadstatecore.ErrLegacyScopeOverlap)
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if w.Code != 409 || body["error"] != "ReadStateMigrationScopeConflict" || body["retryable"] != true || body["requestId"] != "scope-conflict-fixture" || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("scope conflict contract: status=%d body=%v headers=%v", w.Code, body, w.Header())
	}
}
