package wirecore

// Defines v10/v11 ranking versions, weights, signal thresholds, diversity caps, and
// longest-domain-match penalties. Time thresholds use seconds. Positive weights normalize
// together; negative-feedback penalty is applied separately.

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

// RankingWeights sets normalized positive signal contributions and a separately applied
// negative-feedback penalty.
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

// DefaultRankingWeights returns the shared Swift ranking signal weights.
func DefaultRankingWeights() RankingWeights {
	return RankingWeights{.22, .10, .02, .02, .14, .18, .06, .08, .11, .05, .10, .06, .10}
}
func (weights RankingWeights) all() []float64 {
	return []float64{weights.DistinctSharers24h, weights.ShareVelocity1h, weights.LikeBreadthVelocity, weights.RepostBreadthVelocity, weights.CommunitySpread, weights.Freshness, weights.ResurfacingAcceleration, weights.SourceConfidence, weights.StandardSiteAuthority, weights.OpenGraphMetadata, weights.RecommendationBreadth, weights.PositiveFeedbackBreadth}
}

// RankingConfig sets versioned admission, scoring, diversity, and penalty policy;
// duration-like numbers are seconds.
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

// DefaultRankingConfig returns the baseline wire-v10 contract including its fifty-item
// serving floor.
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

// ExternalSignalsV11 uses baseline scoring policy with the wire-v11 external-rollup
// version selector.
func ExternalSignalsV11() RankingConfig {
	config := DefaultRankingConfig()
	config.Version = ExternalSignalVersion
	return config
}
func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }
func unit(value float64) bool   { return finite(value) && value >= 0 && value <= 1 }

// Validate rejects values that violate this type’s documented bounds before they are used.
func (config RankingConfig) Validate() error {
	if config.Version != BaselineVersion && config.Version != ExternalSignalVersion {
		return ErrInvalidVersion
	}
	total := 0.0
	for _, weight := range config.Weights.all() {
		if !finite(weight) || weight < 0 {
			return ErrInvalidWeight
		}
		total += weight
	}
	if total <= 0 {
		return ErrZeroWeightTotal
	}
	if config.MinimumHighIntentActors < 0 || config.MinimumRecommendations < 0 || config.StandardSiteMinimumHighIntentActors < 0 || config.BackfillMinimumHighIntentActors < 0 || config.BackfillMinimumRecommendations < 0 || config.MinimumRankedItems <= 0 || !unit(config.MinimumSourceConfidence) || !unit(config.StandardSiteMinimumSourceConfidence) || config.ActorBreadthTarget <= 0 || config.RecommendationBreadthTarget <= 0 || config.FeedbackBreadthTarget <= 0 || config.CommunityBreadthTarget <= 0 || config.EngagementTarget <= 0 || !(config.FreshnessHalfLife > 0) || !(config.MaximumCandidateAge > 0) || !unit(config.Weights.NegativeFeedbackPenalty) || !unit(config.LimitedCommercialPenalty) || !unit(config.MissingThumbnailPenalty) {
		return ErrInvalidThreshold
	}
	if err := config.DomainPenalties.Validate(); err != nil {
		return err
	}
	for _, value := range config.Diversity.allCaps() {
		if value <= 0 {
			return ErrInvalidDiversityCap
		}
	}
	return nil
}

// DomainPenaltyPolicy maps normalized root domains to bounded penalties with longest
// matching root precedence.
type DomainPenaltyPolicy struct {
	Penalties map[string]float64 `json:"penalties"`
}

// DefaultDomainPenaltyPolicy returns reviewed small penalties for social/video/forum
// domains.
func DefaultDomainPenaltyPolicy() DomainPenaltyPolicy {
	part := map[string]float64{}
	for _, digest := range []string{"bsky.app", "facebook.com", "fb.com", "fb.watch", "instagram.com", "linkedin.com", "pinterest.com", "threads.net", "tiktok.com", "twitter.com", "x.com"} {
		part[digest] = .05
	}
	for _, digest := range []string{"redd.it", "reddit.com"} {
		part[digest] = .04
	}
	for _, digest := range []string{"twitch.tv", "youtu.be", "youtube.com"} {
		part[digest] = .06
	}
	return DomainPenaltyPolicy{part}
}

// Validate rejects values that violate this type’s documented bounds before they are used.
func (policy DomainPenaltyPolicy) Validate() error {
	for digest, value := range policy.Penalties {
		if digest == "" || digest != strings.ToLower(strings.TrimSpace(digest)) || strings.HasPrefix(digest, ".") || !finite(value) || value < 0 || value > .2 {
			return ErrInvalidThreshold
		}
	}
	return nil
}

// Penalty matches a host or its subdomain and uses the longest configured root, avoiding
// map-order dependence.
func (policy DomainPenaltyPolicy) Penalty(host string) float64 {
	host = strings.ToLower(strings.TrimSpace(host))
	longest := -1
	penalty := 0.0
	for root, value := range policy.Penalties {
		if (host == root || strings.HasSuffix(host, "."+root)) && len(root) > longest {
			longest = len(root)
			penalty = value
		}
	}
	return penalty
}
