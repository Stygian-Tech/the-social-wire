package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"log/slog"
	"math"
	"strings"
	"time"
)

func (s *FinanceStore) Page(ctx context.Context, cursor string, limit int, language, viewer string, refresh bool, now time.Time, feed string, hideCrypto bool) (FinancePage, error) {
	if !s.serves() {
		return FinancePage{}, ErrUnavailable
	}
	language = topicLanguage(language)
	if len(feed) > 256 {
		return FinancePage{}, ErrInvalidCursor
	}
	var initial corpuscore.FinanceGeneration
	var err error
	if cursor == "" {
		started := time.Now()
		initial, err = s.source(ctx, language, now)
		ObserveFeedPhase(ctx, "source", time.Since(started))
		if err != nil {
			return FinancePage{}, err
		}
	}
	started := time.Now()
	catalog, err := s.Catalog(ctx)
	ObserveFeedPhase(ctx, "catalog", time.Since(started))
	if err != nil {
		return FinancePage{}, err
	}
	started = time.Now()
	prefs, err := s.Selections.Finance(ctx, viewer, refresh && cursor == "", now)
	ObserveFeedPhase(ctx, "selections", time.Since(started))
	if err != nil {
		return FinancePage{}, err
	}
	revision := ""
	if feed == "finance" {
		revision = financecore.PreferenceFingerprint(prefs.Instruments, prefs.Sectors)
	} else {
		revision = FinanceNamedRevision(catalog)
	}
	revision += ":" + s.Config.Policy.Revision()
	if hideCrypto {
		revision += ":hide-crypto-v1"
	} else {
		revision += ":show-crypto-v1"
	}
	identity := viewer
	if identity == "" {
		identity = "anonymous-finance"
	}
	scope, err := s.Hasher.Hash(identity)
	if err != nil {
		return FinancePage{}, err
	}
	snapshotScope := scope
	if feed != "finance" {
		snapshotScope = "shared:" + feed
	}
	var snapshot corpuscore.FinanceGeneration
	ordinal := 0
	if cursor != "" {
		decoded, err := s.Cursor.Decode(cursor, language, revision, scope, feed, now)
		if err != nil {
			return FinancePage{}, err
		}
		started = time.Now()
		retained, err := s.retained(ctx, decoded.GenerationID, snapshotScope, language, revision, now)
		ObserveFeedPhase(ctx, "snapshot-load", time.Since(started))
		if err != nil {
			return FinancePage{}, err
		}
		if retained == nil {
			return FinancePage{}, ErrCursorExpired
		}
		snapshot = *retained
		ordinal = decoded.NextOrdinal
	} else {
		if !initial.ExpiresAt.After(now) {
			return FinancePage{}, ErrUnavailable
		}
		started = time.Now()
		reused, err := s.reusable(ctx, initial.GenerationID, snapshotScope, language, revision, now)
		ObserveFeedPhase(ctx, "snapshot-lookup", time.Since(started))
		if err != nil {
			return FinancePage{}, err
		}
		if reused != nil {
			snapshot = *reused
		} else {
			started = time.Now()
			definition, ok := financeDefinition(feed, catalog)
			if !ok {
				return FinancePage{}, ErrInvalidCursor
			}
			permitted := map[string]bool{}
			for _, i := range catalog {
				permitted[i.ID] = true
			}
			candidates := []financecore.RankCandidate{}
			for _, candidate := range initial.Candidates {
				if feed != "finance" {
					candidate.Analysis = analyzeFinance(candidate.Item, structuredFinance(candidate.Analysis), catalog)
					if !definition.Matches(candidate.Analysis, candidate.Item.Title, candidate.Item.Summary) {
						continue
					}
				}
				if hideCrypto && financeCryptoStory(candidate.Item.Title, candidate.Item.Summary, candidate.Analysis, catalog) {
					continue
				}
				candidates = append(candidates, candidate)
			}
			instruments, sectors := map[string]bool{}, map[string]bool{}
			if feed == "finance" {
				for _, id := range prefs.Instruments {
					if permitted[id] {
						instruments[id] = true
					}
				}
				for _, id := range prefs.Sectors {
					sectors[id] = true
				}
			}
			ranked := financecore.Rank(candidates, instruments, sectors, feed == "finance")
			ObserveFeedPhase(ctx, "analysis", time.Since(started))
			proposal := corpuscore.FinanceGeneration{GenerationID: newID(), GeneratedAt: initial.GeneratedAt, ExpiresAt: minTime(initial.ExpiresAt, now.Add(48*time.Hour)), Language: language, Candidates: ranked, Source: initial.Source}
			started = time.Now()
			snapshot, err = s.persist(ctx, proposal, initial, snapshotScope, revision, now)
			ObserveFeedPhase(ctx, "snapshot-persistence", time.Since(started))
			if err != nil {
				return FinancePage{}, err
			}
		}
	}
	if ordinal > len(snapshot.Candidates) {
		return FinancePage{}, ErrInvalidCursor
	}
	definition, ok := financeDefinition(feed, catalog)
	if !ok {
		return FinancePage{}, ErrInvalidCursor
	}
	byID := map[string]financecore.Instrument{}
	for _, i := range catalog {
		if _, exists := byID[i.ID]; !exists {
			byID[i.ID] = i
		}
	}
	accepted := []FinanceItem{}
	// Hydrate only the requested first page; filtered pages refill in bounded
	// full batches so rejection does not create one request per missing story.
	batchSize := min(limit, corpuscore.MaximumBatchItems)
	for ordinal < len(snapshot.Candidates) && len(accepted) < limit {
		end := min(ordinal+batchSize, len(snapshot.Candidates))
		batchSize = corpuscore.MaximumBatchItems
		batch := snapshot.Candidates[ordinal:end]
		ids := make([]string, 0, len(batch))
		seen := map[string]bool{}
		for _, candidate := range batch {
			if !seen[candidate.Item.ItemID] {
				ids = append(ids, candidate.Item.ItemID)
				seen[candidate.Item.ItemID] = true
			}
		}
		started := time.Now()
		current, err := s.Wire.Items(ctx, ids, viewer, now)
		ObserveFeedPhase(ctx, "rehydration", time.Since(started))
		slog.Debug("Topic feed phase", "feed", feed, "phase", "rehydration", "duration_ms", time.Since(started).Milliseconds(), "candidates", len(ids))
		if err != nil {
			return FinancePage{}, err
		}

		started = time.Now()
		for _, candidate := range batch {
			ordinal++
			item := current[candidate.Item.ItemID]
			if item == nil {
				continue
			}
			unchanged := item.Title == candidate.Item.Title && equalStrings(item.Summary, candidate.Item.Summary) && item.Source.Domain == candidate.Item.Source.Domain
			analysis := candidate.Analysis
			if feed != "finance" || !unchanged || analysis.ResolverVersion == nil || *analysis.ResolverVersion != financecore.ResolverVersion {
				structured := []string{}
				if unchanged {
					structured = structuredFinance(candidate.Analysis)
				}
				analysis = analyzeFinance(*item, structured, catalog)
			}
			if !analysis.Eligible || !definition.Matches(analysis, item.Title, item.Summary) || (hideCrypto && financeCryptoStory(item.Title, item.Summary, analysis, catalog)) {
				continue
			}
			matches := []FinanceMatchedInstrument{}
			for _, match := range analysis.Associations {
				instrument, exists := byID[match.InstrumentID]
				if !exists || math.IsNaN(match.Confidence) || math.IsInf(match.Confidence, 0) || match.Confidence < .9 || match.Confidence > 1 {
					continue
				}
				matches = append(matches, FinanceMatchedInstrument{instrument, int(math.Round(match.Confidence * 10000)), match.Prominence, append([]string{}, match.Evidence...), match.ResolverVersion})
			}
			accepted = append(accepted, FinanceItem{*item, matches, append([]string{}, analysis.MacroTopics...), append([]string{}, analysis.SectorIDs...), candidate.MajorGlobal, analysis.Materiality})
			if len(accepted) == limit {
				break
			}
		}
		ObserveFeedPhase(ctx, "analysis", time.Since(started))
	}
	var next *string
	if ordinal < len(snapshot.Candidates) {
		encoded, err := s.Cursor.Encode(TopicCursor{Feed: feed, GenerationID: snapshot.GenerationID, Language: language, PreferenceFingerprint: revision, ViewerScope: scope, NextOrdinal: ordinal, ExpiresAt: topicExpiry(snapshot.ExpiresAt)})
		if err != nil {
			return FinancePage{}, err
		}
		next = &encoded
	}
	stale := now.Sub(snapshot.GeneratedAt) > 10*time.Minute
	source := "ranked"
	fallback := snapshot.Source != nil && *snapshot.Source == "simplified_fallback"
	if fallback {
		source = "simplified_fallback"
	} else if stale {
		source = "stale_generation"
	}
	return FinancePage{FeedID: feed, GenerationID: snapshot.GenerationID, GeneratedAt: snapshot.GeneratedAt, ExpiresAt: snapshot.ExpiresAt, Language: language, PreferenceRevision: revision, Cursor: next, Source: source, WidgetsEnabled: s.Config.Widgets, Degraded: stale || fallback, Items: accepted}, nil
}
func equalStrings(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}
func structuredFinance(analysis financecore.ArticleAnalysis) []string {
	result := []string{}
	for _, a := range analysis.Associations {
		if a.Confidence < .9 || a.Confidence > 1 || math.IsNaN(a.Confidence) || math.IsInf(a.Confidence, 0) || a.ResolverVersion != financecore.ResolverVersion {
			continue
		}
		for _, e := range a.Evidence {
			if e == "structured-metadata" {
				result = append(result, a.InstrumentID)
				break
			}
		}
	}
	return result
}
func analyzeFinance(item wirecore.FeedItem, structured []string, catalog []financecore.Instrument) financecore.ArticleAnalysis {
	summary := ""
	if item.Summary != nil {
		summary = *item.Summary
	}
	return financecore.Analyze(item.Title, summary, structured, financecore.VerifiedInstrumentIDs(strings.ToLower(item.Source.Domain), ""), catalog)
}
