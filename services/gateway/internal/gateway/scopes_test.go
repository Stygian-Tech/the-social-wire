package gateway

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

// Baselines are the unchanged Production scopes at 76ca61584f5aa41f30008d9304e95df8e413f817.
func TestPodcastDisabledMetadataKeepsProductionScope(t *testing.T) {
	for _, fixture := range []struct{ path, scope, digest string }{
		{"/oauth-client-metadata.json", webScope, "4f04e3f3d987b84c79ed8738268fefbd5905e7c91932fc300fd4a97e57751739"},
		{"/ios-client-metadata.json", iosScope, "38c8134dc32537cb3948ae5621514bc2f8103f884edde0c33bc9928e3a9d317f"},
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
