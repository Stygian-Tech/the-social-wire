package topicreadcore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"testing"
	"time"
)

type circleCorpusFixture struct {
	corpuscore.Store
	page corpuscore.CandidateResponse
}

func (c circleCorpusFixture) CircleCandidates(context.Context, corpuscore.CandidateRequest, time.Time) (corpuscore.CandidateResponse, error) {
	return c.page, nil
}

type circleProfilesFixture struct{}

func (circleProfilesFixture) Profiles(_ context.Context, dids []string) (map[string]CircleIdentity, error) {
	result := map[string]CircleIdentity{}
	for _, did := range dids {
		result[did] = CircleIdentity{DID: did, Handle: did + ".example"}
	}
	return result, nil
}
func TestCircleEditionCanonicalDatabaseHidesAndAttribution(t *testing.T) {
	db := selectionDB(t)
	ctx := context.Background()
	now := time.Now().UTC()
	viewer := "did:example:circle-edition"
	hasher, err := wirecore.NewActorHasher([]byte("01234567890123456789012345678901"))
	if err != nil {
		t.Fatal(err)
	}
	cache := circleCacheFixture(t)
	state := &CirclePrivateState{DB: db, Hasher: hasher, Cache: cache}
	t.Cleanup(func() { state.Purge(ctx, viewer) })
	complete := true
	graph := CircleGraph{SnapshotID: "11111111-1111-1111-1111-111111111111", ViewerDID: viewer, DirectMembers: []CircleMember{{ActorDID: "did:example:friend", Depth: 1, PathCount: 1}}, OneHopMembers: []CircleMember{{ActorDID: "did:example:indirect", Depth: 2, PathCount: 2}}, OneHopExpansionComplete: &complete, GeneratedAt: now}
	if err = state.StoreGraph(ctx, graph, map[string]bool{viewer: true}, now); err != nil {
		t.Fatal(err)
	}
	friend, _ := hasher.Hash("did:example:friend")
	indirect, _ := hasher.Hash("did:example:indirect")
	stories := []corpuscore.CandidateStory{{Item: topicItem("a"), TopicKeys: []string{}, Facts: []corpuscore.SignalFact{{ActorHash: friend, Kind: "share", SourceURI: "at://friend/share/a", OccurredAt: now.Add(-time.Minute)}, {ActorHash: friend, Kind: "reply", SourceURI: "at://friend/reply/a", OccurredAt: now}, {ActorHash: indirect, Kind: "recommendation", SourceURI: "at://indirect/recommendation/a", OccurredAt: now}}}, {Item: topicItem("hidden"), TopicKeys: []string{}, Facts: []corpuscore.SignalFact{{ActorHash: friend, Kind: "share", SourceURI: "at://friend/share/b", OccurredAt: now}}}}
	if _, err = state.SetHidden(ctx, viewer, " hidden ", true, now); err != nil {
		t.Fatal(err)
	}
	moderation := NewModerationService(nil, nil)
	moderation.Cache.Store(viewer, ModerationSnapshot{FetchedAt: now})
	cursor, _ := wirecore.NewCircleCursorCodec([]byte("01234567890123456789012345678901"))
	service := CircleService{Corpus: circleCorpusFixture{page: corpuscore.CandidateResponse{GenerationID: "generation", GeneratedAt: now, Language: "en", Stories: stories}}, State: state, Hasher: hasher, Cursor: cursor, Moderation: moderation, Profiles: circleProfilesFixture{}}
	auth := gatewaycore.AuthContext{DID: viewer}
	if _, err = service.Edition(ctx, auth, "", "en", "", now); !errors.Is(err, ErrModerationUnavailable) {
		t.Fatal(err)
	}
	edition, err := service.Edition(ctx, auth, "0,1,2,3,4,5", "en", "", now)
	if err != nil {
		t.Fatal(err)
	}
	if len(edition.Stories) != 1 || edition.Stories[0].StoryID != "a" || edition.Stories[0].DiscussionCount != 1 || edition.Stories[0].SharerCount != 2 || len(edition.Stories[0].Sharers) != 2 || edition.Stories[0].Sharers[0].Relationship != "direct" {
		t.Fatal(edition)
	}
	if edition.Stories[0].Sharers[0].SourceURI != "at://friend/share/a" {
		t.Fatal("reply became named attribution", edition.Stories[0])
	}
	if _, err = state.SetHidden(ctx, viewer, "a", true, now); err != nil {
		t.Fatal(err)
	}
	edition, err = service.Edition(ctx, auth, "0,1,2,3,4,5", "en", "", now)
	if err != nil || len(edition.Stories) != 0 {
		t.Fatal(edition, err)
	}
}
