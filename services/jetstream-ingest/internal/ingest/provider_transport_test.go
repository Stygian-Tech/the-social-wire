package ingest

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

type providerFixtureTransport func(*http.Request) (*http.Response, error)

func (f providerFixtureTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestProviderTransportPreservesStructuredRejectionBody(t *testing.T) {
	for _, code := range []string{"CursorTooOld", "FutureCursor"} {
		t.Run(code, func(t *testing.T) {
			body := `{"error":"` + code + `","message":"fixture rejection"}`
			rejections := &ProviderRejections{}
			transport := ProviderTransport{Rejections: rejections, Base: providerFixtureTransport(func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 400, Body: io.NopCloser(strings.NewReader(body))}, nil
			})}
			request, _ := http.NewRequestWithContext(context.Background(), "GET", "https://fixture.invalid/xrpc/network.bsky.jetstream.subscribeEvents", nil)
			response, err := transport.RoundTrip(request)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			got, err := io.ReadAll(response.Body)
			if err != nil || string(got) != body {
				t.Fatalf("SDK body changed: %s %v", got, err)
			}
			if got := rejections.Snapshot(); got.Code != code || got.Message != "fixture rejection" {
				t.Fatalf("structured rejection lost: %+v", got)
			}
			rejections.Clear()
			if rejections.Snapshot().Code != "" {
				t.Fatal("prior rejection survived clear")
			}
		})
	}
}

func TestProviderTransportDoesNotInferCursorErrorsFromMessages(t *testing.T) {
	for _, fixture := range []struct {
		name   string
		status int
		body   string
		err    error
	}{
		{"unstructured", 400, "FutureCursor: arbitrary prose", nil},
		{"message only", 400, `{"message":"CursorTooOld"}`, nil},
		{"wrong status", 503, `{"error":"FutureCursor"}`, nil},
		{"network failure", 0, "", errors.New("FutureCursor: failed to connect")},
		{"oversized envelope", 400, `{"error":"FutureCursor","message":"` + strings.Repeat("x", 5000) + `"}`, nil},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			rejections := &ProviderRejections{}
			transport := ProviderTransport{Rejections: rejections, Base: providerFixtureTransport(func(*http.Request) (*http.Response, error) {
				if fixture.err != nil {
					return nil, fixture.err
				}
				return &http.Response{StatusCode: fixture.status, Body: io.NopCloser(strings.NewReader(fixture.body))}, nil
			})}
			request, _ := http.NewRequest("GET", "https://fixture.invalid/live", nil)
			response, err := transport.RoundTrip(request)
			if fixture.err != nil && !errors.Is(err, fixture.err) {
				t.Fatalf("network error changed: %v", err)
			}
			if response != nil {
				defer response.Body.Close()
				body, err := io.ReadAll(response.Body)
				if err != nil || string(body) != fixture.body {
					t.Fatal("body was consumed or truncated")
				}
			}
			if rejections.Snapshot().Code != "" {
				t.Fatalf("inferred structured code from generic failure: %+v", rejections.Snapshot())
			}
		})
	}
}

func TestLiveOnlyProviderTransportRejectsArchiveBeforeCallingBase(t *testing.T) {
	calls := 0
	transport := ProviderTransport{LiveOnly: true, Base: providerFixtureTransport(func(*http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 200, Body: http.NoBody}, nil
	})}
	for _, method := range []string{"planSnapshot", "getSegment", "getBlock"} {
		request, _ := http.NewRequest("GET", "https://fixture.invalid/xrpc/network.bsky.jetstream."+method, nil)
		if _, err := transport.RoundTrip(request); !errors.Is(err, ErrLiveArchiveRequest) {
			t.Fatalf("archive %s escaped live-only boundary: %v", method, err)
		}
	}
	if calls != 0 {
		t.Fatal("forbidden archive requests reached base transport")
	}
	request, _ := http.NewRequest("GET", "https://fixture.invalid/xrpc/network.bsky.jetstream.subscribeEvents", nil)
	if _, err := transport.RoundTrip(request); err != nil || calls != 1 {
		t.Fatalf("live request blocked: %v calls=%d", err, calls)
	}
}
