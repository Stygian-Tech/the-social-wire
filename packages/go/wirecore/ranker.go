package wirecore

// Validates configuration, computes reason percentiles, applies age/quality/signal
// admission, and combines normalized breadth, velocity, freshness, authority, and feedback
// signals. Penalties and deterministic rotation precede primary/backfill ordering and
// diversity reranking.

import (
	"math"
	"sort"
	"strconv"
	"time"
)

func clamp(value float64) float64 { return min(1, max(0, value)) }
func logarithmicRatio(value, target int) float64 {
	return clamp(math.Log1p(float64(max(0, value))) / math.Log1p(float64(target)))
}
func velocity(hour, day int) float64 {
	return clamp(float64(max(0, hour)) / (max(1, float64(max(0, day))/24) * 4))
}

// RotationNudge returns a deterministic score nudge up to 0.005 from key and thirty-minute
// time bucket.
func RotationNudge(key string, asOf time.Time) float64 {
	bucket := int64(math.Floor(float64(asOf.Unix()) / 1800))
	hash := uint64(14695981039346656037)
	for _, octet := range []byte(strconv.FormatInt(bucket, 10) + "|" + key) {
		hash ^= uint64(octet)
		hash *= 1099511628211
	}
	return float64(hash%1000001) / 1000000 * .005
}
func freshPublication(candidate Candidate, age float64, config RankingConfig) bool {
	return age <= 3*86400 && candidate.SourceConfidence >= config.StandardSiteMinimumSourceConfidence && enabled(candidate.IsStandardSite)
}
func admissionTier(candidate Candidate, age float64, config RankingConfig) int {
	if age <= 21600 && candidate.Shares1h >= 3 && candidate.Shares24h >= 3 {
		return 1
	}
	if candidate.Shares24h >= config.MinimumHighIntentActors || candidate.Recommendations24h >= config.MinimumRecommendations || (freshPublication(candidate, age, config) && candidate.Shares24h >= config.StandardSiteMinimumHighIntentActors) {
		return 1
	}
	if candidate.Shares24h >= config.BackfillMinimumHighIntentActors || candidate.Recommendations24h >= config.BackfillMinimumRecommendations {
		return 2
	}
	return 0
}
func percentile(values []int, quantile float64) int {
	if len(values) == 0 {
		return int(^uint(0) >> 1)
	}
	sort.Ints(values)
	return values[min(len(values)-1, max(0, int(math.Ceil(float64(len(values))*quantile))-1))]
}

// LimitedCommercialPenalty scales the configured limited-content penalty with commercial
// evidence between scores three and five.
func LimitedCommercialPenalty(candidate Candidate, config RankingConfig) float64 {
	if candidate.CommercialClass != Limited {
		return 0
	}
	return config.LimitedCommercialPenalty * min(max(candidate.CommercialScore, 3), 5) / 5
}

