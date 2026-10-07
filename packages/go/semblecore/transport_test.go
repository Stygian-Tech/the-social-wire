package semblecore

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type roundTrip func(*http.Request) (*http.Response, error)

func (f roundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestPublicTransportLimitsAndNoViewerAuth(t *testing.T) {
	client := &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("DPoP") != "" || r.Header.Get("Accept") != "application/json" {
			t.Fatal("public auth boundary")
		}
		if _, ok := r.Context().Deadline(); !ok {
			t.Fatal("no timeout")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(strings.Repeat("x", (8<<20)+1)))}, nil
	})}
	transport := NewHTTPTransport(map[string]string{"SEMBLE_PUBLIC_API_BASE_URL": " https://api.semble.test/api/// "}, client)
	if transport.BaseURL != "https://api.semble.test/api" {
		t.Fatal(transport.BaseURL)
	}
	if _, _, e := transport.Get(context.Background(), "/a", url.Values{}); e == nil {
		t.Fatal("unbounded response accepted")
	}
	if NewHTTPTransport(nil, client).BaseURL != "https://api.semble.so/api" {
		t.Fatal("default")
	}
}
