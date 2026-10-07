package wirecore

// Aggregates eligible signals by participant, keeping each strongest relationship and
// latest timestamp. Sorted participant keys stabilize floating-point accumulation;
// breadth, relationship, recency/velocity, presentation, and interest components produce
// deterministic score/key order.

import (
	"errors"
	"math"
	"sort"
	"strings"
	"time"
)

// CircleRelationship describes a direct or multi-path indirect relationship to a
// participant.
type CircleRelationship struct {
	Direct    bool
	PathCount int
}

// Weight gives direct relationships weight one and indirect relationships a bounded path-
// count boost.
func (relationship CircleRelationship) Weight() float64 {
	if relationship.Direct {
		return 1
	}
	return min(.8, .5+float64(max(1, relationship.PathCount)-1)*.1)
}

// CircleParticipantSignal links a participant’s pseudonym, relationship, and event
// instant.
type CircleParticipantSignal struct {
	ParticipantKey string
	Relationship   CircleRelationship
	OccurredAt     time.Time
}

// CircleRankCandidate provides participant evidence and finite quality, presentation, and
// interest inputs.
type CircleRankCandidate struct {
	CanonicalKey                         string
	ParticipantSignals                   []CircleParticipantSignal
	Quality, Presentation, InterestMatch float64
}

// CircleScoreComponents exposes the five normalized contributions to Circle scoring.
type CircleScoreComponents struct{ ParticipantBreadth, RelationshipStrength, RecencyVelocity, QualityPresentation, InterestMatch float64 }

// CircleRankedCandidate retains a Circle candidate, final score, and component
// diagnostics.
type CircleRankedCandidate struct {
	Candidate  CircleRankCandidate
	Score      float64
	Components CircleScoreComponents
}

// CircleRankingDiagnostics counts missing eligible participants and invalid candidate
// inputs.
type CircleRankingDiagnostics struct{ CandidateCount, EligibleCount, RejectedWithoutEligibleParticipants, RejectedForInvalidInput int }

// CircleRankingResult returns ordered Circle candidates and rejection diagnostics.
type CircleRankingResult struct {
	Items       []CircleRankedCandidate
	Diagnostics CircleRankingDiagnostics
}

// CircleRankingConfig sets participant breadth target and signal recency/age thresholds in
// seconds.
type CircleRankingConfig struct {
	ParticipantBreadthTarget          int
	RecencyHalfLife, MaximumSignalAge float64
}

// DefaultCircleRankingConfig uses eight participants, a twelve-participantsLastHour half-life, and a
// seven-participantsLastDay signal window.
func DefaultCircleRankingConfig() CircleRankingConfig { return CircleRankingConfig{8, 43200, 604800} }

// Validate rejects values that violate this type’s documented bounds before they are used.
func (config CircleRankingConfig) Validate() error {
	if config.ParticipantBreadthTarget <= 0 || !finite(config.RecencyHalfLife) || config.RecencyHalfLife <= 0 || !finite(config.MaximumSignalAge) || config.MaximumSignalAge <= 0 {
		return errors.New("invalid circle ranking threshold")
	}
	return nil
}

// RankCircle deduplicates participants, ignores future/expired signals, and ranks finite
// candidates deterministically.
func RankCircle(candidates []CircleRankCandidate, asOf time.Time, config CircleRankingConfig) (CircleRankingResult, error) {
	if err := config.Validate(); err != nil {
		return CircleRankingResult{}, err
	}
	rankingResult := CircleRankingResult{Items: []CircleRankedCandidate{}, Diagnostics: CircleRankingDiagnostics{CandidateCount: len(candidates)}}
	type participant struct {
		weight float64
		latest time.Time
	}
	for _, candidate := range candidates {
		key := strings.TrimSpace(candidate.CanonicalKey)
		if key == "" || len(key) > 160 || !finite(candidate.Quality) || !finite(candidate.Presentation) || !finite(candidate.InterestMatch) {
			rankingResult.Diagnostics.RejectedForInvalidInput++
			continue
		}
		participants := map[string]participant{}
		for _, participantSignal := range candidate.ParticipantSignals {
			age := asOf.Sub(participantSignal.OccurredAt).Seconds()
			if age < 0 || age > config.MaximumSignalAge {
				continue
			}
			key := strings.TrimSpace(participantSignal.ParticipantKey)
			if key == "" {
				continue
			}
			participantEvidence, ok := participants[key]
			if !ok {
				participants[key] = participant{participantSignal.Relationship.Weight(), participantSignal.OccurredAt}
			} else {
				participantEvidence.weight = max(participantEvidence.weight, participantSignal.Relationship.Weight())
				if participantSignal.OccurredAt.After(participantEvidence.latest) {
					participantEvidence.latest = participantSignal.OccurredAt
				}
				participants[key] = participantEvidence
			}
		}
		if len(participants) == 0 {
			rankingResult.Diagnostics.RejectedWithoutEligibleParticipants++
			continue
		}
		keys := make([]string, 0, len(participants))
		for key := range participants {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		relationship := 0.0
		var latest time.Time
		participantsLastHour, participantsLastDay := 0, 0
		for _, key := range keys {
			participantEvidence := participants[key]
			relationship += participantEvidence.weight
			if participantEvidence.latest.After(latest) {
				latest = participantEvidence.latest
			}
			age := asOf.Sub(participantEvidence.latest).Seconds()
			if age <= 3600 {
				participantsLastHour++
			}
			if age <= 86400 {
				participantsLastDay++
			}
		}
		recency := math.Pow(.5, max(0, asOf.Sub(latest).Seconds())/config.RecencyHalfLife)
		velocity := clamp(float64(participantsLastHour) / (max(1, float64(participantsLastDay)/24) * 4))
		components := CircleScoreComponents{logarithmicRatio(len(participants), config.ParticipantBreadthTarget), clamp(relationship / float64(len(participants))), clamp((recency + velocity) / 2), clamp((candidate.Quality + candidate.Presentation) / 2), clamp(candidate.InterestMatch)}
		score := components.ParticipantBreadth*.35 + components.RelationshipStrength*.25 + components.RecencyVelocity*.20 + components.QualityPresentation*.10 + components.InterestMatch*.10
		rankingResult.Items = append(rankingResult.Items, CircleRankedCandidate{candidate, score, components})
	}
	sort.SliceStable(rankingResult.Items, func(itemIndex, comparisonIndex int) bool {
		leftCandidate, rightCandidate := rankingResult.Items[itemIndex], rankingResult.Items[comparisonIndex]
		if leftCandidate.Score != rightCandidate.Score {
			return leftCandidate.Score > rightCandidate.Score
		}
		return leftCandidate.Candidate.CanonicalKey < rightCandidate.Candidate.CanonicalKey
	})
	rankingResult.Diagnostics.EligibleCount = len(rankingResult.Items)
	return rankingResult, nil
}
