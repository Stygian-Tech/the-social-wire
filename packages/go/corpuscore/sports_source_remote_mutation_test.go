package corpuscore

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

func TestSportsRemoteConditionalCacheOwnsReturnedCandidates(t *testing.T) {
	fixture := sportsSourceFixture(t)
	published := time.Now().UTC().Truncate(time.Second)
	(*fixture.Candidates)[0].PublishedAt = &published
	(*fixture.Candidates)[0].Analysis.SportIDs = []string{"sport"}
	(*fixture.Candidates)[0].Analysis.Associations = []sportscore.Association{{EntityID: "team", Confidence: .95, ResolverVersion: sportscore.ResolverVersion, Evidence: []string{"fixture"}}}
	calls := 0
	remote := NewRemoteStore(RemoteConfig{"https://corpus.example", "appview", strings.Repeat("s", 32)}, &http.Client{Transport: batchRoundTripper(func(*http.Request) (*http.Response, error) {
		calls++
		value := fixture
		if calls > 1 {
			value.GenerationUnchanged = true
			value.Candidates = nil
		}
		body, err := MarshalHTTP(value)
		if err != nil {
			t.Fatal(err)
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"X-Wire-Corpus-Contract": {"3"}}, Body: io.NopCloser(strings.NewReader(string(body)))}, nil
	})})
	for range 3 {
		value, err := remote.SportsSource(context.Background(), SportsSourceRequest{Language: "en"}, time.Now())
		if err != nil || !reflect.DeepEqual(value.Candidates, fixture.Candidates) {
			t.Fatal("caller mutation escaped into validated cache", err, value)
		}
		candidate := &(*value.Candidates)[0]
		candidate.ItemID = "changed"
		candidate.BaseScore = 20
		*candidate.PublishedAt = time.Time{}
		candidate.Analysis.SportIDs[0] = "changed"
		candidate.Analysis.Associations[0].EntityID = "changed"
		candidate.Analysis.Associations[0].Evidence[0] = "changed"
	}
}
