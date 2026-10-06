package wirecore

import (
	"errors"
	"math"
	"strings"
)

const (
	BaselineVersion       = "wire-v10"
	ExternalSignalVersion = "wire-v11"
)

var (
	ErrInvalidVersion      = errors.New("invalid ranking version")
	ErrInvalidWeight       = errors.New("invalid ranking weight")
	ErrZeroWeightTotal     = errors.New("zero ranking weight total")
	ErrInvalidThreshold    = errors.New("invalid ranking threshold")
	ErrInvalidDiversityCap = errors.New("invalid diversity cap")
)

type RankingWeights struct {
	DistinctSharers24h      float64 `json:"distinctSharers24h"`
	ShareVelocity1h         float64 `json:"shareVelocity1h"`
	LikeBreadthVelocity     float64 `json:"likeBreadthVelocity"`
	RepostBreadthVelocity   float64 `json:"repostBreadthVelocity"`
	CommunitySpread         float64 `json:"communitySpread"`
	Freshness               float64 `json:"freshness"`
	ResurfacingAcceleration float64 `json:"resurfacingAcceleration"`
	SourceConfidence        float64 `json:"sourceConfidence"`
	StandardSiteAuthority   float64 `json:"standardSiteAuthority"`
	OpenGraphMetadata       float64 `json:"openGraphMetadata"`
	RecommendationBreadth   float64 `json:"recommendationBreadth"`
	PositiveFeedbackBreadth float64 `json:"positiveFeedbackBreadth"`
	NegativeFeedbackPenalty float64 `json:"negativeFeedbackPenalty"`
}

func DefaultRankingWeights() RankingWeights {
	return RankingWeights{.22, .10, .02, .02, .14, .18, .06, .08, .11, .05, .10, .06, .10}
}
func (w RankingWeights) all() []float64 {
	return []float64{w.DistinctSharers24h, w.ShareVelocity1h, w.LikeBreadthVelocity, w.RepostBreadthVelocity, w.CommunitySpread, w.Freshness, w.ResurfacingAcceleration, w.SourceConfidence, w.StandardSiteAuthority, w.OpenGraphMetadata, w.RecommendationBreadth, w.PositiveFeedbackBreadth}
}

type RankingConfig struct {
	Version                             string              `json:"version"`
	Weights                             RankingWeights      `json:"weights"`
	Diversity                           DiversityPolicy     `json:"diversity"`
	MinimumHighIntentActors             int                 `json:"minimumHighIntentActors"`
	MinimumRecommendations              int                 `json:"minimumRecommendations"`
	StandardSiteMinimumHighIntentActors int                 `json:"standardSiteMinimumHighIntentActors"`
	BackfillMinimumHighIntentActors     int                 `json:"backfillMinimumHighIntentActors"`
	BackfillMinimumRecommendations      int                 `json:"backfillMinimumRecommendations"`
	MinimumRankedItems                  int                 `json:"minimumRankedItems"`
	MinimumSourceConfidence             float64             `json:"minimumSourceConfidence"`
	StandardSiteMinimumSourceConfidence float64             `json:"standardSiteMinimumSourceConfidence"`
	ActorBreadthTarget                  int                 `json:"actorBreadthTarget"`
	RecommendationBreadthTarget         int                 `json:"recommendationBreadthTarget"`
	FeedbackBreadthTarget               int                 `json:"feedbackBreadthTarget"`
	CommunityBreadthTarget              int                 `json:"communityBreadthTarget"`
	EngagementTarget                    int                 `json:"engagementTarget"`
	FreshnessHalfLife                   float64             `json:"freshnessHalfLife"`
	MaximumCandidateAge                 float64             `json:"maximumCandidateAge"`
	DomainPenalties                     DomainPenaltyPolicy `json:"domainPenalties"`
	LimitedCommercialPenalty            float64             `json:"limitedCommercialPenalty"`
	MissingThumbnailPenalty             float64             `json:"missingThumbnailPenalty"`
}

