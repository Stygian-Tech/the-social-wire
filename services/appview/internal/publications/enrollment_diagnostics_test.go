package publications

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func captureEnrollmentLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var output bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&output, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &output
}

func TestEnrollmentFailureLogIsSanitizedAndFailureOnly(t *testing.T) {
	output := captureEnrollmentLogs(t)
	logEnrollmentFailure("enroll", time.Now(), 2, 78, 42, nil, nil)
	if output.Len() != 0 {
		t.Fatal("success logged as failure")
	}
	err := thinappviewcore.WrapEnrollmentFailure("rss_fetch", "https://user:SECRET@publisher.social/private?token=SECRET", 503, errors.New("Bearer SECRET did:plc:private-account private article"))
	logEnrollmentFailure("enroll", time.Now(), 2, 78, 42, errors.Join(err, err), nil)
	var record map[string]any
	if e := json.Unmarshal(output.Bytes(), &record); e != nil {
		t.Fatal(e)
	}
	for k, want := range map[string]float64{"requested_authors": 2, "requested_feeds": 78, "indexed": 42, "failure_count": 2} {
		if record[k] != want {
			t.Fatalf("%s=%v", k, record[k])
		}
	}
	if record["phase"] != "enroll" || record["level"] != "ERROR" || record["duration_ms"].(float64) < 0 {
		t.Fatalf("record=%v", record)
	}
	for _, forbidden := range []string{"SECRET", "private", "did:", "https:", "?", "Bearer"} {
		if strings.Contains(output.String(), forbidden) {
			t.Fatalf("leaked %s", forbidden)
		}
	}
	output.Reset()
	canceledSource := thinappviewcore.WrapEnrollmentFailure("rss_fetch", "https://publisher.social/feed?SECRET", 0, context.Canceled)
	logEnrollmentFailure("enroll", time.Now(), 0, 1, 0, errors.Join(canceledSource, context.Canceled, context.Canceled), context.Canceled)
	record = nil
	if e := json.Unmarshal(output.Bytes(), &record); e != nil {
		t.Fatal(e)
	}
	if record["request_canceled"] != true || record["failure_count"] != float64(1) {
		t.Fatalf("record=%v", record)
	}
	output.Reset()
	logEnrollmentFailure("counters", time.Now(), 2, 78, 42, context.DeadlineExceeded, context.DeadlineExceeded)
	if !strings.Contains(output.String(), `"phase":"counters"`) || !strings.Contains(output.String(), `"request_timed_out":true`) || !strings.Contains(output.String(), `"failure_count":0`) {
		t.Fatal(output.String())
	}
}

func TestEnrollmentRouteLogsOnlyFailedRequestsOnBothAliases(t *testing.T) {
	output := captureEnrollmentLogs(t)
	service := publicationcore.NewService(nil, nil, nil)
	defer service.Close()
	service.Enroller = &publicationcore.Enroller{}
	mux := http.NewServeMux()
	(Routes{Service: service}).Register(mux)
	for _, path := range []string{"/v1/appview/enroll", "/xrpc/app.thesocialwire.appview.enrollSources"} {
		for _, body := range []string{`{}`, `{"authorDids":["SECRET-invalid-author"]}`} {
			output.Reset()
			req := httptest.NewRequest("POST", path, strings.NewReader(body))
			req = req.WithContext(gatewaycore.ContextWithAuth(req.Context(), gatewaycore.AuthContext{DID: "did:plc:SECRET-account"}))
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, req)
			if body == `{}` {
				if w.Code != 200 || output.Len() != 0 {
					t.Fatalf("successful request status=%d logs=%s", w.Code, output)
				}
			} else {
				if w.Code != 503 || !strings.Contains(output.String(), `"category":"pds_author"`) || strings.Contains(output.String(), "SECRET") {
					t.Fatalf("failure status=%d logs=%s", w.Code, output)
				}
			}
		}
	}
}
