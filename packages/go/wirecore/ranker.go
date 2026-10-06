package wirecore

import (
	"math"
	"sort"
	"strconv"
	"time"
)

func clamp(v float64) float64 { return min(1, max(0, v)) }
func logarithmicRatio(v, target int) float64 {
	return clamp(math.Log1p(float64(max(0, v))) / math.Log1p(float64(target)))
}
func velocity(hour, day int) float64 {
	return clamp(float64(max(0, hour)) / (max(1, float64(max(0, day))/24) * 4))
}
func RotationNudge(key string, asOf time.Time) float64 {
	bucket := int64(math.Floor(float64(asOf.Unix()) / 1800))
	hash := uint64(14695981039346656037)
	for _, b := range []byte(strconv.FormatInt(bucket, 10) + "|" + key) {
		hash ^= uint64(b)
		hash *= 1099511628211
	}
	return float64(hash%1000001) / 1000000 * .005
}
func freshPublication(c Candidate, age float64, config RankingConfig) bool {
	return age <= 3*86400 && c.SourceConfidence >= config.StandardSiteMinimumSourceConfidence && enabled(c.IsStandardSite)
}
func admissionTier(c Candidate, age float64, config RankingConfig) int {
	if age <= 21600 && c.Shares1h >= 3 && c.Shares24h >= 3 {
		return 1
	}
	if c.Shares24h >= config.MinimumHighIntentActors || c.Recommendations24h >= config.MinimumRecommendations || (freshPublication(c, age, config) && c.Shares24h >= config.StandardSiteMinimumHighIntentActors) {
		return 1
	}
	if c.Shares24h >= config.BackfillMinimumHighIntentActors || c.Recommendations24h >= config.BackfillMinimumRecommendations {
		return 2
	}
	return 0
}
func percentile(values []int, q float64) int {
	if len(values) == 0 {
		return int(^uint(0) >> 1)
	}
	sort.Ints(values)
	return values[min(len(values)-1, max(0, int(math.Ceil(float64(len(values))*q))-1))]
}
func LimitedCommercialPenalty(c Candidate, config RankingConfig) float64 {
	if c.CommercialClass != Limited {
		return 0
	}
	return config.LimitedCommercialPenalty * min(max(c.CommercialScore, 3), 5) / 5
}
func Rank(candidates []Candidate, asOf time.Time, config RankingConfig) (RankingResult, error) {
	if err := config.Validate(); err != nil {
		return RankingResult{}, err
	}
	d := RankingDiagnostics{CandidateCount: len(candidates)}
	primary := []ScoredCandidate{}
	backfill := []ScoredCandidate{}
	sharesHour, sharesDay, communities := []int{}, []int{}, []int{}
	for _, c := range candidates {
		if admissionTier(c, c.Age(asOf), config) != 0 {
			sharesHour = append(sharesHour, c.Shares1h)
			sharesDay = append(sharesDay, c.Shares24h)
			communities = append(communities, c.Communities24h)
		}
	}
	pHour, pDay, pCommunity := percentile(sharesHour, .9), percentile(sharesDay, .9), percentile(communities, .75)
	total := 0.0
	for _, v := range config.Weights.all() {
		total += v
	}
	w := config.Weights
	for _, c := range candidates {
		age := c.Age(asOf)
		if age > config.MaximumCandidateAge {
			d.RejectedForAge++
			continue
		}
		if !finite(c.SourceConfidence) || c.SourceConfidence < config.MinimumSourceConfidence || !c.TargetKind.CanCreateItem() || c.CommercialClass == ProbableAd || (!enabled(c.IsStandardSite) && !enabled(c.HasUsableOpenGraphMetadata)) {
			d.RejectedForQuality++
			continue
		}
		tier := admissionTier(c, age, config)
		if tier == 0 {
			d.RejectedForSignalFloor++
			continue
		}
		standard, metadata := 0.0, 0.0
		if enabled(c.IsStandardSite) {
			standard = 1
		}
		if enabled(c.HasUsableOpenGraphMetadata) {
			metadata = 1
		}
		baseline := max(1, float64(c.Signals7d)/(7*24))
		positive := (logarithmicRatio(c.Shares24h, config.ActorBreadthTarget)*w.DistinctSharers24h +
			velocity(c.Shares1h, c.Shares24h)*w.ShareVelocity1h +
			.5*(logarithmicRatio(c.DistinctLikes24h, config.ActorBreadthTarget)+velocity(c.Likes1h, c.Likes24h))*w.LikeBreadthVelocity +
			.5*(logarithmicRatio(c.DistinctReposts24h, config.ActorBreadthTarget)+velocity(c.Reposts1h, c.Reposts24h))*w.RepostBreadthVelocity +
			clamp(float64(c.Communities24h)/float64(config.CommunityBreadthTarget))*w.CommunitySpread +
			math.Pow(.5, age/config.FreshnessHalfLife)*w.Freshness +
			clamp(float64(c.Shares1h)/(baseline*3))*w.ResurfacingAcceleration +
			clamp(c.SourceConfidence)*w.SourceConfidence + standard*w.StandardSiteAuthority + metadata*w.OpenGraphMetadata +
			logarithmicRatio(c.Recommendations24h, config.RecommendationBreadthTarget)*w.RecommendationBreadth +
			logarithmicRatio(c.PositiveFeedback24h, config.FeedbackBreadthTarget)*w.PositiveFeedbackBreadth) / total
		feedback := clamp(positive - logarithmicRatio(c.NegativeFeedback24h, config.FeedbackBreadthTarget)*w.NegativeFeedbackPenalty)
		thumbnail := 0.0
		if !enabled(c.HasUsableThumbnail) {
			thumbnail = config.MissingThumbnailPenalty
		}
		score := clamp(feedback - config.DomainPenalties.Penalty(c.SourceDomain) - LimitedCommercialPenalty(c, config) - thumbnail + RotationNudge(c.CanonicalKey, asOf))
		if !finite(score) {
			continue
		}
		reasons := []ReasonCode{}
		if age <= 21600 && c.Shares1h >= max(1, pHour) {
			reasons = append(reasons, BreakingStory)
		}
		if c.Shares24h >= max(1, pDay) {
			reasons = append(reasons, WidelyDiscussed)
		}
		if c.Communities24h >= 3 && c.Communities24h >= max(1, pCommunity) {
			reasons = append(reasons, SharedAcrossCommunities)
		}
		if freshPublication(c, age, config) {
			reasons = append(reasons, FreshPublication)
		}
		if age >= 172800 && float64(c.Shares1h) >= baseline*3 {
			reasons = append(reasons, Resurfacing)
		}
		if len(reasons) > 2 {
			reasons = reasons[:2]
		}
		item := ScoredCandidate{c, score, reasons}
		if tier == 1 {
			primary = append(primary, item)
		} else {
			backfill = append(backfill, item)
		}
	}
	less := func(items []ScoredCandidate) func(int, int) bool {
		return func(i, j int) bool {
			if items[i].Score != items[j].Score {
				return items[i].Score > items[j].Score
			}
			return items[i].Candidate.CanonicalKey < items[j].Candidate.CanonicalKey
		}
	}
	sort.SliceStable(primary, less(primary))
	sort.SliceStable(backfill, less(backfill))
	n := min(len(backfill), max(0, config.MinimumRankedItems-len(primary)))
	d.QualityBackfillCount = n
	d.RejectedForSignalFloor += len(backfill) - n
	scored := append(primary, backfill[:n]...)
	d.EligibleCount = len(scored)
	result := Rerank(scored, config.Diversity)
	d.DiversityDeferrals = len(result.Interventions)
	return RankingResult{result.Items, d}, nil
}
