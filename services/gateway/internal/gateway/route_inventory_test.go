package gateway

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestSwiftProxyPathInventoryRemainsRegistered(t *testing.T) {
	seen := map[string]bool{}
	for _, route := range Routes {
		seen[route.Path] = true
	}
	for _, path := range []string{"/v1/sync/preferences", "/xrpc/app.thesocialwire.sync.getPreferences", "/v1/sync/migrate-lexicons", "/v1/pds/cache/record", "/v1/telemetry/client-performance"} {
		seen[path] = true
	}
	files, e := filepath.Glob("../../Sources/Gateway/Routes/*.swift")
	if e != nil || len(files) == 0 {
		t.Fatal("missing Swift reference", e)
	}
	pattern := regexp.MustCompile(`"(/(?:v1|xrpc)/[^"\\]+)"`)
	for _, file := range files {
		raw, e := os.ReadFile(file)
		if e != nil {
			t.Fatal(e)
		}
		for _, match := range pattern.FindAllStringSubmatch(string(raw), -1) {
			path := match[1]
			if strings.Contains(path, ":") {
				continue
			}
			if !seen[path] {
				t.Errorf("Swift route missing %s in %s", path, file)
			}
		}
	}
	for _, path := range []string{"/v1/operations/gaps/{id}/investigation", "/v1/operations/backfills/{id}", "/v1/operations/backfills/{id}/pause", "/v1/operations/backfills/{id}/resume", "/v1/operations/backfills/{id}/cancel", "/v1/operations/alerts/{id}/acknowledge", "/v1/operations/alerts/{id}/resolve", "/v1/operations/alerts/{id}/retry", "/v1/operations/traces/{traceId}"} {
		if !seen[path] {
			t.Error(path)
		}
	}
}
