package health

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
)

type controlledProbes struct{ started, ready bool }

func (probes controlledProbes) Startup(context.Context) error {
	if probes.started {
		return nil
	}
	return errors.New("private database failure")
}
func (probes controlledProbes) Ready(context.Context) error {
	if probes.ready {
		return nil
	}
	return errors.New("private publisher failure")
}

func TestHealthKeepsLivenessStartupAndReadinessDistinct(t *testing.T) {
	handler := Handler(indexingworkercore.Coordinator, controlledProbes{started: true})
	for _, test := range []struct {
		path   string
		status int
		body   string
	}{
		{"/livez", 200, `"status":"live"`},
		{"/startupz?probe=railway", 200, `"status":"started"`},
		{"/readyz", 503, `"status":"unavailable"`},
		{"/unknown", 404, `"error":"not_found"`},
	} {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, test.path, nil))
		if response.Code != test.status || !strings.Contains(response.Body.String(), test.body) || strings.Contains(response.Body.String(), "private") {
			t.Fatalf("%s: %d %s", test.path, response.Code, response.Body.String())
		}
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/readyz", nil))
	if response.Code != 405 {
		t.Fatal("only GET probes are supported")
	}
}
