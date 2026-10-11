package podcasts

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

func TestPodcastSubscriptionClassification(t *testing.T) {
	native := "at://did:plc:publisher/place.pod.show/show"
	for _, test := range []struct {
		name   string
		values map[string]any
		want   bool
	}{
		{"News RSS", map[string]any{"feedUrl": "https://publisher.example/feed"}, false},
		{"Categorized News RSS", map[string]any{"feedUrl": "https://publisher.example/feed", "category": "news"}, false},
		{"Podcast RSS", map[string]any{"feedUrl": "https://publisher.example/feed", "category": "podcast"}, true},
		{"Normalized Podcast Category", map[string]any{"category": " Podcast "}, true},
		{"Legacy Native Podcast", map[string]any{"sourceType": "atproto.collection", "externalRef": native}, true},
		{"Native Podcast With RSS", map[string]any{"sourceType": "atproto.collection", "externalRef": native, "feedUrl": "https://publisher.example/feed"}, true},
		{"News RSS With Native Reference", map[string]any{"sourceType": "rss", "externalRef": native, "feedUrl": "https://publisher.example/feed"}, false},
		{"Explicit News Category", map[string]any{"category": "news", "sourceType": "atproto.collection", "externalRef": native}, false},
		{"Native Publication", map[string]any{"sourceType": "atproto.collection", "externalRef": "at://did:plc:publisher/site.standard.publication/news"}, false},
		{"Malformed Native Reference", map[string]any{"sourceType": "atproto.collection", "externalRef": "at://did:plc:publisher/place.pod.show"}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := isPodcastSubscription(test.values); got != test.want {
				t.Fatalf("classification = %v, want %v", got, test.want)
			}
		})
	}
}

type subscriptionRepository struct {
	fakeRepository
	page gatewaycore.RepoPage
}

func (r *subscriptionRepository) ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error) {
	return r.page, nil
}

func TestHydrateRemovesNewsFromPodcastLibrary(t *testing.T) {
	service, viewer, repo := fixtureService(t)
	ctx := context.Background()
	newsFeed, podcastFeed := "https://publisher.example/news", "https://publisher.example/podcast"
	nativeURI := "at://did:plc:publisher/place.pod.show/legacy"
	shows := []podcastcore.Show{
		{ID: viewer + "-news", Title: "News With Audio", SourceKind: "rss", FeedURL: &newsFeed},
		{ID: viewer + "-podcast", Title: "Podcast", SourceKind: "rss", FeedURL: &podcastFeed},
		{ID: viewer + "-native", Title: "Legacy Native Podcast", SourceKind: "atproto", SourceURI: &nativeURI},
	}
	old := []podcastcore.Subscription{}
	for _, show := range shows {
		if err := service.Store.Upsert(ctx, show, nil); err != nil {
			t.Fatal(err)
		}
		old = append(old, podcastcore.Subscription{ShowID: show.ID, URI: "at://old"})
	}
	if err := service.Store.Subscriptions(ctx, viewer, old); err != nil {
		t.Fatal(err)
	}
	values := []map[string]any{
		{"feedUrl": newsFeed},
		{"feedUrl": podcastFeed, "category": "podcast"},
		{"sourceType": "atproto.collection", "externalRef": nativeURI},
	}
	page := gatewaycore.RepoPage{}
	for i, value := range values {
		raw := map[string]json.RawMessage{}
		for key, item := range value {
			raw[key], _ = json.Marshal(item)
		}
		page.Records = append(page.Records, gatewaycore.RepoRecord{URI: "at://" + viewer + "/app.skyreader.feed.subscription/" + shows[i].ID, Value: raw})
	}
	service.Repo = &subscriptionRepository{fakeRepository: *repo, page: page}
	got, err := service.Hydrate(ctx, gatewaycore.AuthContext{DID: viewer})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("library contains %d shows, want podcast and native only: %+v", len(got), got)
	}
	for _, show := range got {
		if show.ID == shows[0].ID {
			t.Fatal("cached News subscription survived authoritative hydration")
		}
	}
	stored, err := service.Store.Shows(ctx, viewer)
	if err != nil || len(stored) != 2 {
		t.Fatalf("derived subscription projection was not reconciled: %+v, %v", stored, err)
	}
}