func DefaultRankingConfig() RankingConfig {
	return RankingConfig{
		Version: BaselineVersion, Weights: DefaultRankingWeights(), Diversity: DefaultDiversityPolicy(),
		MinimumHighIntentActors: 5, MinimumRecommendations: 2, StandardSiteMinimumHighIntentActors: 1,
		BackfillMinimumHighIntentActors: 3, BackfillMinimumRecommendations: 1, MinimumRankedItems: 50,
		MinimumSourceConfidence: .25, StandardSiteMinimumSourceConfidence: .75, ActorBreadthTarget: 30,
		RecommendationBreadthTarget: 10, FeedbackBreadthTarget: 10, CommunityBreadthTarget: 5, EngagementTarget: 80,
		FreshnessHalfLife: 36000, MaximumCandidateAge: 2592000, DomainPenalties: DefaultDomainPenaltyPolicy(),
		LimitedCommercialPenalty: .25, MissingThumbnailPenalty: .15,
	}
}
func ExternalSignalsV11() RankingConfig {
	c := DefaultRankingConfig()
	c.Version = ExternalSignalVersion
	return c
}
func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }
func unit(v float64) bool   { return finite(v) && v >= 0 && v <= 1 }
func (c RankingConfig) Validate() error {
	if c.Version != BaselineVersion && c.Version != ExternalSignalVersion {
		return ErrInvalidVersion
	}
	total := 0.0
	for _, w := range c.Weights.all() {
		if !finite(w) || w < 0 {
			return ErrInvalidWeight
		}
		total += w
	}
	if total <= 0 {
		return ErrZeroWeightTotal
	}
	if c.MinimumHighIntentActors < 0 || c.MinimumRecommendations < 0 || c.StandardSiteMinimumHighIntentActors < 0 || c.BackfillMinimumHighIntentActors < 0 || c.BackfillMinimumRecommendations < 0 || c.MinimumRankedItems <= 0 || !unit(c.MinimumSourceConfidence) || !unit(c.StandardSiteMinimumSourceConfidence) || c.ActorBreadthTarget <= 0 || c.RecommendationBreadthTarget <= 0 || c.FeedbackBreadthTarget <= 0 || c.CommunityBreadthTarget <= 0 || c.EngagementTarget <= 0 || !(c.FreshnessHalfLife > 0) || !(c.MaximumCandidateAge > 0) || !unit(c.Weights.NegativeFeedbackPenalty) || !unit(c.LimitedCommercialPenalty) || !unit(c.MissingThumbnailPenalty) {
		return ErrInvalidThreshold
	}
	if err := c.DomainPenalties.Validate(); err != nil {
		return err
	}
	for _, v := range c.Diversity.allCaps() {
		if v <= 0 {
			return ErrInvalidDiversityCap
		}
	}
	return nil
}

type DomainPenaltyPolicy struct {
	Penalties map[string]float64 `json:"penalties"`
}

func DefaultDomainPenaltyPolicy() DomainPenaltyPolicy {
	p := map[string]float64{}
	for _, d := range []string{"bsky.app", "facebook.com", "fb.com", "fb.watch", "instagram.com", "linkedin.com", "pinterest.com", "threads.net", "tiktok.com", "twitter.com", "x.com"} {
		p[d] = .05
	}
	for _, d := range []string{"redd.it", "reddit.com"} {
		p[d] = .04
	}
	for _, d := range []string{"twitch.tv", "youtu.be", "youtube.com"} {
		p[d] = .06
	}
	return DomainPenaltyPolicy{p}
}
func (p DomainPenaltyPolicy) Validate() error {
	for d, v := range p.Penalties {
		if d == "" || d != strings.ToLower(strings.TrimSpace(d)) || strings.HasPrefix(d, ".") || !finite(v) || v < 0 || v > .2 {
			return ErrInvalidThreshold
		}
	}
	return nil
}
func (p DomainPenaltyPolicy) Penalty(host string) float64 {
	host = strings.ToLower(strings.TrimSpace(host))
	longest := -1
	penalty := 0.0
	for root, v := range p.Penalties {
		if (host == root || strings.HasSuffix(host, "."+root)) && len(root) > longest {
			longest = len(root)
			penalty = v
		}
	}
	return penalty
}
