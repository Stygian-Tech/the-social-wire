package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
)

func gifFileRequest(query, owner string) *http.Request {
	r := httptest.NewRequest("GET", socialDraftGIFPath+query, nil)
	r.Header.Set("Authorization", "DPoP viewer-token")
	r.Header.Set("DPoP", "viewer-proof")
	if owner != "" {
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: owner}))
	}
	return r
}
func gifFileResponse(status int, media string, body io.Reader, length int64) *http.Response {
	return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": {media}}, Body: io.NopCloser(body), ContentLength: length}
}
func gifFileCatalog(asset providerGIF) *http.Response {
	body, _ := json.Marshal(map[string]any{"results": []providerGIF{asset}, "provider_key": "must-stay-private"})
	return gifFileResponse(200, "application/json", bytes.NewReader(body), int64(len(body)))
}
func TestSocialDraftGIFFileCopiesEveryRequestedRendition(t *testing.T) {
	mp4 := []byte{0, 0, 0, 24, 'f', 't', 'y', 'p', 'm', 'p', '4', '2', 0, 0, 0, 0, 'm', 'p', '4', '2', 'i', 's', 'o', 'm'}
	for _, tc := range []struct {
		name, media, path string
		body              []byte
	}{
		{"gif", "image/gif", "full.gif", []byte("GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff;")},
		{"poster", "image/png", "still.jpg", []byte("\x89PNG\r\n\x1a\nposter")},
		{"poster", "image/jpeg", "still.jpg", []byte("\xff\xd8\xff\xdbposter")},
		{"poster", "image/webp", "still.jpg", []byte("RIFF\x00\x00\x00\x00WEBPVP8 ")},
		{"mp4", "video/mp4", "video.mp4", mp4},
		{"webm", "video/webm", "video.webm", []byte("\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01")},
	} {
		t.Run(tc.name+" "+tc.media, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("TMPDIR", dir)
			calls := 0
			asset := gifFixture()
			asset.Formats["webm"] = gifRendition{URL: "https://static.klipy.com/ii/example/video.webm"}
			s := &Server{Config: Config{KlipyAPIKey: "must-stay-private"}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.Header.Get("Authorization") != "" || r.Header.Get("DPoP") != "" {
					t.Error("viewer credentials forwarded to provider")
				}
				if r.URL.Host == "api.klipy.com" {
					if r.URL.Path != "/v2/posts" || r.URL.Query().Get("ids") != "123" || r.URL.Query().Get("key") != "must-stay-private" {
						t.Error("not exact catalog lookup", r.URL.Path)
					}
					return gifFileCatalog(asset), nil
				}
				if r.URL.Host != "static.klipy.com" || r.URL.Path != "/ii/example/"+tc.path || r.URL.RawQuery != "" || r.Header.Get("Accept-Encoding") != "identity" {
					t.Error("unexpected media request", r.URL.Path)
				}
				length := int64(len(tc.body))
				if tc.name == "webm" {
					length = -1
				}
				return gifFileResponse(200, tc.media+"; charset=binary", bytes.NewReader(tc.body), length), nil
			})}}
			// The private route must use Public, never the internal AppView HTTP client.
			s.HTTP = &http.Client{Transport: gifTransport(func(*http.Request) (*http.Response, error) { t.Fatal("GIF was proxied to AppView"); return nil, nil })}
			handler := s.Handler()
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, gifFileRequest("?id=123&rendition="+tc.name, "did:plc:owner"))
			if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), tc.body) || w.Header().Get("Content-Type") != tc.media || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("X-Content-Type-Options") != "nosniff" || w.Result().ContentLength != int64(len(tc.body)) || calls != 2 {
				t.Fatal(w.Code, w.Header(), w.Body.String(), calls)
			}
			if strings.Contains(fmt.Sprint(w.Header()), "must-stay-private") {
				t.Fatal("provider key exposed")
			}
			if files, _ := os.ReadDir(dir); len(files) != 0 {
				t.Fatal("temporary GIF file leaked")
			}
		})
	}
}
func TestSocialDraftGIFFileRequiresAuthAndExactSelectors(t *testing.T) {
	calls := 0
	s := &Server{Config: Config{KlipyAPIKey: "secret"}, Public: &http.Client{Transport: gifTransport(func(*http.Request) (*http.Response, error) { calls++; return nil, fmt.Errorf("must not fetch") })}}
	for _, owner := range []string{"", gatewaycore.AnonymousDiscoveryDID} {
		w := httptest.NewRecorder()
		s.socialDraftGIF(w, gifFileRequest("?id=123&rendition=gif", owner))
		if w.Code != 401 {
			t.Fatal(w.Code)
		}
	}
	for _, query := range []string{"?id=123", "?rendition=gif", "?id=https://evil.invalid&rendition=gif", "?id=123&rendition=bad", "?id=123&rendition=gif&url=https://evil.invalid", "?id=123&id=456&rendition=gif", "?id=123&rendition=gif&rendition=mp4", "?id=123&rendition=%zz"} {
		w := httptest.NewRecorder()
		s.socialDraftGIF(w, gifFileRequest(query, "did:plc:owner"))
		if w.Code != 400 {
			t.Fatal(query, w.Code)
		}
	}
	if calls != 0 {
		t.Fatal("invalid selector fetched provider")
	}
	s.Config.KlipyAPIKey = ""
	w := httptest.NewRecorder()
	s.socialDraftGIF(w, gifFileRequest("?id=123&rendition=gif", "did:plc:owner"))
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
}
func TestSocialDraftGIFFileNeverSubstitutesIdentityOrMissingFormat(t *testing.T) {
	for _, mismatch := range []bool{false, true} {
		asset := gifFixture()
		rendition := "mp4"
		if mismatch {
			asset.ID = "other"
			rendition = "gif"
		} else {
			delete(asset.Formats, "mp4")
			asset.Formats["webm"] = gifRendition{URL: "https://static.klipy.com/ii/example/video.webm"}
		}
		calls := 0
		s := &Server{Config: Config{KlipyAPIKey: "secret"}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.URL.Host != "api.klipy.com" {
				t.Error("missing rendition fetched another file")
			}
			return gifFileCatalog(asset), nil
		})}}
		w := httptest.NewRecorder()
		s.socialDraftGIF(w, gifFileRequest("?id=123&rendition="+rendition, "did:plc:owner"))
		if w.Code != 404 || calls != 1 {
			t.Fatal(w.Code, calls)
		}
	}
}
func TestSocialDraftGIFFileRejectsProviderURLTraversalAndCredentials(t *testing.T) {
	for _, raw := range []string{"https://127.0.0.1/ii/a.png", "https://static.klipy.com/ii/../secret.png", "https://static.klipy.com/ii/%2e%2e/secret.png", "https://static.klipy.com/ii/a.png?key=secret", "https://static.klipy.com/ii/a.png#fragment", "https://user:secret@static.klipy.com/ii/a.png", "https://static.klipy.com:443/ii/a.png", "http://static.klipy.com/ii/a.png", "https://static.klipy.com/private/a.png"} {
		asset := gifFixture()
		asset.Formats["preview"] = gifRendition{URL: raw}
		calls := 0
		s := &Server{Config: Config{KlipyAPIKey: "secret"}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.URL.Host != "api.klipy.com" {
				t.Error("unsafe URL fetched")
			}
			return gifFileCatalog(asset), nil
		})}}
		w := httptest.NewRecorder()
		s.socialDraftGIF(w, gifFileRequest("?id=123&rendition=poster", "did:plc:owner"))
		if w.Code == 200 || calls != 1 {
			t.Fatal(raw, w.Code, calls)
		}
	}
}
func TestSocialDraftGIFFileDoesNotFollowCatalogOrMediaRedirects(t *testing.T) {
	for _, catalog := range []bool{false, true} {
		calls := 0
		s := &Server{Config: Config{KlipyAPIKey: "secret"}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.URL.Host == "api.klipy.com" && !catalog {
				return gifFileCatalog(gifFixture()), nil
			}
			res := gifFileResponse(302, "text/plain", strings.NewReader("secret"), 6)
			res.Header.Set("Location", "https://127.0.0.1/private?key=secret")
			return res, nil
		})}}
		w := httptest.NewRecorder()
		s.socialDraftGIF(w, gifFileRequest("?id=123&rendition=gif", "did:plc:owner"))
		want := 2
		if catalog {
			want = 1
		}
		if w.Code != 502 || calls != want || strings.Contains(w.Body.String(), "secret") || w.Header().Get("Location") != "" {
			t.Fatal(w.Code, calls, w.Body.String())
		}
	}
}

