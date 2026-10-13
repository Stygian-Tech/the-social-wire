package corpuscore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestRemoteSourceSeparatesTransportAndDecode(t *testing.T) {
	now := time.Now()
	for _, domain := range []string{"finance", "sports"} {
		t.Run(domain, func(t *testing.T) {
			var data []byte
			if domain == "finance" {
				data, _ = MarshalHTTP(FinanceGeneration{GenerationID: "source", GeneratedAt: now, ExpiresAt: now.Add(time.Hour), Language: "en", Candidates: []financecore.RankCandidate{}, Instruments: []financecore.Instrument{}})
			} else {
				data, _ = MarshalHTTP(SportsGeneration{GenerationID: "source", GeneratedAt: now, ExpiresAt: now.Add(time.Hour), Language: "en", Candidates: []sportscore.RankCandidate{}, Entities: []sportscore.Entity{}})
			}
			remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": []string{"3"}}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
			})})
			phases := map[string]int{}
			ctx := WithQueryObserver(context.Background(), func(phase string, elapsed time.Duration) {
				if elapsed < 0 {
					t.Fatal(elapsed)
				}
				phases[phase]++
			})
			var err error
			if domain == "finance" {
				_, err = remote.Finance(ctx, "en", now)
			} else {
				_, err = remote.Sports(ctx, "en", now)
			}
			if err != nil || len(phases) != 2 || phases["source-transport"] != 1 || phases["source-decode"] != 1 {
				t.Fatal(err, phases)
			}
		})
	}
}
