package gateway

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestNativeMetadataMatchesAuthorizationRequest(t *testing.T) {
	raw, err := os.ReadFile("../../../../apps/apple/SocialWire/Services/ATProtoOAuthService.swift")
	if err != nil {
		t.Fatal(err)
	}
	_, array, found := strings.Cut(string(raw), "static let scopes = [")
	if !found {
		t.Fatal("native authorization scopes not found")
	}
	array, _, found = strings.Cut(array, "].joined(separator:")
	if !found {
		t.Fatal("native authorization scope array is unterminated")
	}
	matches := regexp.MustCompile(`(?m)^\s*"([^"\n]+)"`).FindAllStringSubmatch(array, -1)
	if len(matches) == 0 {
		t.Fatal("native authorization scopes are empty")
	}
	scopes := make([]string, 0, len(matches))
	for _, match := range matches {
		scopes = append(scopes, match[1])
	}
	want := strings.Join(scopes, " ")
	for _, enabled := range []bool{false, true} {
		s := Server{Config: Config{PodcastsEnabled: enabled}}
		w := httptest.NewRecorder()
		s.metadata(w, httptest.NewRequest("GET", "https://gateway.valid/ios-client-metadata.json", nil))
		var doc struct{ Scope string }
		if err := json.Unmarshal(w.Body.Bytes(), &doc); err != nil || w.Code != 200 {
			t.Fatal(w.Code, err)
		}
		if doc.Scope != podcastScope(want, enabled) {
			t.Fatalf("native metadata differs from authorization request (podcasts enabled: %t)", enabled)
		}
	}
}

// Web baseline includes the reviewed least-privilege Social (including private draft RPCs and create-only Follow), Articles, and chat moderation grants.
// Native baseline includes Social and Standard Reader Lists permissions in the
// published native authorization request order.
func TestPodcastDisabledMetadataKeepsProductionScope(t *testing.T) {
	for _, fixture := range []struct{ path, scope, digest string }{
		{"/oauth-client-metadata.json", webScope, "2bd81d479140135ab6b49aa91eff2b99991f9ae08008fe70ac5b2449b2796f5f"},
		{"/ios-client-metadata.json", iosScope, "653a030dc0ca652baa58019ebb0f61ff8ce05cb27575ac7d40e3a4f06eb8c0a5"},
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
