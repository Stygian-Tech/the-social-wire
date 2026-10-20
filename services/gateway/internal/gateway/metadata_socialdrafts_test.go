package gateway

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSocialDraftUploadPreflightAllowsPrivateUploadHeader(t *testing.T) {
	s := &Server{Config: Config{AllowedOrigins: []string{"https://web.valid"}}}
	handler := s.Handler()
	r := httptest.NewRequest("OPTIONS", draftPrefix+"uploadAttachment", nil)
	r.Header.Set("Origin", "https://web.valid")
	r.Header.Set("Access-Control-Request-Method", "POST")
	r.Header.Set("Access-Control-Request-Headers", "authorization, dpop, content-type, x-social-draft-upload-id")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	if w.Code != 204 || w.Header().Get("Access-Control-Allow-Origin") != "https://web.valid" {
		t.Fatal(w.Code, w.Header())
	}
	allowed := map[string]bool{}
	for _, header := range strings.Split(w.Header().Get("Access-Control-Allow-Headers"), ",") {
		allowed[strings.ToLower(strings.TrimSpace(header))] = true
	}
	for _, header := range []string{"authorization", "dpop", "content-type", "x-social-draft-upload-id"} {
		if !allowed[header] {
			t.Fatalf("preflight blocks %s", header)
		}
	}
}
