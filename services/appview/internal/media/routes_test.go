package media

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

const photo = `{"$type":"app.bsky.embed.images#view","images":[{"thumb":"https://cdn.bsky.app/thumb","fullsize":"https://cdn.bsky.app/full"}]}`
const portrait = `{"$type":"app.bsky.embed.video#view","playlist":"https://video.bsky.app/play.m3u8","aspectRatio":{"width":720,"height":1280}}`

func request(body, did string) *httptest.ResponseRecorder {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	r := httptest.NewRequest("POST", "/v1/media/project", strings.NewReader(body))
	if did != "" {
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: did}))
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	return w
}

func TestProjectionAuthenticatesAndBoundsCandidates(t *testing.T) {
	for _, did := range []string{"", gatewaycore.AnonymousDiscoveryDID} {
		if w := request(`{"mode":"photos","posts":[]}`, did); w.Code != 401 {
			t.Fatal(w.Code)
		}
	}
	for _, body := range []string{`{}`, `{"mode":"all","posts":[]}`, `{"mode":"photos","posts":null}`, `{"mode":"photos","posts":[],"viewerDid":"did:plc:other"}`, `{"mode":"photos","posts":[]} {}`, `{"mode":"photos","posts":[` + strings.Repeat(`{"uri":"a","embed":{}},`, 30) + `{"uri":"b","embed":{}}]}`, `{"mode":"photos","posts":[{"uri":"a","embed":{"text":"` + strings.Repeat("a", 512<<10) + `"}}]}`} {
		if w := request(body, "did:plc:viewer"); w.Code != 400 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}

func TestProjectionDeduplicatesWithoutRetainingViewerState(t *testing.T) {
	body := `{"mode":"photos","posts":[{"uri":"at://did:plc:a/app.bsky.feed.post/1","embed":` + photo + `},{"uri":"at://did:plc:a/app.bsky.feed.post/1","embed":` + photo + `},{"uri":"https://evil/post","embed":` + photo + `}]}`
	for _, did := range []string{"did:plc:a", "did:plc:b"} {
		w := request(body, did)
		var result struct {
			URIs             []string `json:"uris"`
			Source           string   `json:"source"`
			DurationVerified bool     `json:"durationVerified"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || w.Code != 200 || len(result.URIs) != 1 || result.Source != "bluesky-following" || result.DurationVerified {
			t.Fatal(w.Code, w.Body.String(), err)
		}
		if w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatal("cacheable viewer input")
		}
	}
	if w := request(`{"mode":"photos","posts":[]}`, "did:plc:b"); !strings.Contains(w.Body.String(), `"uris":[]`) {
		t.Fatal("retained previous viewer input")
	}
}

func TestMediaRulesFailClosed(t *testing.T) {
	gallery := `{"$type":"app.bsky.embed.gallery#view","items":[{"$type":"app.bsky.embed.gallery#viewImage","thumbnail":"https://cdn.bsky.app/thumb","fullsize":"https://cdn.bsky.app/full"}]}`
	for _, tc := range []struct {
		name, embed, mode string
		want              bool
	}{
		{"photos", photo, "photos", true},
		{"gallery", gallery, "photos", true},
		{"unknown gallery union", strings.ReplaceAll(gallery, "#viewImage", "#viewVideo"), "photos", false},
		{"portrait", portrait, "short-videos", true},
		{"landscape", strings.ReplaceAll(portrait, `"width":720,"height":1280`, `"width":1280,"height":720`), "short-videos", false},
		{"missing dimensions", `{"$type":"app.bsky.embed.video#view","playlist":"https://video.bsky.app/play"}`, "short-videos", false},
		{"fractional dimensions", strings.ReplaceAll(portrait, `"width":720`, `"width":0.5`), "short-videos", false},
		{"gif", strings.Replace(portrait, `"playlist"`, `"presentation":"gif","playlist"`, 1), "short-videos", false},
		{"unsafe video", strings.ReplaceAll(portrait, "https://video.bsky.app/play.m3u8", "javascript:alert(1)"), "short-videos", false},
		{"unsafe image", strings.ReplaceAll(photo, "https://cdn.bsky.app/full", "http://cdn.bsky.app/full"), "photos", false},
		{"credentials", strings.ReplaceAll(photo, "https://cdn.bsky.app/full", "https://user:pass@cdn.bsky.app/full"), "photos", false},
		{"external", `{"$type":"app.bsky.embed.external#view"}`, "photos", false},
		{"quote image", `{"$type":"app.bsky.embed.recordWithMedia#view","media":` + photo + `}`, "photos", true},
		{"quote portrait", `{"$type":"app.bsky.embed.recordWithMedia#view","media":` + portrait + `}`, "short-videos", true},
		{"nested unknown quote", `{"$type":"app.bsky.embed.recordWithMedia#view","media":{"$type":"app.bsky.embed.recordWithMedia#view","media":` + photo + `}}`, "photos", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var embed map[string]any
			if err := json.Unmarshal([]byte(tc.embed), &embed); err != nil {
				t.Fatal(err)
			}
			if got := matches(embed, tc.mode, 0); got != tc.want {
				t.Fatal(got)
			}
		})
	}
}
