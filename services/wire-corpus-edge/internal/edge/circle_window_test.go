package edge

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
)

func TestCandidateLookbackAllowsProcessingDelayWithoutExpandingWindow(t *testing.T) {
	for _, test := range []struct {
		name   string
		offset time.Duration
		status int
	}{
		{"exact boundary", 0, 200},
		{"processing delay", -500 * time.Millisecond, 200},
		{"maximum tolerance", -time.Minute, 200},
		{"outside tolerance", -time.Minute - time.Nanosecond, 400},
		{"narrower window", time.Hour, 200},
	} {
		t.Run(test.name, func(t *testing.T) {
			h, store := testHandler()
			oldest := h.Now().Add(-7 * 24 * time.Hour)
			request := corpuscore.CandidateRequest{
				ActorHashes: []string{"h1:" + strings.Repeat("a", 64)},
				Language:    "en",
				Since:       oldest.Add(test.offset),
				Limit:       3,
			}
			body, err := json.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			response := perform(h, signed(h, "POST", "/internal/wire/v1/circle-candidates", body))
			if response.Code != test.status {
				t.Fatalf("status = %d, want %d", response.Code, test.status)
			}
			if test.status != 200 {
				if !store.candidate.Since.IsZero() {
					t.Fatal("rejected request reached the store")
				}
				return
			}
			want := request.Since
			if want.Before(oldest) {
				want = oldest
			}
			if !store.candidate.Since.Equal(want) {
				t.Fatalf("query since = %s, want %s", store.candidate.Since, want)
			}
		})
	}
}
