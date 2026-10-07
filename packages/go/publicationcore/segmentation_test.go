package publicationcore

import (
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"strings"
	"testing"
	"time"
)

func TestPublicationIdentityRetainsRecordKeyAndMatchesEncodedAuthorities(t *testing.T) {
	a := "at://did:plc:viewer/site.standard.publication/key%2Fone"
	b := "at://did%3Aplc%3Aviewer/site.standard.publication/key%2Fone"
	if !IDsMatch(a, b) || NormalizeATRepoParam(b) != a {
		t.Fatal(LookupKeys(b))
	}
	if IDsMatch(a, "at://did:plc:viewer/site.standard.publication/key/one") {
		t.Fatal("record key decoded as path")
	}
	if !IDsMatch("@did:plc:viewer", "did:plc:viewer") {
		t.Fatal("DID normalization")
	}
}
func TestSegmentationKeepsOwnUnaddressableRowsOutOfSubscriptions(t *testing.T) {
	uri := "at://did:plc:viewer/site.standard.publication/self"
	own := DiscoveredRow{PublicationID: uri, SubscriptionPublicationID: &uri, AuthorDID: "did:plc:viewer"}
	pseudo := DiscoveredRow{PublicationID: "did:plc:viewer", AuthorDID: "did:plc:viewer"}
	subscribed, following := Segment([]DiscoveredRow{own, pseudo}, "did:plc:viewer", nil)
	if len(subscribed) != 1 || subscribed[0].PublicationID != uri || len(following) != 1 {
		t.Fatal(subscribed, following)
	}
}
func TestHiddenPreferenceLatestURIFencesOnlyMatchingPublication(t *testing.T) {
	rows := []DiscoveredRow{{PublicationID: "at://did:plc:a/site.standard.publication/one"}, {PublicationID: "at://did:plc:a/site.standard.publication/two"}}
	prefs := []PreferenceRecord{{URI: "at://did:plc:v/app.thesocialwire.publicationPrefs/a", PublicationID: rows[0].PublicationID, Value: map[string]any{"hidden": false}}, {URI: "at://did:plc:v/app.thesocialwire.publicationPrefs/z", PublicationID: rows[0].PublicationID, Value: map[string]any{"hidden": true}}}
	visible := FilterHidden(rows, prefs)
	if len(visible) != 1 || visible[0].PublicationID != rows[1].PublicationID {
		t.Fatal(visible)
	}
}
func TestPodcastSubscriptionsNeverEnterArticleSidebar(t *testing.T) {
	records := []gatewaycore.RepoRecord{}
	for _, category := range []string{"podcast", " Podcast ", "article"} {
		raw, _ := json.Marshal(category)
		records = append(records, gatewaycore.RepoRecord{URI: "at://did:plc:a/app.skyreader.feed.subscription/" + category, Value: map[string]json.RawMessage{"category": raw, "feedUrl": json.RawMessage(`"https://publisher.valid/rss.xml"`), "customTitle": json.RawMessage(`"Publication"`)}})
	}
	rows := RSSRows(records, time.Now())
	if len(rows) != 1 || rows[0].Title != "Publication" || !strings.HasPrefix(rows[0].PublicationID, "rss:") {
		t.Fatal(rows)
	}
}