type countedGIFBody struct{ remaining, read int64 }

func (b *countedGIFBody) Read(p []byte) (int, error) {
	if b.remaining == 0 {
		return 0, io.EOF
	}
	n := min(int64(len(p)), b.remaining)
	clear(p[:n])
	b.remaining -= n
	b.read += n
	return int(n), nil
}
func TestSocialDraftGIFFileValidatesSizeMIMEAndCompleteLength(t *testing.T) {
	for _, tc := range []struct {
		name, rendition, media string
		body                   io.Reader
		length                 int64
		status                 int
	}{
		{"wrong type", "gif", "image/png", strings.NewReader("GIF89a"), 6, 502},
		{"wrong bytes", "gif", "image/gif", strings.NewReader("<html>bad</html>"), 16, 502},
		{"truncated", "gif", "image/gif", strings.NewReader("GIF89a"), 100, 502},
		{"extra bytes", "gif", "image/gif", strings.NewReader("GIF89a"), 1, 502},
		{"empty", "gif", "image/gif", strings.NewReader(""), -1, 502},
		{"gif advertised oversized", "gif", "image/gif", strings.NewReader(""), (100 << 20) + 1, 413},
		{"poster advertised oversized", "poster", "image/png", strings.NewReader(""), 1_000_001, 413},
		{"gif unknown oversized", "gif", "image/gif", &countedGIFBody{remaining: 200 << 20}, -1, 413},
		{"poster unknown oversized", "poster", "image/png", &countedGIFBody{remaining: 2_000_000}, -1, 413},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("TMPDIR", dir)
			s := &Server{Config: Config{KlipyAPIKey: "secret"}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
				if r.URL.Host == "api.klipy.com" {
					return gifFileCatalog(gifFixture()), nil
				}
				return gifFileResponse(200, tc.media, tc.body, tc.length), nil
			})}}
			w := httptest.NewRecorder()
			s.socialDraftGIF(w, gifFileRequest("?id=123&rendition="+tc.rendition, "did:plc:owner"))
			if w.Code != tc.status || strings.HasPrefix(w.Body.String(), "GIF89a") {
				t.Fatal(w.Code, w.Body.String())
			}
			if counted, ok := tc.body.(*countedGIFBody); ok {
				limit := int64(100 << 20)
				if tc.rendition == "poster" {
					limit = 1_000_000
				}
				if counted.read != limit+1 {
					t.Fatal("unbounded upstream body read", counted.read)
				}
			}
			if files, _ := os.ReadDir(dir); len(files) != 0 {
				t.Fatal("invalid GIF temporary file leaked")
			}
		})
	}
}
func TestSocialDraftGIFFileRegistrationUsesDraftAdmission(t *testing.T) {
	_, a := draftRedisAdmission(t)
	calls := 0
	s := &Server{Config: Config{KlipyAPIKey: "secret"}, Limiter: &RequestLimiter{Redis: a.redis, Namespace: a.namespace}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) { calls++; return gifFileCatalog(gifFixture()), nil })}}
	handler := s.Handler()
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, gifFileRequest("?id=123&rendition=gif", ""))
	if w.Code != 401 || calls != 0 {
		t.Fatal("route bypassed authentication", w.Code, calls)
	}
	for i := 0; i < socialDraftUploadSlots; i++ {
		release, status := a.acquire(httptest.NewRequest("GET", "/", nil).Context(), fmt.Sprintf("did:plc:busy%d", i), true, time.Now())
		if status != 0 {
			t.Fatal(status)
		}
		defer release()
	}
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, gifFileRequest("?id=123&rendition=gif", "did:plc:owner"))
	if w.Code != 429 || calls != 0 {
		t.Fatal("GIF copy bypassed transfer admission", w.Code, calls)
	}
}

type privateGIFResolver struct{ calls int }

func (r *privateGIFResolver) LookupNetIP(context.Context, string, string) ([]netip.Addr, error) {
	r.calls++
	return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
}
func TestSocialDraftGIFFileRetainsPublicDNSAdmission(t *testing.T) {
	resolver := &privateGIFResolver{}
	safe := gatewaycore.NewPublicHTTPClient(resolver)
	defer safe.CloseIdleConnections()
	s := &Server{Config: Config{KlipyAPIKey: "secret"}, Public: &http.Client{Transport: gifTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == "api.klipy.com" {
			return gifFileCatalog(gifFixture()), nil
		}
		return safe.Transport.RoundTrip(r)
	})}}
	w := httptest.NewRecorder()
	s.socialDraftGIF(w, gifFileRequest("?id=123&rendition=gif", "did:plc:owner"))
	if w.Code != 502 || resolver.calls != 1 {
		t.Fatal("static media bypassed private DNS rejection", w.Code, resolver.calls)
	}
	if strings.Contains(w.Body.String(), "127.0.0.1") || strings.Contains(w.Body.String(), "secret") {
		t.Fatal("upstream detail exposed", w.Body.String())
	}
}
