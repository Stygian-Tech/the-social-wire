package wireworkercore

// Orchestrates connectivity, optional inbox maintenance, bounded retention, mandatory
// label refresh, language discovery, ranking plans, and publication. Off performs
// connectivity only; shadow never activates; api/visible activation requires both
// candidate and diverse-first-page floors.

import (
	"context"
	"crypto/rand"
	"fmt"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

// CycleConfig sets activation mode, external-signal plan, candidate/retention bounds,
// language, and rank policy.
type CycleConfig struct {
	Mode, ExternalSignalMode, LanguageBucket string
	CandidateLimit, RetentionBatchSize       int
	GenerationRetention                      time.Duration
	Ranking                                  wirecore.RankingConfig
}

// DefaultCycleConfig defaults to off with 5,000 candidates/retention rows and one-hour
// generation expiry.
func DefaultCycleConfig() CycleConfig {
	return CycleConfig{Mode: "off", ExternalSignalMode: "off", LanguageBucket: "und", CandidateLimit: 5000, RetentionBatchSize: 5000, GenerationRetention: time.Hour, Ranking: wirecore.DefaultRankingConfig()}
}

// CycleOutcome reports the primary plan’s generation, ranked count, and whether it became
// active.
type CycleOutcome struct {
	GenerationID string
	ItemCount    int
	Activated    bool
}

// Cycle orchestrates one rank/publication pass with caller-supplied inbox and label-
// refresh hooks.
type Cycle struct {
	Store         GenerationStore
	Config        CycleConfig
	MaintainInbox func(context.Context, time.Time) error
	RefreshLabels func(context.Context, time.Time) error
}

func newGenerationID() (string, error) {
	var identifierBytes [16]byte
	if _, err := rand.Read(identifierBytes[:]); err != nil {
		return "", err
	}
	identifierBytes[6] = identifierBytes[6]&15 | 64
	identifierBytes[8] = identifierBytes[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", identifierBytes[:4], identifierBytes[4:6], identifierBytes[6:8], identifierBytes[8:10], identifierBytes[10:]), nil
}

// Run runs maintenance and all eligible ranking plans; off checks connectivity and shadow
// plans cannot change serving pointers.
func (cycle Cycle) Run(ctx context.Context, at time.Time) (CycleOutcome, error) {
	config := cycle.Config
	if cycle.Store == nil {
		return CycleOutcome{}, fmt.Errorf("missing generation store")
	}
	if err := config.Ranking.Validate(); err != nil {
		return CycleOutcome{}, err
	}
	if config.Mode != "off" && config.Mode != "shadow" && config.Mode != "api" && config.Mode != "visible" {
		return CycleOutcome{}, fmt.Errorf("invalid wire feed mode %q", config.Mode)
	}
	if config.CandidateLimit <= 0 || config.RetentionBatchSize <= 0 || config.GenerationRetention <= 0 || config.LanguageBucket == "" {
		return CycleOutcome{}, fmt.Errorf("invalid wire cycle configuration")
	}
	type plan struct {
		ranking            wirecore.RankingConfig
		activationEligible bool
	}
	plans := []plan{}
	switch config.ExternalSignalMode {
	case "off":
		plans = append(plans, plan{config.Ranking, true})
	case "shadow":
		plans = append(plans, plan{config.Ranking, true}, plan{wirecore.ExternalSignalsV11(), false})
	case "rank":
		plans = append(plans, plan{wirecore.ExternalSignalsV11(), true})
	default:
		return CycleOutcome{}, fmt.Errorf("invalid external signal mode %q", config.ExternalSignalMode)
	}
	if err := cycle.Store.Ping(ctx); err != nil {
		return CycleOutcome{}, err
	}
	if config.Mode == "off" {
		return CycleOutcome{}, nil
	}
	if cycle.MaintainInbox != nil {
		if err := cycle.MaintainInbox(ctx, at); err != nil {
			return CycleOutcome{}, err
		}
	}
	if err := cycle.Store.DeleteExpired(ctx, at, config.RetentionBatchSize); err != nil {
		return CycleOutcome{}, err
	}
	if cycle.RefreshLabels == nil {
		return CycleOutcome{}, fmt.Errorf("baseline label refresh is required")
	}
	if err := cycle.RefreshLabels(ctx, at); err != nil {
		return CycleOutcome{}, err
	}
	buckets := []string{config.LanguageBucket}
	if config.LanguageBucket == "und" {
		servingRanking := config.Ranking
		for _, plan := range plans {
			if plan.activationEligible {
				servingRanking = plan.ranking
				break
			}
		}
		languages, err := cycle.Store.EligibleLanguageBuckets(ctx, 12, wirecore.MinimumLocaleCandidates, servingRanking, at)
		if err != nil {
			return CycleOutcome{}, err
		}
		for _, language := range languages {
			if language != config.LanguageBucket {
				buckets = append(buckets, language)
			}
		}
	}
	var primary CycleOutcome
	for _, bucket := range buckets {
		floor := wirecore.MinimumLocaleCandidates
		if bucket == "und" {
			floor = wirecore.MinimumGlobalCandidates
		}
		for _, plan := range plans {
			if err := ctx.Err(); err != nil {
				return CycleOutcome{}, err
			}
			candidates, err := cycle.Store.LoadCandidates(ctx, bucket, config.CandidateLimit, plan.ranking, at)
			if err != nil {
				return CycleOutcome{}, err
			}
			result, err := wirecore.Rank(candidates, at, plan.ranking)
			if err != nil {
				return CycleOutcome{}, err
			}
			id, err := newGenerationID()
			if err != nil {
				return CycleOutcome{}, err
			}
			activate := plan.activationEligible && (config.Mode == "api" || config.Mode == "visible") && len(result.Items) >= floor && len(result.Items) >= wirecore.DiverseFirstPageCount
			if err := cycle.Store.Commit(ctx, GenerationCommit{id, "wire", bucket, plan.ranking.Version, at, at.Add(config.GenerationRetention), activate, result}); err != nil {
				return CycleOutcome{}, err
			}
			if bucket == config.LanguageBucket && plan.activationEligible {
				primary = CycleOutcome{id, len(result.Items), activate}
			}
		}
	}
	return primary, nil
}
