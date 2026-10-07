package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"math"
	"sort"
	"strings"
	"time"
)

type CircleCache struct {
	Client    *socialwireredis.CacheClient
	Namespace socialwireredis.KeyNamespace
}

func NewCircleCache(commands socialwireredis.Commands, environment string) *CircleCache {
	return &CircleCache{socialwireredis.NewCacheClient(commands), socialwireredis.NewKeyNamespace(environment, "")}
}

type cacheMember struct {
	ActorDID         string   `json:"actorDID"`
	Depth            int      `json:"depth"`
	PathCount        int      `json:"pathCount"`
	RecentActivityAt *float64 `json:"recentActivityAt,omitempty"`
}
type cacheGraph struct {
	SnapshotID              string        `json:"snapshotID"`
	ViewerDID               string        `json:"viewerDID"`
	DirectMembers           []cacheMember `json:"directMembers"`
	OneHopMembers           []cacheMember `json:"oneHopMembers"`
	DirectCandidateCount    int           `json:"directCandidateCount"`
	OneHopCandidateCount    int           `json:"oneHopCandidateCount"`
	OneHopExpansionComplete *bool         `json:"oneHopExpansionComplete,omitempty"`
	GeneratedAt             float64       `json:"generatedAt"`
}
type graphEntry struct {
	Exclusions []string   `json:"exclusions"`
	Snapshot   cacheGraph `json:"snapshot"`
}
type editionEntry struct {
	SnapshotID     string   `json:"snapshotID"`
	GenerationID   string   `json:"generationID"`
	Language       string   `json:"language"`
	HiddenStoryIDs []string `json:"hiddenStoryIDs"`
	Payload        []byte   `json:"payload"`
}

func keys(set map[string]bool) []string {
	result := []string{}
	for key, value := range set {
		if value {
			result = append(result, key)
		}
	}
	sort.Strings(result)
	return result
}
func equalKeys(list []string, set map[string]bool) bool {
	observed := map[string]bool{}
	for _, value := range list {
		observed[value] = true
	}
	expected := keys(set)
	if len(observed) != len(expected) {
		return false
	}
	for _, key := range expected {
		if !observed[key] {
			return false
		}
	}
	return true
}
func millis(at time.Time) float64 { return float64(at.Unix())*1000 + float64(at.Nanosecond())/1e6 }
func fromMillis(value float64) time.Time {
	seconds := math.Floor(value / 1000)
	return time.Unix(int64(seconds), int64(math.Round((value-seconds*1000)*1e6))).UTC()
}
func (c *CircleCache) key(domain, viewer string) string {
	return c.Namespace.Key(domain, nil, []string{viewer})
}
func (c *CircleCache) LoadGraph(ctx context.Context, viewer string, excluded map[string]bool, now time.Time) (*CircleGraph, error) {
	lookup, err := socialwireredis.LookupValue[graphEntry](ctx, c.Client, c.key("circle-graph", viewer), now)
	if err != nil || lookup.Envelope == nil {
		return nil, err
	}
	e := lookup.Envelope.Value
	if !equalKeys(e.Exclusions, excluded) || e.Snapshot.ViewerDID != viewer || !validUUID(e.Snapshot.SnapshotID) || math.IsNaN(e.Snapshot.GeneratedAt) || math.IsInf(e.Snapshot.GeneratedAt, 0) {
		return nil, nil
	}
	g := e.Snapshot
	decode := func(rows []cacheMember) []CircleMember {
		result := []CircleMember{}
		for _, row := range rows {
			m := CircleMember{ActorDID: row.ActorDID, Depth: row.Depth, PathCount: row.PathCount}
			if row.RecentActivityAt != nil {
				at := fromMillis(*row.RecentActivityAt)
				m.RecentActivityAt = &at
			}
			result = append(result, m)
		}
		return result
	}
	return &CircleGraph{g.SnapshotID, g.ViewerDID, decode(g.DirectMembers), decode(g.OneHopMembers), g.DirectCandidateCount, g.OneHopCandidateCount, g.OneHopExpansionComplete, fromMillis(g.GeneratedAt)}, nil
}
func (c *CircleCache) StoreGraph(ctx context.Context, g CircleGraph, excluded map[string]bool, now time.Time) error {
	remaining := g.GeneratedAt.Add(24 * time.Hour).Sub(now)
	if remaining <= 0 {
		return nil
	}
	encode := func(rows []CircleMember) []cacheMember {
		result := []cacheMember{}
		for _, row := range rows {
			m := cacheMember{ActorDID: row.ActorDID, Depth: row.Depth, PathCount: row.PathCount}
			if row.RecentActivityAt != nil {
				at := millis(*row.RecentActivityAt)
				m.RecentActivityAt = &at
			}
			result = append(result, m)
		}
		return result
	}
	value := graphEntry{keys(excluded), cacheGraph{strings.ToUpper(g.SnapshotID), g.ViewerDID, encode(g.DirectMembers), encode(g.OneHopMembers), g.DirectCandidateCount, g.OneHopCandidateCount, g.OneHopExpansionComplete, millis(g.GeneratedAt)}}
	return socialwireredis.StoreValue(ctx, c.Client, c.key("circle-graph", g.ViewerDID), value, socialwireredis.CachePolicy{FreshDuration: min(10*time.Minute, remaining), HardDuration: remaining}, now)
}
func (c *CircleCache) CachedEdition(ctx context.Context, viewer, snapshot, generation, language string, hidden map[string]bool, now time.Time) ([]byte, error) {
	lookup, err := socialwireredis.LookupValue[editionEntry](ctx, c.Client, c.key("circle-edition", viewer), now)
	if err != nil || lookup.Envelope == nil {
		return nil, err
	}
	value := lookup.Envelope.Value
	if !strings.EqualFold(value.SnapshotID, snapshot) || value.GenerationID != generation || value.Language != language || !equalKeys(value.HiddenStoryIDs, hidden) {
		return nil, nil
	}
	return value.Payload, nil
}
func (c *CircleCache) StoreEdition(ctx context.Context, viewer, snapshot, generation, language string, hidden map[string]bool, expires time.Time, payload []byte, now time.Time) error {
	remaining := min(expires.Sub(now), 10*time.Minute)
	if remaining <= 0 {
		return nil
	}
	return socialwireredis.StoreValue(ctx, c.Client, c.key("circle-edition", viewer), editionEntry{strings.ToUpper(snapshot), generation, language, keys(hidden), payload}, socialwireredis.CachePolicy{FreshDuration: remaining, HardDuration: remaining}, now)
}
func (c *CircleCache) InvalidateEditions(ctx context.Context, viewer string) {
	_ = c.Client.Commands.Delete(ctx, []string{c.key("circle-edition", viewer)})
}
func (c *CircleCache) Purge(ctx context.Context, viewer string) error {
	return c.Client.Commands.Delete(ctx, []string{c.key("circle-graph", viewer), c.key("circle-edition", viewer)})
}
