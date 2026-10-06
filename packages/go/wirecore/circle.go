package wirecore

import (
	"errors"
	"math"
	"sort"
	"strings"
	"time"
)

type CircleRelationship struct {
	Direct    bool
	PathCount int
}

func (r CircleRelationship) Weight() float64 {
	if r.Direct {
		return 1
	}
	return min(.8, .5+float64(max(1, r.PathCount)-1)*.1)
}

type CircleParticipantSignal struct {
	ParticipantKey string
	Relationship   CircleRelationship
	OccurredAt     time.Time
}
type CircleRankCandidate struct {
	CanonicalKey                         string
	ParticipantSignals                   []CircleParticipantSignal
	Quality, Presentation, InterestMatch float64
}
type CircleScoreComponents struct{ ParticipantBreadth, RelationshipStrength, RecencyVelocity, QualityPresentation, InterestMatch float64 }
type CircleRankedCandidate struct {
	Candidate  CircleRankCandidate
	Score      float64
	Components CircleScoreComponents
}
type CircleRankingDiagnostics struct{ CandidateCount, EligibleCount, RejectedWithoutEligibleParticipants, RejectedForInvalidInput int }
type CircleRankingResult struct {
	Items       []CircleRankedCandidate
	Diagnostics CircleRankingDiagnostics
}
type CircleRankingConfig struct {
	ParticipantBreadthTarget          int
	RecencyHalfLife, MaximumSignalAge float64
}

func DefaultCircleRankingConfig() CircleRankingConfig { return CircleRankingConfig{8, 43200, 604800} }
func (c CircleRankingConfig) Validate() error {
	if c.ParticipantBreadthTarget <= 0 || !finite(c.RecencyHalfLife) || c.RecencyHalfLife <= 0 || !finite(c.MaximumSignalAge) || c.MaximumSignalAge <= 0 {
		return errors.New("invalid circle ranking threshold")
	}
	return nil
}
func RankCircle(candidates []CircleRankCandidate, asOf time.Time, config CircleRankingConfig) (CircleRankingResult, error) {
	if err := config.Validate(); err != nil {
		return CircleRankingResult{}, err
	}
	r := CircleRankingResult{Items: []CircleRankedCandidate{}, Diagnostics: CircleRankingDiagnostics{CandidateCount: len(candidates)}}
	type participant struct {
		weight float64
		latest time.Time
	}
	for _, c := range candidates {
		key := strings.TrimSpace(c.CanonicalKey)
		if key == "" || len(key) > 160 || !finite(c.Quality) || !finite(c.Presentation) || !finite(c.InterestMatch) {
			r.Diagnostics.RejectedForInvalidInput++
			continue
		}
		people := map[string]participant{}
		for _, s := range c.ParticipantSignals {
			age := asOf.Sub(s.OccurredAt).Seconds()
			if age < 0 || age > config.MaximumSignalAge {
				continue
			}
			key := strings.TrimSpace(s.ParticipantKey)
			if key == "" {
				continue
			}
			p, ok := people[key]
			if !ok {
				people[key] = participant{s.Relationship.Weight(), s.OccurredAt}
			} else {
				p.weight = max(p.weight, s.Relationship.Weight())
				if s.OccurredAt.After(p.latest) {
					p.latest = s.OccurredAt
				}
				people[key] = p
			}
		}
		if len(people) == 0 {
			r.Diagnostics.RejectedWithoutEligibleParticipants++
			continue
		}
		keys := make([]string, 0, len(people))
		for key := range people {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		relationship := 0.0
		var latest time.Time
		hour, day := 0, 0
		for _, key := range keys {
			p := people[key]
			relationship += p.weight
			if p.latest.After(latest) {
				latest = p.latest
			}
			age := asOf.Sub(p.latest).Seconds()
			if age <= 3600 {
				hour++
			}
			if age <= 86400 {
				day++
			}
		}
		recency := math.Pow(.5, max(0, asOf.Sub(latest).Seconds())/config.RecencyHalfLife)
		velocity := clamp(float64(hour) / (max(1, float64(day)/24) * 4))
		comp := CircleScoreComponents{logarithmicRatio(len(people), config.ParticipantBreadthTarget), clamp(relationship / float64(len(people))), clamp((recency + velocity) / 2), clamp((c.Quality + c.Presentation) / 2), clamp(c.InterestMatch)}
		score := comp.ParticipantBreadth*.35 + comp.RelationshipStrength*.25 + comp.RecencyVelocity*.20 + comp.QualityPresentation*.10 + comp.InterestMatch*.10
		r.Items = append(r.Items, CircleRankedCandidate{c, score, comp})
	}
	sort.SliceStable(r.Items, func(i, j int) bool {
		a, b := r.Items[i], r.Items[j]
		if a.Score != b.Score {
			return a.Score > b.Score
		}
		return a.Candidate.CanonicalKey < b.Candidate.CanonicalKey
	})
	r.Diagnostics.EligibleCount = len(r.Items)
	return r, nil
}
