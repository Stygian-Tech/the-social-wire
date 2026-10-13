package edge

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func TestGenerationResponseSizeDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		family string
		value  any
	}{
		{"finance", corpuscore.FinanceGeneration{GenerationID: "private-generation", Candidates: make([]financecore.RankCandidate, 2), Instruments: make([]financecore.Instrument, 3)}},
		{"sports", corpuscore.SportsGeneration{GenerationID: "private-generation", Candidates: make([]sportscore.RankCandidate, 2), Entities: make([]sportscore.Entity, 3)}},
	} {
		t.Run(tc.family, func(t *testing.T) {
			var output bytes.Buffer
			previous := slog.Default()
			slog.SetDefault(slog.New(slog.NewJSONHandler(&output, nil)))
			defer slog.SetDefault(previous)
			w := httptest.NewRecorder()
			w.Header().Set("X-Request-ID", "request-123")
			writeJSON(w, 200, tc.value, true)
			var fields map[string]any
			if err := json.Unmarshal(bytes.TrimSpace(output.Bytes()), &fields); err != nil {
				t.Fatal(err)
			}
			if fields["family"] != tc.family || fields["request_id"] != "request-123" || fields["bytes"] != float64(w.Body.Len()) || fields["candidate_count"] != float64(2) || fields["catalog_count"] != float64(3) {
				t.Fatal(fields)
			}
			allowed := map[string]bool{"time": true, "level": true, "msg": true, "request_id": true, "family": true, "status": true, "bytes": true, "candidate_count": true, "catalog_count": true}
			for key := range fields {
				if !allowed[key] {
					t.Fatal("unexpected diagnostic field", key)
				}
			}
			if strings.Contains(output.String(), "private-generation") {
				t.Fatal("generation leaked")
			}
			if w.Code != 200 || w.Header().Get("X-Wire-Corpus-Contract") != "3" {
				t.Fatal(w)
			}
		})
	}
}

func TestEdgeRejectsUnsafeCorrelationMetadata(t *testing.T) {
	handler := NewHandler(&fixtureStore{}, Config{})
	for _, id := range []string{"request-123", "did:plc:viewer", strings.Repeat("a", 129)} {
		r := httptest.NewRequest("GET", "/livez", nil)
		r.Header.Set("X-Request-ID", id)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Header().Get("X-Request-ID") != corpuscore.ValidSourceRequestID(id) {
			t.Fatal(w.Header())
		}
	}
}
