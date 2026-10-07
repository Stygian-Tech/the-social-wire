package gateway

import (
	"encoding/json"
	"os"
	"testing"
)

func TestCanonicalPublicContractsRemainRegistered(t *testing.T) {
	seen := map[string]bool{}
	for _, route := range Routes {
		seen[route.Method+" "+route.Path] = true
	}
	for _, pattern := range []string{
		"GET /health", "GET /livez", "GET /readyz", "GET /freshness",
		"GET /oauth-client-metadata.json", "GET /oauth/client-metadata.json", "GET /ios-client-metadata.json", "GET /operations-oauth-client-metadata.json",
		"GET /v1/sync/preferences", "GET /xrpc/app.thesocialwire.sync.getPreferences", "POST /v1/sync/migrate-lexicons", "GET /v1/pds/cache/record", "POST /v1/telemetry/client-performance",
	} {
		seen[pattern] = true
	}
	raw, err := os.ReadFile("../../../../packages/spec/endpoint-manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Entries []struct{ Surface, Method, Path string }
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, endpoint := range manifest.Entries {
		if endpoint.Surface != "openapi" {
			continue
		}
		count++
		pattern := endpoint.Method + " " + endpoint.Path
		if !seen[pattern] {
			t.Errorf("canonical Gateway contract missing %s", pattern)
		}
	}
	if count == 0 {
		t.Fatal("missing canonical public contracts")
	}
}
