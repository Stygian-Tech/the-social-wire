package corpuscore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestPayloadCacheSwiftDatesAndAuthoritativeFill(t *testing.T) {
	ctx := context.Background()
	now := time.Unix(1791324000, 123000000).UTC()
	cache := redisCache(t)
	calls := 0
	load := func(context.Context) (Page, error) {
		calls++
		return Page{GeneratedAt: now, Rows: []Row{{Item: wirecore.FeedItem{PublishedAt: &now, Title: "2026-10-07T00:00:00Z"}}}}, nil
	}
	revision := "r1"
	current := func(context.Context) (string, error) { return revision, nil }
	first, err := cachedValue(ctx, cache, []string{"feed", "test"}, revision, now, time.Minute, current, nil, load)
	if err != nil {
		t.Fatal(err)
	}
	data, err := encodePayload(first)
	if err != nil || !strings.Contains(string(data), `"generatedAt":1791324000123`) || !strings.Contains(string(data), `"title":"2026-10-07T00:00:00Z"`) {
		t.Fatalf("Swift date cache %s %v", data, err)
	}
	second, err := cachedValue(ctx, cache, []string{"feed", "test"}, revision, now, time.Minute, current, nil, load)
	if err != nil || calls != 1 || !second.GeneratedAt.Equal(now) || !second.Rows[0].Item.PublishedAt.Equal(now) {
		t.Fatalf("cache dates %v %d %v", second, calls, err)
	}
	changedLoad := func(ctx context.Context) (Page, error) { revision = "r2"; return load(ctx) }
	_, err = cachedValue(ctx, cache, []string{"item", "new"}, "r1", now, time.Minute, current, nil, changedLoad)
	if err != nil || cache.Statistics()["item_revision_changed"] != 1 {
		t.Fatal("changed authoritative fill", err, cache.Statistics())
	}
	cache.MaximumPayloadBytes = 1
	_, err = cachedValue(ctx, cache, []string{"item", "oversized"}, revision, now, time.Minute, current, nil, load)
	if err != nil || cache.Statistics()["item_oversized"] != 1 {
		t.Fatal("oversized fill", err)
	}
}
func TestPayloadCoalescingAndCancellation(t *testing.T) {
	cache := redisCache(t)
	ctx := context.Background()
	now := time.Now()
	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	load := func(context.Context) (string, error) {
		if calls.Add(1) == 1 {
			close(started)
		}
		<-release
		return "value", nil
	}
	current := func(context.Context) (string, error) { return "r", nil }
	var group sync.WaitGroup
	group.Add(1)
	go func() {
		defer group.Done()
		if _, err := cachedValue(ctx, cache, []string{"feed", "same"}, "r", now, time.Minute, current, nil, load); err != nil {
			t.Error(err)
		}
	}()
	<-started
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := cachedValue(cancelled, cache, []string{"feed", "same"}, "r", now, time.Minute, current, nil, load); !errors.Is(err, context.Canceled) {
		t.Fatal("waiting caller cancellation", err)
	}
	group.Add(1)
	go func() {
		defer group.Done()
		if value, err := cachedValue(ctx, cache, []string{"feed", "same"}, "r", now, time.Minute, current, nil, load); err != nil || value != "value" {
			t.Error(value, err)
		}
	}()
	for cache.Statistics()["feed_coalesced"] < 2 {
		time.Sleep(time.Millisecond)
	}
	close(release)
	group.Wait()
	if calls.Load() != 1 {
		t.Fatal("duplicate loads", calls.Load())
	}
}
func TestEditionProofMembershipAndJSONPrecision(t *testing.T) {
	revision := `["generation","rev",5]
["module","top","rev"]
["module","outside-us:top","rev"]
["item","top",0,"a","rev"]
["item","outside-us:top",0,"b","rev"]
["account",0,"did:example:a","rev"]
["continuation",true]`
	region := "outside-us"
	p := editionProof{ModulePrefix: "outside-us:", ModuleKeys: []string{"outside-us:top"}, Stories: [][]string{{"outside-us:top", "b"}}, Accounts: []string{"did:example:a"}, HasMore: true}
	if !p.matches(revision, &region) || p.matches(revision, nil) {
		t.Fatal("regional proof")
	}
	p.Stories = [][]string{{"outside-us:top", "a"}}
	if p.matches(revision, &region) {
		t.Fatal("wrong membership accepted")
	}
	at := time.Date(2026, 10, 7, 1, 2, 3, 987654000, time.UTC)
	edition := Edition{Edition: wirecore.AssembleEdition("test", at, "en", nil, "ranked", false, nil, nil), SourceActorKeysByItemID: map[string]string{}, FallbackRows: []Row{}}
	data, err := MarshalHTTP(edition)
	if err != nil || !strings.Contains(string(data), `"generatedAt":"2026-10-07T01:02:03Z"`) || !strings.Contains(string(data), `"sourceActorKeysByItemID":{}`) || !strings.Contains(string(data), `"fallbackRows":[]`) {
		t.Fatalf("edition HTTP %s %v", data, err)
	}
	value := struct {
		At     time.Time `json:"at"`
		Number int64     `json:"number"`
		Score  float64   `json:"score"`
	}{at, 9007199254740993, 1e-12}
	data, _ = MarshalHTTP(value)
	if !strings.Contains(string(data), `9007199254740993`) || !strings.Contains(string(data), `1e-12`) {
		t.Fatal("number precision", string(data))
	}
	var event sportscore.Event
	if err := json.Unmarshal([]byte(`{"id":"a","startsAt":"2026-10-07T01:02:03Z","updatedAt":"2026-10-07T01:02:03Z"}`), &event); err != nil {
		t.Fatal(err)
	}
	data, _ = json.Marshal(event)
	if strings.Contains(string(data), "startTimeKnown") {
		t.Fatal("unknown start time converted into false", string(data))
	}
}
