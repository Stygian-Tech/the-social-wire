package topicreadcore

import (
	"context"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"sort"
	"strings"
	"time"
)

type CircleProfileReader interface {
	Profiles(context.Context, []string) (map[string]CircleIdentity, error)
}
type CircleService struct {
	Corpus     corpuscore.Store
	Wire       *WireStore
	Mode       string
	State      *CirclePrivateState
	Hasher     *wirecore.ActorHasher
	Cursor     *wirecore.CircleCursorCodec
	Moderation *ModerationService
	Public     CirclePublicFollows
	Activity   CircleActivity
	Profiles   CircleProfileReader
}
type circleMembership struct {
	DID, Relationship string
	Rank              wirecore.CircleRelationship
}

func (s *CircleService) Catalog(ctx context.Context, now time.Time) (CircleCatalog, error) {
	catalog, err := s.Wire.Catalog(ctx, now)
	if err != nil {
		return CircleCatalog{}, err
	}
	return CircleCatalog{s.Mode == "visible", catalog.Available, "Your Circle", "Stories shared and discussed by people you follow and the people they follow.", catalog.SupportedLanguages, catalog.LatestGenerationID, catalog.GeneratedAt}, nil
}

type CircleCatalog struct {
	Enabled            bool       `json:"enabled"`
	Available          bool       `json:"available"`
	Title              string     `json:"title"`
	Subtitle           string     `json:"subtitle"`
	SupportedLanguages []string   `json:"supportedLanguages"`
	LatestGenerationID *string    `json:"latestGenerationId,omitempty"`
	GeneratedAt        *time.Time `json:"generatedAt,omitempty"`
}

