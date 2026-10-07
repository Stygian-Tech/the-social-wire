package topicreadcore

import (
	"context"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"golang.org/x/sync/errgroup"
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
		initial, err = s.source(ctx, language, now)
		if err != nil {
			return FinancePage{}, err
		}
	}
	initialCatalog, err := s.Catalog(ctx)
	if err != nil {
		return FinancePage{}, err
	}
	prefs, err := s.Selections.Finance(ctx, viewer, refresh && cursor == "", now)
	if err != nil {
		return FinancePage{}, err
	}
	revision := ""
	if feed == "finance" {
		revision = financecore.PreferenceFingerprint(prefs.Instruments, prefs.Sectors)
	} else {
		revision = FinanceNamedRevision(initialCatalog)
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
		retained, err := s.retained(ctx, decoded.GenerationID, snapshotScope, language, revision, now)
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
		catalog, err := s.Catalog(ctx)
		if err != nil {
			return FinancePage{}, err
		}
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
		proposal := corpuscore.FinanceGeneration{GenerationID: newID(), GeneratedAt: initial.GeneratedAt, ExpiresAt: minTime(initial.ExpiresAt, now.Add(48*time.Hour)), Language: language, Candidates: ranked, Source: initial.Source}
		snapshot, err = s.persist(ctx, proposal, initial, snapshotScope, revision, now)
		if err != nil {
			return FinancePage{}, err
		}
	}
	if ordinal > len(snapshot.Candidates) {
		return FinancePage{}, ErrInvalidCursor
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return FinancePage{}, err
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
	for ordinal < len(snapshot.Candidates) && len(accepted) < limit {
		end := min(ordinal+10, len(snapshot.Candidates))
		batch := snapshot.Candidates[ordinal:end]
		current := make([]*wirecore.FeedItem, len(batch))
		g, gctx := errgroup.WithContext(ctx)
		for index, candidate := range batch {
			g.Go(func() error {
				item, err := s.Wire.Item(gctx, candidate.Item.ItemID, viewer, now)
				if err != nil {
					return err
				}
				if item != nil {
					current[index] = &item.Item
				}
				return nil
			})
		}
		if err = g.Wait(); err != nil {
			return FinancePage{}, err
		}
		for index, candidate := range batch {
			ordinal++
			item := current[index]
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
func financeDefinition(feed string, catalog []financecore.Instrument) (FinanceDefinition, bool) {
	for _, definition := range FinanceDefinitions(catalog) {
		if definition.ID == feed {
			return definition, true
		}
	}
	return FinanceDefinition{}, false
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
