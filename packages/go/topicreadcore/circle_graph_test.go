package topicreadcore

import (
	"context"
	"errors"
	"testing"
	"time"
)

type graphFixture struct {
	root     FollowList
	public   []FollowList
	activity map[string]time.Time
	cached   *CircleGraph
	err      error
	stored   bool
}

func (f *graphFixture) ViewerFollows(context.Context, string) (FollowList, error) {
	return f.root, f.err
}
func (f *graphFixture) PublicFollows(context.Context, []string) ([]FollowList, error) {
	return f.public, nil
}
func (f *graphFixture) RecentActivity(context.Context, []string, time.Time) (map[string]time.Time, error) {
	return f.activity, nil
}
func (f *graphFixture) LoadGraph(context.Context, string, map[string]bool, time.Time) (*CircleGraph, error) {
	return f.cached, nil
}
func (f *graphFixture) StoreGraph(_ context.Context, g CircleGraph, _ map[string]bool, _ time.Time) error {
	f.stored = true
	f.cached = &g
	return nil
}
func TestCircleGraphCappedDirectPathsAndCoverage(t *testing.T) {
	now := time.Now()
	f := &graphFixture{root: FollowList{ActorDID: "did:example:viewer", FolloweeDIDs: []string{"did:example:a", "did:example:b", "did:example:c", "did:example:excluded"}, Complete: true}, activity: map[string]time.Time{"did:example:a": now, "did:example:b": now.Add(-time.Minute), "did:example:c": now.Add(-time.Hour)}, public: []FollowList{{ActorDID: "did:example:a", FolloweeDIDs: []string{"did:example:shared", "did:example:c", "did:example:excluded"}, Complete: true}, {ActorDID: "did:example:b", FolloweeDIDs: []string{"did:example:shared"}, Complete: true}}}
	s := &CircleGraphService{Viewer: f, Public: f, Activity: f, Cache: f, DirectLimit: 2, ExpansionLimit: 2}
	r, e := s.Snapshot(context.Background(), " DID:EXAMPLE:VIEWER ", map[string]bool{"did:example:excluded": true}, now)
	if e != nil {
		t.Fatal(e)
	}
	if r.Degraded() || r.Graph.DirectCandidateCount != 3 || len(r.Graph.DirectMembers) != 2 || r.Graph.OneHopCandidateCount != 2 || r.Graph.OneHopMembers[0].ActorDID != "did:example:shared" || r.Graph.OneHopMembers[0].PathCount != 2 || !f.stored {
		t.Fatal(r)
	}
	if r.Graph.OneHopMembers[1].ActorDID != "did:example:c" {
		t.Fatal("capped follow should remain eligible one hop", r)
	}
}
func TestCircleGraphPartialDuplicateAndStaleFailClosed(t *testing.T) {
	now := time.Now()
	f := &graphFixture{root: FollowList{ActorDID: "viewer", FolloweeDIDs: []string{"a", "b"}, Complete: true}, public: []FollowList{{ActorDID: "a", FolloweeDIDs: []string{"one"}, Complete: false}, {ActorDID: "b", FolloweeDIDs: []string{"invalid"}, Complete: true}, {ActorDID: "b", FolloweeDIDs: []string{"other"}, Complete: true}}, activity: map[string]time.Time{}}
	s := &CircleGraphService{Viewer: f, Public: f, Activity: f, Cache: f}
	r, e := s.Snapshot(context.Background(), "viewer", nil, now)
	if e != nil || !r.Degraded() || len(r.Graph.OneHopMembers) != 1 || r.Graph.OneHopMembers[0].ActorDID != "one" {
		t.Fatal(r, e)
	}
	f.err = errors.New("private follow fetch failed")
	r, e = s.Snapshot(context.Background(), "viewer", nil, now.Add(time.Hour))
	if e != nil || !r.Stale {
		t.Fatal(r, e)
	}
	if _, e = s.Snapshot(context.Background(), "viewer", nil, now.Add(25*time.Hour)); e == nil {
		t.Fatal("expired graph accepted")
	}
	f.cached.ViewerDID = "other"
	if _, e = s.Snapshot(context.Background(), "viewer", nil, now); e == nil {
		t.Fatal("cross-viewer graph accepted")
	}
}
