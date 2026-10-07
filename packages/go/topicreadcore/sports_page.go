package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"golang.org/x/sync/errgroup"
	"math"
	"time"
)

func (s *SportsStore) Page(ctx context.Context, cursor string, limit int, lang, viewer string, refresh bool, now time.Time, feed string, region *string) (SportsPage, error) {
	if !s.serves() {
		return SportsPage{}, ErrUnavailable
	}
	lang = topicLanguage(lang)
	if len(feed) > 256 {
		return SportsPage{}, ErrInvalidCursor
	}
	var initial corpuscore.SportsGeneration
	var err error
	if cursor == "" {
		initial, err = s.source(ctx, lang, now)
		if err != nil {
			return SportsPage{}, err
		}
	}
	initialCatalog, err := s.Catalog(ctx)
	if err != nil {
		return SportsPage{}, err
	}
	prefs, err := s.Selections.Sports(ctx, viewer, refresh && cursor == "", now)
	if err != nil {
		return SportsPage{}, err
	}
	catalogRevision, err := sportscore.ServingCatalogRevision(initialCatalog)
	if err != nil {
		return SportsPage{}, err
	}
	regionName := "global"
	if region != nil {
		regionName = *region
	}
	revision := sportscore.PreferenceFingerprint(prefs) + ":interests-v2:" + sportscore.ResolverVersion + ":" + catalogRevision + ":" + feed + ":" + regionName
	identity := viewer
	if identity == "" {
		identity = "anonymous-sports"
	}
	scope, err := s.Hasher.Hash(identity)
	if err != nil {
		return SportsPage{}, err
	}
	snapshotScope := scope + ":" + feed
	var snapshot corpuscore.SportsGeneration
	ordinal := 0
	if cursor != "" {
		decoded, err := s.Cursor.Decode(cursor, lang, revision, scope, feed, now)
		if err != nil {
			return SportsPage{}, err
		}
		retained, err := s.retained(ctx, decoded.GenerationID, snapshotScope, lang, revision, now)
		if err != nil {
			return SportsPage{}, err
		}
		if retained == nil {
			return SportsPage{}, ErrCursorExpired
		}
		snapshot = *retained
		ordinal = decoded.NextOrdinal
	} else {
		if !initial.ExpiresAt.After(now) {
			return SportsPage{}, ErrUnavailable
		}
		catalog, err := s.Catalog(ctx)
		if err != nil {
			return SportsPage{}, err
		}
		definition, ok := sportsDefinition(feed, catalog)
		if !ok {
			return SportsPage{}, ErrInvalidCursor
		}
		byID := map[string]sportscore.Entity{}
		for _, e := range catalog {
			if _, exists := byID[e.ID]; !exists {
				byID[e.ID] = e
			}
		}
		usIDs := map[string]bool{}
		for _, id := range []string{"nfl", "nba", "wnba", "mlb", "nhl", "mls", "nwsl", "ncaa-football", "ncaa-mens-basketball", "ncaa-womens-basketball", "ncaa-baseball", "ncaa-softball", "ncaa-hockey", "nascar", "indycar"} {
			usIDs[sportscore.ReviewedID("competition:"+id)] = true
		}
		matching := []sportscore.RankCandidate{}
		for _, c := range initial.Candidates {
			if !definition.Matches(c.Analysis) {
				continue
			}
			competitions := append([]string{}, c.Analysis.CompetitionIDs...)
			for _, a := range c.Analysis.Associations {
				competitions = append(competitions, byID[a.EntityID].CompetitionIDs...)
			}
			us := false
			for _, id := range competitions {
				us = us || usIDs[id]
			}
			regional := feed == "sports" && len(competitions) > 0 && ((regionName == "outside-us" && !us) || (regionName != "outside-us" && us))
			if regional {
				c.BaseScore *= 1.05
			}
			matching = append(matching, c)
		}
		ranked := sportscore.RankSelections(matching, prefs, catalog, feed == "sports")
		proposal := corpuscore.SportsGeneration{GenerationID: newID(), GeneratedAt: initial.GeneratedAt, ExpiresAt: minTime(initial.ExpiresAt, now.Add(48*time.Hour)), Language: lang, Candidates: ranked, Source: initial.Source}
		snapshot, err = s.persist(ctx, proposal, initial, snapshotScope, revision, now)
		if err != nil {
			return SportsPage{}, err
		}
	}
	if ordinal > len(snapshot.Candidates) {
		return SportsPage{}, ErrInvalidCursor
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return SportsPage{}, err
	}
	definition, ok := sportsDefinition(feed, catalog)
	if !ok {
		return SportsPage{}, ErrInvalidCursor
	}
	byID := map[string]sportscore.Entity{}
	for _, e := range catalog {
		if _, exists := byID[e.ID]; !exists {
			byID[e.ID] = e
		}
	}
	accepted := []SportsItem{}
	for ordinal < len(snapshot.Candidates) && len(accepted) < limit {
		end := min(ordinal+10, len(snapshot.Candidates))
		batch := snapshot.Candidates[ordinal:end]
		current := make([]*wirecore.FeedItem, len(batch))
		g, gctx := errgroup.WithContext(ctx)
		for i, c := range batch {
			g.Go(func() error {
				item, err := s.Wire.Item(gctx, c.Item.ItemID, viewer, now)
				if err != nil {
					return err
				}
				if item != nil {
					current[i] = &item.Item
				}
				return nil
			})
		}
		if err = g.Wait(); err != nil {
			return SportsPage{}, err
		}
		for i, c := range batch {
			ordinal++
			item := current[i]
			if item == nil {
				continue
			}
			unchanged := item.Title == c.Item.Title && equalStrings(item.Summary, c.Item.Summary) && item.Source.Domain == c.Item.Source.Domain && sportsCurrent([]sportscore.RankCandidate{c})
			analysis := c.Analysis
			if !unchanged {
				summary := ""
				if item.Summary != nil {
					summary = *item.Summary
				}
				analysis = sportscore.Analyze(item.Title, summary, catalog)
			}
			if !analysis.Eligible || !definition.Matches(analysis) || len(sportscore.RankSelections([]sportscore.RankCandidate{{Item: *item, Analysis: analysis, BaseScore: 1, MajorGlobal: c.MajorGlobal}}, prefs, catalog, false)) == 0 {
				continue
			}
			entities := []sportscore.Entity{}
			associations := []sportscore.Association{}
			for _, a := range analysis.Associations {
				e, exists := byID[a.EntityID]
				if !exists || a.ResolverVersion != sportscore.ResolverVersion || a.Confidence < .9 || a.Confidence > 1 || math.IsNaN(a.Confidence) || math.IsInf(a.Confidence, 0) {
					continue
				}
				entities = append(entities, e)
				associations = append(associations, a)
			}
			accepted = append(accepted, SportsItem{*item, entities, associations, analysis.Materiality, c.MajorGlobal, append([]string{}, analysis.SportIDs...), append([]string{}, analysis.CompetitionIDs...)})
			if len(accepted) == limit {
				break
			}
		}
	}
	var next *string
	if ordinal < len(snapshot.Candidates) {
		encoded, err := s.Cursor.Encode(TopicCursor{Feed: feed, GenerationID: snapshot.GenerationID, Language: lang, PreferenceFingerprint: revision, ViewerScope: scope, NextOrdinal: ordinal, ExpiresAt: topicExpiry(snapshot.ExpiresAt)})
		if err != nil {
			return SportsPage{}, err
		}
		next = &encoded
	}
	stale := now.Sub(snapshot.GeneratedAt) > 10*time.Minute
	fallback := snapshot.Source != nil && *snapshot.Source == "simplified_fallback"
	source := "ranked"
	if fallback {
		source = "simplified_fallback"
	} else if stale {
		source = "stale_generation"
	}
	return SportsPage{FeedID: feed, GenerationID: snapshot.GenerationID, GeneratedAt: snapshot.GeneratedAt, ExpiresAt: snapshot.ExpiresAt, Language: lang, PreferenceRevision: revision, Cursor: next, Source: source, EventsEnabled: s.Config.EventsEnabled, Degraded: stale || fallback, Items: accepted}, nil
}
