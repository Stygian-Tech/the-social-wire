package podcastcore

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

func TestSearchBoundedScanPrivateRedactionAndCursorBinding(t *testing.T) {
	s, viewer := fixtureStore(t)
	ctx := context.Background()
	show := Show{ID: viewer + "-show", Title: "Publisher", SourceKind: "rss"}
	episodes := make([]Episode, 502)
	for i := range episodes {
		title := "Nothing here"
		if i == 501 {
			title = "Needle final"
		}
		episodes[i] = Episode{ID: viewer + fmt.Sprintf("-%04d", i), ShowID: show.ID, Title: title, PublishedAt: "2026-10-05T00:00:00Z", AudioURL: "https://example.invalid/secret-needle.mp3"}
	}
	if err := s.Upsert(ctx, show, episodes); err != nil {
		t.Fatal(err)
	}
	if err := s.Subscriptions(ctx, viewer, []Subscription{{show.ID, "at://subscription"}}); err != nil {
		t.Fatal(err)
	}
	request := SearchRequest{Query: "needle", Kind: pointer("episodes")}
	page, err := s.Search(ctx, viewer, request)
	if err != nil || len(page.Episodes) != 0 || !page.HasMore || page.Cursor == nil {
		t.Fatalf("first bounded scan %v %v", page, err)
	}
	request.Cursor = page.Cursor
	next, err := s.Search(ctx, viewer, request)
	if err != nil || next.HasMore || len(next.Episodes) != 1 || next.Episodes[0].Title != "Needle final" {
		t.Fatalf("search continuation %v %v", next, err)
	}
	if _, err := s.Search(ctx, viewer+"other", request); !errors.Is(err, ErrInvalidRequest) {
		t.Fatal("cross viewer cursor")
	}
	request.Query = "changed"
	if _, err := s.Search(ctx, viewer, request); !errors.Is(err, ErrInvalidRequest) {
		t.Fatal("changed query cursor")
	}
	secret := "https://example.invalid/feed?token=private-secret"
	private, privateEpisodes := ScopePrivate(viewer, secret, Show{Title: "Private", SourceKind: "rss"}, []Episode{{ID: "one", Title: "Private episode", Description: &secret, AudioURL: secret, PublishedAt: "2026-10-05T00:00:00Z"}})
	if err := s.SavePrivateCatalog(ctx, viewer, secret, private, privateEpisodes, false); err != nil {
		t.Fatal(err)
	}
	hidden, err := s.Search(ctx, viewer, SearchRequest{Query: "private-secret"})
	if err != nil || len(hidden.Shows)+len(hidden.Episodes) != 0 {
		t.Fatal("private token searched", hidden, err)
	}
	privateRequest := SearchRequest{Query: "private episode", ShowID: &private.ID}
	visible, err := s.Search(ctx, viewer, privateRequest)
	if err != nil || len(visible.Episodes) != 1 || visible.Episodes[0].AudioURL == secret {
		t.Fatal("private search visibility", visible, err)
	}
}
