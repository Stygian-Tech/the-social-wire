package topicreadcore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"strings"
	"testing"
	"time"
)

type financeRemoteFailure struct {
	corpuscore.Store
	err error
}

func (f financeRemoteFailure) Finance(context.Context, string, time.Time) (corpuscore.FinanceGeneration, error) {
	return corpuscore.FinanceGeneration{}, f.err
}

type financeFallbackFixture struct {
	corpuscore.Store
	calls int
}

func (f *financeFallbackFixture) Feed(_ context.Context, q corpuscore.FeedQuery, now time.Time) (corpuscore.Page, error) {
	f.calls++
	item := topicItem("macro-topic-fallback")
	item.Title = "Central bank announces interest rate cut and economic growth outlook"
	return corpuscore.Page{GenerationID: "11111111-1111-1111-1111-111111111111", GeneratedAt: now, Language: q.Language, Source: "ranked", Rows: []corpuscore.Row{{Item: item}}, Exhausted: true}, nil
}
func TestFinanceRemoteFallbackDistinguishesHTTPFromMalformedAndNetworkFailures(t *testing.T) {
	db := selectionDB(t)
	for _, fixture := range []struct {
		name     string
		err      error
		fallback bool
	}{{"status", corpuscore.RemoteStatusError{Status: 503}, true}, {"version-header", corpuscore.RemoteVersionError{}, true}, {"network", corpuscore.ErrUnavailable, false}, {"malformed-body", corpuscore.ErrContractMismatch, false}} {
		t.Run(fixture.name, func(t *testing.T) {
			corpus := &financeFallbackFixture{}
			wire, err := NewWireStore(corpus, strings.Repeat("a", 32), "visible", &ModerationCache{})
			if err != nil {
				t.Fatal(err)
			}
			store := FinanceStore{DB: db, Wire: wire, Remote: financeRemoteFailure{err: fixture.err}}
			source, err := store.source(context.Background(), "en", time.Now())
			if fixture.fallback {
				if err != nil || source.Source == nil || *source.Source != "simplified_fallback" || corpus.calls != 1 {
					t.Fatal(source, err, corpus.calls)
				}
			} else if !errors.Is(err, ErrUnavailable) || corpus.calls != 0 {
				t.Fatal(err, corpus.calls)
			}
		})
	}
}
