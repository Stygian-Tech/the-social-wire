package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"testing"
	"time"
)

type batchedWireFixture struct {
	*corpusFixture
	calls int
}

func (f *batchedWireFixture) Items(_ context.Context, _ []string, _ time.Time) ([]corpuscore.Item, error) {
	f.calls++
	blocked := "did:example:blocked"
	allowed := "did:example:allowed"
	return []corpuscore.Item{{Item: topicItem("second"), SourceActorKey: &allowed}, {Item: topicItem("first"), SourceActorKey: &blocked}}, nil
}
func TestWireBatchModerationAndMissingItems(t *testing.T) {
	now := time.Now()
	fixture := &batchedWireFixture{corpusFixture: &corpusFixture{}}
	store, err := NewWireStore(fixture, "01234567890123456789012345678901", "visible", &ModerationCache{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.Items(context.Background(), []string{"first", "second", "missing"}, "viewer", now); err != ErrModerationUnavailable || fixture.calls != 0 {
		t.Fatal(err, fixture.calls)
	}
	store.Moderation.Store("viewer", ModerationSnapshot{BlockedDIDs: map[string]bool{"did:example:blocked": true}, FetchedAt: now})
	items, err := store.Items(context.Background(), []string{"first", "second", "missing"}, "viewer", now)
	if err != nil || fixture.calls != 1 || len(items) != 1 || items["second"] == nil || items["first"] != nil || items["missing"] != nil {
		t.Fatal(items, err, fixture.calls)
	}
}
