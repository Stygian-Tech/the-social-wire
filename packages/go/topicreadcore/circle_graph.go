package topicreadcore

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"hash/fnv"
	"sort"
	"strings"
	"time"
)

type CircleMember struct {
	ActorDID         string     `json:"actorDID"`
	Depth            int        `json:"depth"`
	PathCount        int        `json:"pathCount"`
	RecentActivityAt *time.Time `json:"recentActivityAt,omitempty"`
}
type CircleGraph struct {
	SnapshotID              string         `json:"snapshotID"`
	ViewerDID               string         `json:"viewerDID"`
	DirectMembers           []CircleMember `json:"directMembers"`
	OneHopMembers           []CircleMember `json:"oneHopMembers"`
	DirectCandidateCount    int            `json:"directCandidateCount"`
	OneHopCandidateCount    int            `json:"oneHopCandidateCount"`
	OneHopExpansionComplete *bool          `json:"oneHopExpansionComplete,omitempty"`
	GeneratedAt             time.Time      `json:"generatedAt"`
}
type FollowList struct {
	ActorDID     string
	FolloweeDIDs []string
	Complete     bool
}
type CircleViewerFollows interface {
	ViewerFollows(context.Context, string) (FollowList, error)
}
type CirclePublicFollows interface {
	PublicFollows(context.Context, []string) ([]FollowList, error)
}
type CircleActivity interface {
	RecentActivity(context.Context, []string, time.Time) (map[string]time.Time, error)
}
type CircleGraphCache interface {
	LoadGraph(context.Context, string, map[string]bool, time.Time) (*CircleGraph, error)
	StoreGraph(context.Context, CircleGraph, map[string]bool, time.Time) error
}
type CircleGraphService struct {
	Viewer                                   CircleViewerFollows
	Public                                   CirclePublicFollows
	Activity                                 CircleActivity
	Cache                                    CircleGraphCache
	DirectLimit, OneHopLimit, ExpansionLimit int
	NewID                                    func() string
}
type CircleGraphResult struct {
	Graph CircleGraph
	Stale bool
}