// Rank admits and scores an explicit-time snapshot, selects bounded quality backfill, then
// diversifies the ordered stream.
func Rank(candidates []Candidate, asOf time.Time, config RankingConfig) (RankingResult, error) {
	if err := config.Validate(); err != nil {
		return RankingResult{}, err
	}
	diagnostics := RankingDiagnostics{CandidateCount: len(candidates)}
	primary := []ScoredCandidate{}
	backfill := []ScoredCandidate{}
	// Reason thresholds intentionally use signal-admitted candidates before
	// the later quality/age filter, matching the Swift reason population.
	sharesHour, sharesDay, communities := []int{}, []int{}, []int{}
	for _, candidate := range candidates {
		if admissionTier(candidate, candidate.Age(asOf), config) != 0 {
			sharesHour = append(sharesHour, candidate.Shares1h)
			sharesDay = append(sharesDay, candidate.Shares24h)
			communities = append(communities, candidate.Communities24h)
		}
	}
	hourSharePercentile, daySharePercentile, communityPercentile := percentile(sharesHour, .9), percentile(sharesDay, .9), percentile(communities, .75)
	positiveWeightTotal := 0.0
	for _, value := range config.Weights.all() {
		positiveWeightTotal += value
	}
	weights := config.Weights
	for _, candidate := range candidates {
		age := candidate.Age(asOf)
		if age > config.MaximumCandidateAge {
			diagnostics.RejectedForAge++
			continue
		}
		if !finite(candidate.SourceConfidence) || candidate.SourceConfidence < config.MinimumSourceConfidence || !candidate.TargetKind.CanCreateItem() || candidate.CommercialClass == ProbableAd || (!enabled(candidate.IsStandardSite) && !enabled(candidate.HasUsableOpenGraphMetadata)) {
			diagnostics.RejectedForQuality++
			continue
		}
		tier := admissionTier(candidate, age, config)
		if tier == 0 {
			diagnostics.RejectedForSignalFloor++
			continue
		}
		standard, metadata := 0.0, 0.0
		if enabled(candidate.IsStandardSite) {
			standard = 1
		}
		if enabled(candidate.HasUsableOpenGraphMetadata) {
			metadata = 1
		}
		baseline := max(1, float64(candidate.Signals7d)/(7*24))
		// Normalize positive contributions together, then apply feedback and
		// content/presentation penalties separately before final clamping.
		positive := (logarithmicRatio(candidate.Shares24h, config.ActorBreadthTarget)*weights.DistinctSharers24h +
			velocity(candidate.Shares1h, candidate.Shares24h)*weights.ShareVelocity1h +
			.5*(logarithmicRatio(candidate.DistinctLikes24h, config.ActorBreadthTarget)+velocity(candidate.Likes1h, candidate.Likes24h))*weights.LikeBreadthVelocity +
			.5*(logarithmicRatio(candidate.DistinctReposts24h, config.ActorBreadthTarget)+velocity(candidate.Reposts1h, candidate.Reposts24h))*weights.RepostBreadthVelocity +
			clamp(float64(candidate.Communities24h)/float64(config.CommunityBreadthTarget))*weights.CommunitySpread +
			math.Pow(.5, age/config.FreshnessHalfLife)*weights.Freshness +
			clamp(float64(candidate.Shares1h)/(baseline*3))*weights.ResurfacingAcceleration +
			clamp(candidate.SourceConfidence)*weights.SourceConfidence + standard*weights.StandardSiteAuthority + metadata*weights.OpenGraphMetadata +
			logarithmicRatio(candidate.Recommendations24h, config.RecommendationBreadthTarget)*weights.RecommendationBreadth +
			logarithmicRatio(candidate.PositiveFeedback24h, config.FeedbackBreadthTarget)*weights.PositiveFeedbackBreadth) / positiveWeightTotal
		feedback := clamp(positive - logarithmicRatio(candidate.NegativeFeedback24h, config.FeedbackBreadthTarget)*weights.NegativeFeedbackPenalty)
		thumbnail := 0.0
		if !enabled(candidate.HasUsableThumbnail) {
			thumbnail = config.MissingThumbnailPenalty
		}
		score := clamp(feedback - config.DomainPenalties.Penalty(candidate.SourceDomain) - LimitedCommercialPenalty(candidate, config) - thumbnail + RotationNudge(candidate.CanonicalKey, asOf))
		if !finite(score) {
			continue
		}
		reasons := []ReasonCode{}
		if age <= 21600 && candidate.Shares1h >= max(1, hourSharePercentile) {
			reasons = append(reasons, BreakingStory)
		}
		if candidate.Shares24h >= max(1, daySharePercentile) {
			reasons = append(reasons, WidelyDiscussed)
		}
		if candidate.Communities24h >= 3 && candidate.Communities24h >= max(1, communityPercentile) {
			reasons = append(reasons, SharedAcrossCommunities)
		}
		if freshPublication(candidate, age, config) {
			reasons = append(reasons, FreshPublication)
		}
		if age >= 172800 && float64(candidate.Shares1h) >= baseline*3 {
			reasons = append(reasons, Resurfacing)
		}
		if len(reasons) > 2 {
			reasons = reasons[:2]
		}
		item := ScoredCandidate{candidate, score, reasons}
		if tier == 1 {
			primary = append(primary, item)
		} else {
			backfill = append(backfill, item)
		}
	}
	less := func(items []ScoredCandidate) func(int, int) bool {
		return func(itemIndex, comparisonIndex int) bool {
			if items[itemIndex].Score != items[comparisonIndex].Score {
				return items[itemIndex].Score > items[comparisonIndex].Score
			}
			return items[itemIndex].Candidate.CanonicalKey < items[comparisonIndex].Candidate.CanonicalKey
		}
	}
	sort.SliceStable(primary, less(primary))
	sort.SliceStable(backfill, less(backfill))
	// Backfill fills only a short primary list; its scores never displace
	// primary candidates. Diversity operates on the combined stream.
	count := min(len(backfill), max(0, config.MinimumRankedItems-len(primary)))
	diagnostics.QualityBackfillCount = count
	diagnostics.RejectedForSignalFloor += len(backfill) - count
	scored := append(primary, backfill[:count]...)
	diagnostics.EligibleCount = len(scored)
	result := Rerank(scored, config.Diversity)
	diagnostics.DiversityDeferrals = len(result.Interventions)
	return RankingResult{result.Items, diagnostics}, nil
}
