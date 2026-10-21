package socialdrafts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialdraftcore"
)

type fakeService struct {
	owner    string
	err      error
	uploaded string
}

func (s *fakeService) Reserve(_ context.Context, owner string, in socialdraftcore.ReserveInput) (socialdraftcore.Asset, error) {
	s.owner = owner
	return socialdraftcore.Asset{AssetID: in.AssetID}, s.err
}
func (s *fakeService) Upload(_ context.Context, owner, id string, r io.Reader, n int64) (socialdraftcore.Asset, error) {
	s.owner = owner
	b, e := io.ReadAll(r)
	s.uploaded = string(b)
	if e != nil {
		return socialdraftcore.Asset{}, e
	}
	return socialdraftcore.Asset{AssetID: id, ByteLength: n}, s.err
}
func (s *fakeService) Download(_ context.Context, owner, id string) (io.ReadCloser, socialdraftcore.Asset, error) {
	s.owner = owner
	return io.NopCloser(strings.NewReader("private bytes")), socialdraftcore.Asset{AssetID: id, ContentType: "image/png", ByteLength: 13}, s.err
}
func (s *fakeService) Manifest(_ context.Context, owner, id string) (socialdraftcore.Manifest, error) {
	s.owner = owner
	return socialdraftcore.Manifest{DraftID: id}, s.err
}
func (s *fakeService) PutManifest(_ context.Context, owner string, in socialdraftcore.PutManifestInput) (socialdraftcore.Manifest, error) {
	s.owner = owner
	return socialdraftcore.Manifest{DraftID: in.DraftID}, s.err
}
func (s *fakeService) DeleteManifest(_ context.Context, owner, id string, _ int64) (socialdraftcore.Manifest, error) {
	s.owner = owner
	return socialdraftcore.Manifest{DraftID: id, Deleted: true}, s.err
}
func request(method, name, body, owner string) *http.Request {
	r := httptest.NewRequest(method, prefix+name, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if owner != "" {
		r = r.WithContext(gatewaycore.ContextWithAuth(r.Context(), gatewaycore.AuthContext{DID: owner}))
	}
	return r
}
func TestAuthenticationAndDisabledStorage(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, owner := range []string{"", gatewaycore.AnonymousDiscoveryDID, "did:plc:viewer"} {
		for _, tc := range []struct{ method, name string }{{"POST", "reserveAttachment"}, {"POST", "uploadAttachment"}, {"GET", "getAttachment"}, {"GET", "getManifest"}, {"POST", "putManifest"}, {"POST", "deleteManifest"}} {
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, request(tc.method, tc.name, "{}", owner))
			want := 401
			if owner == "did:plc:viewer" {
				want = 503
			}
			if w.Code != want {
				t.Fatalf("%s: %d", tc.name, w.Code)
			}
		}
	}
}
func TestOwnerComesOnlyFromAuthentication(t *testing.T) {
	s := &fakeService{}
	mux := http.NewServeMux()
	Routes{Service: s}.Register(mux)
	for _, tc := range []struct{ method, name, body string }{{"POST", "reserveAttachment", `{"assetId":"a","name":"photo.jpg","contentType":"image/jpeg","byteLength":3,"sha256":"hash","kind":"photo"}`}, {"GET", "getManifest?draftId=d", ""}, {"POST", "putManifest", `{"draftId":"d","expectedRevision":0,"attachments":[]}`}, {"POST", "deleteManifest", `{"draftId":"d","expectedRevision":1}`}} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, request(tc.method, tc.name, tc.body, "did:plc:owner"))
		if w.Code != 200 || s.owner != "did:plc:owner" {
			t.Fatalf("%s: %d %s", tc.name, w.Code, w.Body.String())
		}
	}
	for _, body := range []string{`{"assetId":"a","did":"did:plc:other"}`, `{"assetId":"a"} {}`, `null`} {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, request("POST", "reserveAttachment", body, "did:plc:owner"))
		if w.Code != 400 {
			t.Fatalf("accepted %s", body)
		}
	}
}
func TestUploadBoundsAndRawDownload(t *testing.T) {
	s := &fakeService{}
	mux := http.NewServeMux()
	Routes{Service: s}.Register(mux)
	for _, tc := range []struct {
		length   int64
		kind, id string
		status   int
	}{{-1, "application/octet-stream", "a", 411}, {MaximumUploadBytes + 1, "application/octet-stream", "a", 413}, {0, "application/octet-stream", "a", 400}, {3, "application/json", "a", 400}, {3, "application/octet-stream", "", 400}, {3, "application/octet-stream", "a", 200}} {
		r := request("POST", "uploadAttachment", "raw", "did:plc:owner")
		r.ContentLength = tc.length
		r.Header.Set("Content-Type", tc.kind)
		r.Header.Set("X-Social-Draft-Upload-Id", tc.id)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("%+v: %d %s", tc, w.Code, w.Body.String())
		}
	}
	if s.uploaded != "raw" {
		t.Fatal("upload was not raw")
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, request("GET", "getAttachment?assetId=a", "", "did:plc:owner"))
	if w.Code != 200 || w.Body.String() != "private bytes" || w.Header().Get("Content-Type") != "image/png" || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Content-Length") != "13" {
		t.Fatal(w)
	}
}
func TestErrorsAreTypedAndSafe(t *testing.T) {
	for _, tc := range []struct {
		err    error
		status int
		code   string
	}{{socialdraftcore.ErrInvalid, 400, "InvalidRequest"}, {socialdraftcore.ErrNotFound, 404, "NotFound"}, {socialdraftcore.ErrConflict, 409, "Conflict"}, {socialdraftcore.ErrQuota, 413, "Quota"}, {socialdraftcore.ErrUploadPending, 409, "UploadPending"}, {socialdraftcore.ErrUnavailable, 503, "Unavailable"}, {errors.New("secret storage key"), 503, "Unavailable"}} {
		mux := http.NewServeMux()
		Routes{Service: &fakeService{err: fmt.Errorf("secret storage key: %w", tc.err)}}.Register(mux)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, request("GET", "getManifest?draftId=d", "", "did:plc:owner"))
		if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.code) || strings.Contains(w.Body.String(), "secret") {
			t.Fatal(w)
		}
	}
}

