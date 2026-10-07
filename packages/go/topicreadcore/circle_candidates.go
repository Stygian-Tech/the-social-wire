package topicreadcore

import (
	"context"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"sort"
	"time"
)

func circleCandidates(ctx context.Context, store corpuscore.Store, hashes []string, language string, since time.Time, limit int, now time.Time) (corpuscore.CandidateResponse, error) {
	if _, remote := store.(*corpuscore.RemoteStore); !remote {
		return store.CircleCandidates(ctx, corpuscore.CandidateRequest{ActorHashes: hashes, Language: language, Since: since, Limit: limit}, now)
	}
	byID := map[string]corpuscore.CandidateStory{}
	generation := ""
	generated := time.Time{}
	for start := 0; start < len(hashes); start += 5000 {
		page, err := store.CircleCandidates(ctx, corpuscore.CandidateRequest{ActorHashes: hashes[start:min(start+5000, len(hashes))], Language: language, Since: since, Limit: limit}, now)
		if err != nil {
			return corpuscore.CandidateResponse{}, corpusError(err)
		}
		if generation != "" && generation != page.GenerationID {
			return corpuscore.CandidateResponse{}, ErrUnavailable
		}
		generation = page.GenerationID
		if page.GeneratedAt.After(generated) {
			generated = page.GeneratedAt
		}
		for _, story := range page.Stories {
			existing, ok := byID[story.Item.ItemID]
			if !ok {
				byID[story.Item.ItemID] = story
				continue
			}
			facts := map[string]corpuscore.SignalFact{}
			for _, fact := range append(existing.Facts, story.Facts...) {
				key := fmt.Sprintf("%s\n%s\n%.9f", fact.ActorHash, fact.SourceURI, float64(fact.OccurredAt.Unix())+float64(fact.OccurredAt.Nanosecond())/1e9)
				facts[key] = fact
			}
			existing.Facts = []corpuscore.SignalFact{}
			for _, fact := range facts {
				existing.Facts = append(existing.Facts, fact)
			}
			sort.Slice(existing.Facts, func(i, j int) bool {
				a, b := existing.Facts[i], existing.Facts[j]
				if !a.OccurredAt.Equal(b.OccurredAt) {
					return a.OccurredAt.After(b.OccurredAt)
				}
				if a.ActorHash != b.ActorHash {
					return a.ActorHash < b.ActorHash
				}
				return a.SourceURI < b.SourceURI
			})
			topics := map[string]bool{}
			for _, topic := range append(existing.TopicKeys, story.TopicKeys...) {
				topics[topic] = true
			}
			existing.TopicKeys = keys(topics)
			byID[story.Item.ItemID] = existing
		}
	}
	stories := []corpuscore.CandidateStory{}
	for _, story := range byID {
		stories = append(stories, story)
	}
	participants := func(story corpuscore.CandidateStory) (int, time.Time) {
		actors := map[string]bool{}
		at := time.Time{}
		for _, fact := range story.Facts {
			actors[fact.ActorHash] = true
			if fact.OccurredAt.After(at) {
				at = fact.OccurredAt
			}
		}
		return len(actors), at
	}
	sort.Slice(stories, func(i, j int) bool {
		ac, ad := participants(stories[i])
		bc, bd := participants(stories[j])
		if ac != bc {
			return ac > bc
		}
		if !ad.Equal(bd) {
			return ad.After(bd)
		}
		return stories[i].Item.ItemID < stories[j].Item.ItemID
	})
	if generation == "" {
		generation = fmt.Sprintf("circle-%d", now.Unix()/300)
		generated = now
	}
	return corpuscore.CandidateResponse{GenerationID: generation, GeneratedAt: generated, Language: language, Stories: stories[:min(limit, len(stories))], Exhausted: len(stories) < limit}, nil
}
