package topicreadcore

import (
	"strings"
	"sync"
	"time"
)

type ModerationSnapshot struct {
	BlockedDIDs, MutedDIDs map[string]bool
	MutedWords             []string
	InterestTags           map[string]bool
	FetchedAt              time.Time
}

func (s ModerationSnapshot) Allows(item, title string, summary, representativeURI *string) bool {
	did := ""
	if strings.HasPrefix(item, "did:") {
		did = item
	} else if representativeURI != nil && strings.HasPrefix(*representativeURI, "at://") {
		did = strings.Split(strings.TrimPrefix(*representativeURI, "at://"), "/")[0]
	}
	if s.BlockedDIDs[did] || s.MutedDIDs[did] {
		return false
	}
	text := title + " "
	if summary != nil {
		text += *summary
	}
	text = strings.ToLower(text)
	for _, word := range s.MutedWords {
		if strings.Contains(text, word) {
			return false
		}
	}
	return true
}

type ModerationCache struct {
	mu        sync.Mutex
	snapshots map[string]ModerationSnapshot
}

func (c *ModerationCache) lookup(viewer string, at time.Time, age time.Duration) *ModerationSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	value, ok := c.snapshots[viewer]
	if !ok || at.Sub(value.FetchedAt) > age {
		return nil
	}
	return &value
}
func (c *ModerationCache) Fresh(viewer string, at time.Time) *ModerationSnapshot {
	return c.lookup(viewer, at, 5*time.Minute)
}
func (c *ModerationCache) Usable(viewer string, at time.Time) *ModerationSnapshot {
	return c.lookup(viewer, at, 30*time.Minute)
}
func (c *ModerationCache) Store(viewer string, value ModerationSnapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.snapshots == nil {
		c.snapshots = map[string]ModerationSnapshot{}
	}
	c.snapshots[viewer] = value
}
