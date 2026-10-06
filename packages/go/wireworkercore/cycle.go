package wireworkercore

import (
	"context"
	"crypto/rand"
	"fmt"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type CycleConfig struct {
	Mode, ExternalSignalMode, LanguageBucket string
	CandidateLimit, RetentionBatchSize       int
	GenerationRetention                      time.Duration
	Ranking                                  wirecore.RankingConfig
}

func DefaultCycleConfig() CycleConfig {
	return CycleConfig{Mode: "off", ExternalSignalMode: "off", LanguageBucket: "und", CandidateLimit: 5000, RetentionBatchSize: 5000, GenerationRetention: time.Hour, Ranking: wirecore.DefaultRankingConfig()}
}

type CycleOutcome struct {
	GenerationID string
	ItemCount    int
	Activated    bool
}
type Cycle struct {
	Store         GenerationStore
	Config        CycleConfig
	MaintainInbox func(context.Context, time.Time) error
	RefreshLabels func(context.Context, time.Time) error
}

func newGenerationID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}
func (c Cycle) Run(ctx context.Context, at time.Time) (CycleOutcome, error) {
	config := c.Config
	if c.Store == nil {
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
	if err := c.Store.Ping(ctx); err != nil {
		return CycleOutcome{}, err
	}
	if config.Mode == "off" {
		return CycleOutcome{}, nil
	}
	if c.MaintainInbox != nil {
		if err := c.MaintainInbox(ctx, at); err != nil {
			return CycleOutcome{}, err
		}
	}
	if err := c.Store.DeleteExpired(ctx, at, config.RetentionBatchSize); err != nil {
		return CycleOutcome{}, err
	}
	if c.RefreshLabels == nil {
		return CycleOutcome{}, fmt.Errorf("baseline label refresh is required")
	}
	if err := c.RefreshLabels(ctx, at); err != nil {
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
		languages, err := c.Store.EligibleLanguageBuckets(ctx, 12, wirecore.MinimumLocaleCandidates, servingRanking, at)
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
			candidates, err := c.Store.LoadCandidates(ctx, bucket, config.CandidateLimit, plan.ranking, at)
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
			if err := c.Store.Commit(ctx, GenerationCommit{id, "wire", bucket, plan.ranking.Version, at, at.Add(config.GenerationRetention), activate, result}); err != nil {
				return CycleOutcome{}, err
			}
			if bucket == config.LanguageBucket && plan.activationEligible {
				primary = CycleOutcome{id, len(result.Items), activate}
			}
		}
	}
	return primary, nil
}