func TestRetiredReservationIDIsDistinctFromOrdinaryConflicts(t *testing.T) {
	for _, tc := range []struct {
		name, body, want string
		err              error
	}{
		{"reserveAttachment", `{"assetId":"a","name":"photo.jpg","contentType":"image/jpeg","byteLength":3,"sha256":"hash","kind":"photo"}`, "AssetRetired", errors.Join(socialdraftcore.ErrAssetRetired, socialdraftcore.ErrConflict)},
		{"reserveAttachment", `{"assetId":"a","name":"photo.jpg","contentType":"image/jpeg","byteLength":3,"sha256":"hash","kind":"photo"}`, "Conflict", socialdraftcore.ErrConflict},
		{"putManifest", `{"draftId":"d","expectedRevision":1,"attachments":[]}`, "Conflict", socialdraftcore.ErrConflict},
	} {
		mux := http.NewServeMux()
		Routes{Service: &fakeService{err: fmt.Errorf("private storage detail: %w", tc.err)}}.Register(mux)
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, request("POST", tc.name, tc.body, "did:plc:owner"))
		var payload struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(w.Body.Bytes(), &payload) != nil || w.Code != 409 || payload.Error != tc.want || strings.Contains(w.Body.String(), "private storage detail") {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}
func TestGatewayGIFQueryIsNotAnAppViewStorageRoute(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	if _, pattern := mux.Handler(httptest.NewRequest("GET", prefix+"getGifFile?id=123&rendition=gif", nil)); pattern != "" {
		t.Fatal("Gateway GIF file copy registered in AppView", pattern)
	}
}
