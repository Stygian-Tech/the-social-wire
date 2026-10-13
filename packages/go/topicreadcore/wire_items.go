package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"time"
)

func (s *WireStore) Items(ctx context.Context, ids []string, viewer string, now time.Time) (map[string]*wirecore.FeedItem, error) {
	if !s.serves() {
		return nil, ErrUnavailable
	}
	snapshot, err := s.moderation(viewer, now)
	if err != nil {
		return nil, err
	}
	items, err := corpuscore.LoadItems(ctx, s.Corpus, ids, now)
	if err != nil {
		return nil, corpusError(err)
	}
	result := map[string]*wirecore.FeedItem{}
	for _, item := range items {
		if allows(snapshot, item.SourceActorKey, item.Item) {
			value := item.Item
			result[value.ItemID] = &value
		}
	}
	return result, nil
}
