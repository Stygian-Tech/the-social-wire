package gateway

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

// Web baseline includes the reviewed least-privilege Social and Articles grants.
// Native baseline includes the explicitly enabled Standard Reader Lists permissions
// in the published native authorization request order.
func TestPodcastDisabledMetadataKeepsProductionScope(t *testing.T) {
	for _, fixture := range []struct{ path, scope, digest string }{
		{"/oauth-client-metadata.json", webScope, "7bb76547bd50807e63ddb4ad28d0fc0772f5839b7cb0e0104d22f7e051a4644d"},
		{"/ios-client-metadata.json", iosScope, "7001b4367000f36cab50a5cf3e517f23353b9ef7cb37b90c4310661b761d4a9d"},
	} {
		for _, enabled := range []bool{false, true} {
			s := Server{Config: Config{PodcastsEnabled: enabled}}
			w := httptest.NewRecorder()
			s.metadata(w, httptest.NewRequest("GET", "https://gateway.valid"+fixture.path, nil))
			var doc struct{ Scope string }
			if err := json.Unmarshal(w.Body.Bytes(), &doc); err != nil || w.Code != 200 {
				t.Fatal(w.Code, err)
			}
			if enabled {
				if doc.Scope != fixture.scope {
					t.Fatal("enabled scope ordering changed")
				}
				continue
			}
			digest := sha256.Sum256([]byte(doc.Scope))
			if hex.EncodeToString(digest[:]) != fixture.digest {
				t.Fatal("Production scope drift")
			}
			if strings.Contains(doc.Scope, "podcast") {
				t.Fatal("disabled permission exposed")
			}
		}
	}
}
func TestPodcastScopeRequiresExplicitEnablement(t *testing.T) {
	for _, raw := range []string{"", "false", "1", "TRUE", "true"} {
		c, err := ParseConfig(map[string]string{"PODCASTS_ENABLED": raw})
		if err != nil {
			t.Fatal(err)
		}
		if c.PodcastsEnabled != strings.EqualFold(raw, "true") {
			t.Fatal("unexpected podcast flag")
		}
	}
}