func (r CircleGraphResult) Degraded() bool {
	return r.Stale || (r.Graph.OneHopExpansionComplete != nil && !*r.Graph.OneHopExpansionComplete)
}
func normalizedDID(did string) string { return strings.ToLower(strings.TrimSpace(did)) }
func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	h := hex.EncodeToString(b[:])
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}
func (s *CircleGraphService) Snapshot(ctx context.Context, viewer string, excluded map[string]bool, now time.Time) (CircleGraphResult, error) {
	viewer = normalizedDID(viewer)
	if viewer == "" {
		return CircleGraphResult{}, ErrInvalidCursor
	}
	exclusions := map[string]bool{viewer: true}
	for did := range excluded {
		if key := normalizedDID(did); key != "" {
			exclusions[key] = true
		}
	}
	var cached *CircleGraph
	if s.Cache != nil {
		cached, _ = s.Cache.LoadGraph(ctx, viewer, exclusions, now)
	}
	if cached != nil && cached.ViewerDID != viewer {
		cached = nil
	}
	if cached != nil && max(time.Duration(0), now.Sub(cached.GeneratedAt)) <= 10*time.Minute {
		return CircleGraphResult{Graph: *cached}, nil
	}
	graph, err := s.build(ctx, viewer, exclusions, now)
	if err == nil {
		if s.Cache != nil {
			_ = s.Cache.StoreGraph(ctx, graph, exclusions, now)
		}
		return CircleGraphResult{Graph: graph}, nil
	}
	if cached != nil && max(time.Duration(0), now.Sub(cached.GeneratedAt)) <= 24*time.Hour {
		return CircleGraphResult{*cached, true}, nil
	}
	return CircleGraphResult{}, err
}
func (s *CircleGraphService) build(ctx context.Context, viewer string, exclusions map[string]bool, now time.Time) (CircleGraph, error) {
	if s.Viewer == nil || s.Public == nil || s.Activity == nil {
		return CircleGraph{}, ErrUnavailable
	}
	root, err := s.Viewer.ViewerFollows(ctx, viewer)
	if err != nil {
		return CircleGraph{}, err
	}
	if normalizedDID(root.ActorDID) != viewer || !root.Complete {
		return CircleGraph{}, ErrUnavailable
	}
	normalized := func(dids []string, exclude map[string]bool) []string {
		seen := map[string]bool{}
		out := []string{}
		for _, did := range dids {
			did = normalizedDID(did)
			if did != "" && !exclude[did] && !seen[did] {
				seen[did] = true
				out = append(out, did)
			}
		}
		return out
	}
	direct := normalized(root.FolloweeDIDs, exclusions)
	activity, err := s.Activity.RecentActivity(ctx, direct, now)
	if err != nil {
		return CircleGraph{}, err
	}
	orderActivity := func(a, b string, activity map[string]time.Time) bool {
		ad, bd := activity[a], activity[b]
		if !ad.Equal(bd) {
			return ad.After(bd)
		}
		hash := func(v string) uint64 { h := fnv.New64a(); _, _ = h.Write([]byte(v)); return h.Sum64() }
		ah, bh := hash(a), hash(b)
		if ah != bh {
			return ah < bh
		}
		return a < b
	}
	sort.Slice(direct, func(i, j int) bool { return orderActivity(direct[i], direct[j], activity) })
	dl := s.DirectLimit
	if dl == 0 {
		dl = 500
	}
	dl = max(1, min(dl, 500))
	ol := s.OneHopLimit
	if ol == 0 {
		ol = 20000
	}
	ol = max(1, min(ol, 20000))
	el := s.ExpansionLimit
	if el == 0 {
		el = 16
	}
	el = max(1, min(el, 16))
	selected := direct[:min(len(direct), dl)]
	sources := selected[:min(len(selected), el)]
	reads, readErr := s.Public.PublicFollows(ctx, sources)
	byActor := map[string]FollowList{}
	invalid := map[string]bool{}
	wanted := map[string]bool{}
	for _, did := range sources {
		wanted[did] = true
	}
	complete := readErr == nil
	if readErr != nil {
		reads = nil
	}
	for _, read := range reads {
		actor := normalizedDID(read.ActorDID)
		if !wanted[actor] || actor == "" {
			complete = false
			continue
		}
		if _, exists := byActor[actor]; exists || invalid[actor] {
			delete(byActor, actor)
			invalid[actor] = true
			complete = false
			continue
		}
		if !read.Complete {
			complete = false
		}
		if !read.Complete && len(read.FolloweeDIDs) == 0 {
			invalid[actor] = true
			continue
		}
		byActor[actor] = read
	}
	for _, did := range sources {
		if _, ok := byActor[did]; !ok {
			complete = false
		}
	}
	complete = complete && len(sources) == len(selected)
	oneExclusions := map[string]bool{}
	for did := range exclusions {
		oneExclusions[did] = true
	}
	for _, did := range selected {
		oneExclusions[did] = true
	}
	paths := map[string]map[string]bool{}
	for source, read := range byActor {
		for _, did := range normalized(read.FolloweeDIDs, oneExclusions) {
			if paths[did] == nil {
				paths[did] = map[string]bool{}
			}
			paths[did][source] = true
		}
	}
	one := []string{}
	for did := range paths {
		one = append(one, did)
	}
	oneActivity, err := s.Activity.RecentActivity(ctx, one, now)
	if err != nil {
		return CircleGraph{}, err
	}
	sort.Slice(one, func(i, j int) bool {
		a, b := one[i], one[j]
		if len(paths[a]) != len(paths[b]) {
			return len(paths[a]) > len(paths[b])
		}
		return orderActivity(a, b, oneActivity)
	})
	id := newID()
	if s.NewID != nil {
		id = s.NewID()
	}
	graph := CircleGraph{SnapshotID: id, ViewerDID: viewer, DirectMembers: []CircleMember{}, OneHopMembers: []CircleMember{}, DirectCandidateCount: len(direct), OneHopCandidateCount: len(one), OneHopExpansionComplete: &complete, GeneratedAt: now}
	member := func(did string, depth int, count int, activity map[string]time.Time) CircleMember {
		m := CircleMember{ActorDID: did, Depth: depth, PathCount: count}
		if at, ok := activity[did]; ok {
			m.RecentActivityAt = &at
		}
		return m
	}
	for _, did := range selected {
		graph.DirectMembers = append(graph.DirectMembers, member(did, 1, 1, activity))
	}
	for _, did := range one[:min(len(one), ol)] {
		graph.OneHopMembers = append(graph.OneHopMembers, member(did, 2, len(paths[did]), oneActivity))
	}
	return graph, nil
}
