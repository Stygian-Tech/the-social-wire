package readstate

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
)

func TestEmptyPreparedBoundarySelectionPreservesExplicitArrays(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_APPVIEW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated canonical PostgreSQL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mux := http.NewServeMux()
	Routes{DB: db, Store: &pdsreadstatecore.Store{DB: db}, ResolveScopes: func(context.Context, gatewaycore.AuthContext, appviewcore.ReadScopeSelector) ([]appviewcore.PublicationScope, error) {
		return []appviewcore.PublicationScope{}, nil
	}}.Register(mux)
	req := httptest.NewRequest("POST", "/xrpc/app.thesocialwire.appview.prepareReadState", strings.NewReader(`{"scope":{"kind":"subscribed"},"previewSubjectUris":["uncached-subject"]}`))
	req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: "did:plc:empty-preparation-fixture"}))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, req)
	var response map[string]json.RawMessage
	json.Unmarshal(w.Body.Bytes(), &response)
	if w.Code != 200 || string(response["boundaries"]) != "[]" || string(response["previewSubjectUris"]) != "[]" || string(response["selection"]) != `"boundaries"` || response["subjectUris"] != nil || response["manifestCid"] != nil {
		t.Fatalf("empty preparation contract: %d %s", w.Code, w.Body.String())
	}
}
