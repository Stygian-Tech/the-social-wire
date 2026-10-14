package gateway

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type gifTransport func(*http.Request) (*http.Response, error)

func (f gifTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func gifFixture() providerGIF {
	return providerGIF{ID: "123", Title: "Celebrate", Description: "A person celebrating", Formats: map[string]gifRendition{
		"gif":     {URL: "https://static.klipy.com/ii/example/full.gif", Dims: []int{280, 498}},
		"preview": {URL: "https://static.klipy.com/ii/example/still.jpg"},
		"mp4":     {URL: "https://static.klipy.com/ii/example/video.mp4"},
	}}
}

func TestGIFNormalizationRejectsUnsafeOrIncompatibleMedia(t *testing.T) {
	for _, raw := range []string{"http://static.klipy.com/ii/a.gif", "https://static.klipy.com.evil/ii/a.gif", "https://user@static.klipy.com/ii/a.gif", "https://static.klipy.com:8080/ii/a.gif", "https://127.0.0.1/ii/a.gif"} {
		if klipyMediaURL(raw) != "" {
			t.Fatal("accepted unsafe media")
		}
	}
	good := gifFixture()
	asset, ok := normalizeGIF(good)
	if !ok || asset.Width != 280 || asset.Height != 498 {
		t.Fatal(asset)
	}
	good.Formats["mp4"] = gifRendition{URL: "https://static.klipy.com/ii/other/video.mp4"}
	if _, ok := normalizeGIF(good); ok {
		t.Fatal("accepted incompatible rendition")
	}
}

func TestGIFSearchUsesServerKeyAndDoesNotExposeProviderResponse(t *testing.T) {
	s := Server{Config: Config{KlipyAPIKey: "test-secret"}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.klipy.com" || r.URL.Path != "/v2/search" || r.URL.Query().Get("key") != "test-secret" || r.URL.Query().Get("q") != "celebrate" || r.URL.Query().Get("contentfilter") != "medium" {
			t.Fatal("incorrect provider contract")
		}
		body, _ := json.Marshal(map[string]any{"results": []providerGIF{gifFixture()}, "next": "next-page", "secret": "test-secret"})
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
	})}}
	w := httptest.NewRecorder()
	s.gifs(w, httptest.NewRequest("GET", "/v1/media/gifs?q=celebrate", nil))
	if w.Code != 200 || strings.Contains(w.Body.String(), "test-secret") || !strings.Contains(w.Body.String(), "Powered by KLIPY") {
		t.Fatal(w.Body.String())
	}
}

func TestGIFResolveRequiresMatchingIdentityAndConfiguration(t *testing.T) {
	s := Server{}
	w := httptest.NewRecorder()
	s.gifs(w, httptest.NewRequest("GET", "/v1/media/gifs", nil))
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
	s.Config.KlipyAPIKey = "key"
	s.Public = &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
		body, _ := json.Marshal(map[string]any{"results": []providerGIF{gifFixture()}})
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
	})}
	w = httptest.NewRecorder()
	s.gifs(w, httptest.NewRequest("GET", "/v1/media/gifs?id=456", nil))
	if w.Code != 404 {
		t.Fatal(w.Code)
	}
	w = httptest.NewRecorder()
	s.gifs(w, httptest.NewRequest("GET", "/v1/media/gifs?id=https://evil", nil))
	if w.Code != 400 {
		t.Fatal(w.Code)
	}
}
