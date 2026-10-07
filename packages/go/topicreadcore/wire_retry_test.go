package topicreadcore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"testing"
	"time"
)

type wireRetryFixture struct {
	corpuscore.Store
	feeds    []corpuscore.FeedQuery
	editions []corpuscore.EditionQuery
}

func (f *wireRetryFixture) Feed(_ context.Context, q corpuscore.FeedQuery, now time.Time) (corpuscore.Page, error) {
	f.feeds = append(f.feeds, q)
	if q.FallbackLimit != nil {
		return corpuscore.Page{}, corpuscore.RemoteStatusError{Status: 400}
	}
	return corpuscore.Page{GenerationID: "11111111-1111-1111-1111-111111111111", GeneratedAt: now, Language: q.Language, Rows: []corpuscore.Row{}, Exhausted: true}, nil
}
func (f *wireRetryFixture) Edition(_ context.Context, q corpuscore.EditionQuery, now time.Time) (corpuscore.Edition, error) {
	f.editions = append(f.editions, q)
	if q.Region != nil || q.FallbackLimit != nil {
		return corpuscore.Edition{}, corpuscore.RemoteStatusError{Status: 400}
	}
	return corpuscore.Edition{Edition: wirecore.Edition{GenerationID: "generation", GeneratedAt: now, Language: q.Language, Source: "ranked"}}, nil
}
func TestWireLegacyAnonymousRetriesStayBoundedAndViewerFailsClosed(t *testing.T) {
	now := time.Now()
	f := &wireRetryFixture{}
	store, err := NewWireStore(f, "01234567890123456789012345678901", "visible", &ModerationCache{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.Feed(context.Background(), "", 5, "en", "", now); err != nil || len(f.feeds) != 2 || f.feeds[1].FallbackLimit != nil {
		t.Fatal(f.feeds, err)
	}
	viewer := "did:example:viewer"
	store.Moderation.Store(viewer, ModerationSnapshot{FetchedAt: now})
	f.feeds = nil
	if _, err = store.Feed(context.Background(), "", 5, "en", viewer, now); !errors.Is(err, ErrUnavailable) || len(f.feeds) != 1 {
		t.Fatal(f.feeds, err)
	}
	region := "outside-us"
	if _, err = store.Edition(context.Background(), "en", &region, "", now); err != nil || len(f.editions) != 2 || f.editions[1].Region != nil || f.editions[1].FallbackLimit != nil {
		t.Fatal(f.editions, err)
	}
	f.editions = nil
	if _, err = store.Edition(context.Background(), "en", nil, viewer, now); !errors.Is(err, ErrUnavailable) || len(f.editions) != 1 {
		t.Fatal(f.editions, err)
	}
	f.editions = nil
	if _, err = store.Edition(context.Background(), "en", &region, viewer, now); !errors.Is(err, ErrUnavailable) || len(f.editions) != 2 || f.editions[1].FallbackLimit == nil {
		t.Fatal(f.editions, err)
	}
}