func (s *CircleService) Edition(ctx context.Context, auth gatewaycore.AuthContext, rawProofs, language, cursor string, now time.Time) (CircleEdition, error) {
	proofs, err := ExtractProofs(rawProofs, 6)
	if err != nil {
		return CircleEdition{}, err
	}
	snapshot, err := s.Moderation.RequireProofs(ctx, auth, proofs[:5], now)
	if err != nil {
		return CircleEdition{}, err
	}
	excluded := map[string]bool{}
	for did := range snapshot.BlockedDIDs {
		excluded[did] = true
	}
	for did := range snapshot.MutedDIDs {
		excluded[did] = true
	}
	reader := &CircleReader{Moderation: s.Moderation, Auth: auth, FollowProof: proofs[5]}
	graphService := CircleGraphService{Viewer: reader, Public: s.Public, Activity: s.Activity, Cache: s.State}
	graph, err := graphService.Snapshot(ctx, auth.DID, excluded, now)
	if err != nil {
		return CircleEdition{}, err
	}
	membership := map[string]circleMembership{}
	for _, member := range graph.Graph.DirectMembers {
		hash, err := s.Hasher.Hash(member.ActorDID)
		if err != nil {
			return CircleEdition{}, err
		}
		membership[hash] = circleMembership{member.ActorDID, "direct", wirecore.CircleRelationship{Direct: true, PathCount: 1}}
	}
	for _, member := range graph.Graph.OneHopMembers {
		hash, err := s.Hasher.Hash(member.ActorDID)
		if err != nil {
			return CircleEdition{}, err
		}
		membership[hash] = circleMembership{member.ActorDID, "one_hop", wirecore.CircleRelationship{PathCount: member.PathCount}}
	}
	hashes := []string{}
	for hash := range membership {
		hashes = append(hashes, hash)
	}
	sort.Strings(hashes)
	hidden, err := s.State.Hidden(ctx, auth.DID)
	if err != nil {
		return CircleEdition{}, err
	}
	candidates := corpuscore.CandidateResponse{GenerationID: fmt.Sprintf("circle-empty-%d", now.Unix()/300), GeneratedAt: now, Language: language, Stories: []corpuscore.CandidateStory{}, Exhausted: true}
	if len(hashes) > 0 {
		candidates, err = circleCandidates(ctx, s.Corpus, hashes, language, now.Add(-7*24*time.Hour), 500, now)
		if err != nil {
			return CircleEdition{}, corpusError(err)
		}
	}
	ordinal := 0
	if cursor != "" {
		value, err := s.Cursor.Decode(cursor, auth.DID, now)
		if errors.Is(err, wirecore.ErrCursorExpired) {
			return CircleEdition{}, ErrCursorExpired
		}
		if err != nil {
			return CircleEdition{}, ErrInvalidCursor
		}
		if value.SnapshotID != strings.ToLower(graph.Graph.SnapshotID) || value.GenerationID != candidates.GenerationID || value.Language != language {
			return CircleEdition{}, ErrCursorExpired
		}
		ordinal = value.NextOrdinal
	}
	if ordinal == 0 && s.State.Cache != nil {
		body, _ := s.State.Cache.CachedEdition(ctx, auth.DID, graph.Graph.SnapshotID, candidates.GenerationID, language, hidden, now)
		if body != nil {
			var response CircleEdition
			if corpuscore.DecodeContract(body, &response) == nil {
				return response, nil
			}
		}
	}
	byID := map[string]corpuscore.CandidateStory{}
	input := []wirecore.CircleRankCandidate{}
	for _, story := range candidates.Stories {
		if _, duplicate := byID[story.Item.ItemID]; duplicate {
			return CircleEdition{}, ErrUnavailable
		}
		byID[story.Item.ItemID] = story
		if hidden[story.Item.ItemID] {
			continue
		}
		signals := []wirecore.CircleParticipantSignal{}
		for _, fact := range story.Facts {
			if member, ok := membership[fact.ActorHash]; ok {
				signals = append(signals, wirecore.CircleParticipantSignal{ParticipantKey: fact.ActorHash, Relationship: member.Rank, OccurredAt: fact.OccurredAt})
			}
		}
		presentation := .4
		if story.Item.Summary != nil && *story.Item.Summary != "" {
			presentation += .3
		}
		if story.Item.ThumbnailURL != nil && *story.Item.ThumbnailURL != "" {
			presentation += .3
		}
		tags := map[string]bool{}
		for _, tag := range story.TopicKeys {
			tag = strings.ToLower(tag)
			if snapshot.InterestTags[tag] {
				tags[tag] = true
			}
		}
		input = append(input, wirecore.CircleRankCandidate{CanonicalKey: story.Item.ItemID, ParticipantSignals: signals, Quality: 1, Presentation: presentation, InterestMatch: min(1, float64(len(tags))/2)})
	}
	ranked, err := wirecore.RankCircle(input, now, wirecore.DefaultCircleRankingConfig())
	if err != nil {
		return CircleEdition{}, err
	}
	stories := []corpuscore.CandidateStory{}
	for _, item := range ranked.Items[min(ordinal, len(ranked.Items)):min(ordinal+50, len(ranked.Items))] {
		if story, ok := byID[item.Candidate.CanonicalKey]; ok {
			stories = append(stories, story)
		}
	}
	end := ordinal + len(stories)
	var more *string
	if end < len(ranked.Items) {
		expires := minTime(now.Add(24*time.Hour), graph.Graph.GeneratedAt.Add(24*time.Hour))
		encoded, err := s.Cursor.Encode(wirecore.CircleCursor{SnapshotID: strings.ToLower(graph.Graph.SnapshotID), GenerationID: candidates.GenerationID, Language: language, NextOrdinal: end, ExpiresAt: expires}, auth.DID)
		if err != nil {
			return CircleEdition{}, err
		}
		more = &encoded
	}
	public, err := s.publicStories(ctx, stories, membership, now)
	if err != nil {
		return CircleEdition{}, err
	}
	presentation := []wirecore.FeedItem{}
	for _, story := range stories {
		item := story.Item
		item.Reasons = []wirecore.ReasonCode{}
		distinct := map[string]bool{}
		reply := false
		latest := time.Time{}
		for _, fact := range story.Facts {
			if _, ok := membership[fact.ActorHash]; ok {
				distinct[fact.ActorHash] = true
				reply = reply || fact.Kind == "reply"
				if fact.OccurredAt.After(latest) {
					latest = fact.OccurredAt
				}
			}
		}
		if len(distinct) >= 3 {
			item.Reasons = append(item.Reasons, wirecore.SharedAcrossCommunities)
		}
		if reply {
			item.Reasons = append(item.Reasons, wirecore.WidelyDiscussed)
		}
		if !latest.IsZero() && now.Sub(latest) <= time.Hour {
			item.Reasons = append(item.Reasons, wirecore.BreakingStory)
		}
		presentation = append(presentation, item)
	}
	source := "ranked"
	if graph.Stale {
		source = "stale_generation"
	}
	assembled := wirecore.AssembleEdition(candidates.GenerationID, candidates.GeneratedAt, language, more, source, graph.Degraded(), presentation, nil)
	ids := func(items []wirecore.FeedItem) []string {
		out := []string{}
		for _, item := range items {
			out = append(out, item.ItemID)
		}
		return out
	}
	response := CircleEdition{EditionVersion: "circle-edition-v1", GenerationID: candidates.GenerationID, GeneratedAt: candidates.GeneratedAt, Language: language, Source: source, Degraded: graph.Degraded(), Stories: public, TopStoryIDs: ids(assembled.LeadStories), PublicationSpotlights: []CircleSpotlight{}, StoryRails: []StoryRail{}, TrendingStoryIDs: ids(assembled.TrendingStories), MoreCursor: more}
	for _, panel := range assembled.PublicationPanels {
		response.PublicationSpotlights = append(response.PublicationSpotlights, CircleSpotlight{panel.Publication.Key, panel.Stories[0].Source, ids(panel.Stories)})
	}
	for _, rail := range assembled.StoryRails {
		response.StoryRails = append(response.StoryRails, StoryRail{rail.ID, rail.Title, ids(rail.Stories)})
	}
	if ordinal == 0 && s.State.Cache != nil {
		body, err := corpuscore.MarshalHTTP(response)
		if err != nil {
			return CircleEdition{}, err
		}
		_ = s.State.Cache.StoreEdition(ctx, auth.DID, graph.Graph.SnapshotID, candidates.GenerationID, language, hidden, minTime(now.Add(10*time.Minute), graph.Graph.GeneratedAt.Add(24*time.Hour)), body, now)
	}
	return response, nil
}
func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}
func namedFact(kind string) bool {
	return kind == "recommendation" || kind == "share" || kind == "quote" || kind == "repost"
}
func (s *CircleService) publicStories(ctx context.Context, stories []corpuscore.CandidateStory, membership map[string]circleMembership, now time.Time) ([]CircleStory, error) {
	selected := map[string][]corpuscore.SignalFact{}
	counts := map[string]int{}
	actors := map[string]bool{}
	for _, story := range stories {
		best := map[string]corpuscore.SignalFact{}
		for _, fact := range story.Facts {
			if _, ok := membership[fact.ActorHash]; !ok || !namedFact(fact.Kind) {
				continue
			}
			if previous, ok := best[fact.ActorHash]; ok && !fact.OccurredAt.After(previous.OccurredAt) {
				continue
			}
			best[fact.ActorHash] = fact
		}
		facts := []corpuscore.SignalFact{}
		for _, fact := range best {
			facts = append(facts, fact)
		}
		sort.Slice(facts, func(i, j int) bool {
			a, b := facts[i], facts[j]
			am, bm := membership[a.ActorHash], membership[b.ActorHash]
			if am.Relationship != bm.Relationship {
				return am.Relationship == "direct"
			}
			if !a.OccurredAt.Equal(b.OccurredAt) {
				return a.OccurredAt.After(b.OccurredAt)
			}
			return am.DID < bm.DID
		})
		counts[story.Item.ItemID] = len(best)
		facts = facts[:min(5, len(facts))]
		selected[story.Item.ItemID] = facts
		for _, fact := range facts {
			actors[membership[fact.ActorHash].DID] = true
		}
	}
	profiles, err := s.Profiles.Profiles(ctx, keys(actors))
	if err != nil {
		return nil, err
	}
	result := []CircleStory{}
	for _, story := range stories {
		direct, oneHop := false, false
		distinct := map[string]bool{}
		replies := 0
		latest := time.Time{}
		for _, fact := range story.Facts {
			if member, ok := membership[fact.ActorHash]; ok {
				direct = direct || member.Relationship == "direct"
				oneHop = oneHop || member.Relationship == "one_hop"
				distinct[fact.ActorHash] = true
				if fact.Kind == "reply" {
					replies++
				}
				if fact.OccurredAt.After(latest) {
					latest = fact.OccurredAt
				}
			}
		}
		reasons := []string{}
		if direct {
			reasons = append(reasons, "shared_by_following")
		}
		if oneHop {
			reasons = append(reasons, "shared_by_extended_circle")
		}
		if len(distinct) >= 3 {
			reasons = append(reasons, "popular_in_your_circle")
		}
		if replies > 0 {
			reasons = append(reasons, "discussed_in_your_circle")
		}
		if !latest.IsZero() && now.Sub(latest) <= 6*time.Hour {
			reasons = append(reasons, "fresh_from_your_circle")
		}
		sharers := []CircleSharer{}
		for _, fact := range selected[story.Item.ItemID] {
			member := membership[fact.ActorHash]
			if identity, ok := profiles[member.DID]; ok {
				action := "shared"
				if fact.Kind == "recommendation" {
					action = "recommended"
				}
				sharers = append(sharers, CircleSharer{identity, member.Relationship, action, fact.SourceURI, fact.OccurredAt})
			}
		}
		item := story.Item
		result = append(result, CircleStory{item.ItemID, item.CanonicalURL, item.RepresentativeURI, item.Title, item.Summary, item.PublishedAt, item.ThumbnailURL, item.Source, reasons[:min(3, len(reasons))], replies, counts[item.ItemID], sharers})
	}
	return result, nil
}
