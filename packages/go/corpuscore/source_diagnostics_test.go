package corpuscore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestSourceFailureDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		name      string
		status    int
		version   string
		body      string
		transport bool
		reason    string
	}{
		{"oversized", 200, "3", "private-payload", false, "response-limit"},
		{"missing", 404, "3", "{}", false, "http-status"},
		{"unauthorized", 401, "3", "{}", false, "http-status"},
		{"unavailable", 503, "3", "{}", false, "http-status"},
		{"version", 200, "2", "{}", false, "contract-version"},
		{"transport", 0, "", "", true, "transport"},
		{"decode", 200, "3", "null", false, "decode"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var output bytes.Buffer
			previous := slog.Default()
			slog.SetDefault(slog.New(slog.NewJSONHandler(&output, nil)))
			defer slog.SetDefault(previous)
			remote := NewRemoteStore(RemoteConfig{"https://private.example", "appview", strings.Repeat("secret", 8)}, &http.Client{Transport: batchRoundTripper(func(r *http.Request) (*http.Response, error) {
				if r.Header.Get("X-Request-ID") != "request-123" {
					t.Fatal("missing correlation")
				}
				if tc.transport {
					return nil, errors.New("sensitive transport error")
				}
				return &http.Response{StatusCode: tc.status, Header: http.Header{"X-Wire-Corpus-Contract": {tc.version}}, Body: io.NopCloser(strings.NewReader(tc.body))}, nil
			})})
			if remote.MaximumResponseBytes != 8<<20 {
				t.Fatal("default cap changed")
			}
			remote.MaximumResponseBytes = 8
			phases := map[string]int{}
			ctx := WithSourceRequestID(WithQueryObserver(context.Background(), func(phase string, _ time.Duration) { phases[phase]++ }), "request-123")
			_, err := remote.Sports(ctx, "private-language", time.Now())
			if err == nil {
				t.Fatal("failure became success")
			}
			if tc.reason == "response-limit" && !errors.Is(err, ErrUnavailable) {
				t.Fatal(err)
			}
			if phases["source-transport"] != 1 || (tc.reason != "decode" && phases["source-decode"] != 0) {
				t.Fatal(phases)
			}
			var fields map[string]any
			if err := json.Unmarshal(bytes.TrimSpace(output.Bytes()), &fields); err != nil {
				t.Fatal(err, output.String())
			}
			if fields["reason"] != tc.reason || fields["family"] != "sports" || fields["request_id"] != "request-123" || fields["status"] != float64(tc.status) {
				t.Fatal(fields)
			}
			if tc.reason == "response-limit" && (fields["bytes"] != float64(9) || fields["limit_bytes"] != float64(8)) {
				t.Fatal(fields)
			}
			allowed := map[string]bool{"time": true, "level": true, "msg": true, "request_id": true, "family": true, "reason": true, "status": true, "bytes": true, "limit_bytes": true}
			for key := range fields {
				if !allowed[key] {
					t.Fatal("unexpected diagnostic field", key)
				}
			}
			for _, forbidden := range []string{"private-payload", "private.example", "private-language", "sensitive transport error", "secret"} {
				if strings.Contains(output.String(), forbidden) {
					t.Fatal("diagnostic leaked private data")
				}
			}
		})
	}
}

func TestSourceCorrelationIDBounds(t *testing.T) {
	for _, id := range []string{"", strings.Repeat("a", 129), "did:plc:viewer", "unsafe\nheader", "url?token=value"} {
		if SourceRequestID(WithSourceRequestID(context.Background(), id)) != "" {
			t.Fatal(id)
		}
	}
	if ValidSourceRequestID(strings.Repeat("a", 128)) == "" {
		t.Fatal("valid boundary rejected")
	}
}
