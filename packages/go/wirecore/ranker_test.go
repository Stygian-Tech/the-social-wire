package wirecore

import (
	"errors"
	"math"
	"strings"
	"testing"
	"time"
)

func pointer[T any](value T) *T { return &value }
func TestRankingAdmissionAndBoundaries(t *testing.T) {
	now := time.Unix(1800000000, 0)
	candidate := NewCandidate("a", "https://a.example/story", "a.example", now)
	candidate.SourceConfidence = .75
	candidate.IsStandardSite = pointer(true)
	candidate.HasUsableThumbnail = pointer(true)
	candidate.Shares24h = 1
	rankingResult, err := Rank([]Candidate{candidate}, now, DefaultRankingConfig())
	if err != nil || len(rankingResult.Items) != 1 || rankingResult.Items[0].ReasonCodes[0] != WidelyDiscussed {
		t.Fatalf("fresh single-share publication: %+v %v", rankingResult, err)
	}
	candidate.FirstSeenAt = now.Add(-72*time.Hour - time.Second)
	rankingResult, err = Rank([]Candidate{candidate}, now, DefaultRankingConfig())
	if err != nil || len(rankingResult.Items) != 0 || rankingResult.Diagnostics.RejectedForSignalFloor != 1 {
		t.Fatalf("old single-share publication admitted: %+v %v", rankingResult, err)
	}
	candidate.Shares24h = 5
	candidate.FirstSeenAt = now.Add(-ItemRetention)
	rankingResult, err = Rank([]Candidate{candidate}, now, DefaultRankingConfig())
	if err != nil || len(rankingResult.Items) != 1 {
		t.Fatal("inclusive age ceiling rejected", err)
	}
	candidate.FirstSeenAt = candidate.FirstSeenAt.Add(-time.Second)
	rankingResult, _ = Rank([]Candidate{candidate}, now, DefaultRankingConfig())
	if rankingResult.Diagnostics.RejectedForAge != 1 {
		t.Fatal("expired item admitted")
	}
}
func TestInvalidConfigAndNonfiniteQuality(t *testing.T) {
	config := DefaultRankingConfig()
	config.Weights.Freshness = math.NaN()
	if !errors.Is(config.Validate(), ErrInvalidWeight) {
		t.Fatal("NaN weight accepted")
	}
	config = DefaultRankingConfig()
	config.Weights = RankingWeights{}
	if !errors.Is(config.Validate(), ErrZeroWeightTotal) {
		t.Fatal("zero weight total accepted")
	}
	candidate := NewCandidate("a", "https://a.example", "a.example", time.Now())
	candidate.SourceConfidence = math.Inf(1)
	rankingResult, err := Rank([]Candidate{candidate}, time.Now(), DefaultRankingConfig())
	if err != nil || rankingResult.Diagnostics.RejectedForQuality != 1 {
		t.Fatal("non-finite confidence accepted")
	}
}
func TestCircleParticipantsAndViewerBoundCursor(t *testing.T) {
	now := time.Unix(1800000000, 0)
	rankingResult, err := RankCircle([]CircleRankCandidate{{CanonicalKey: "a", Quality: 1, Presentation: 1, InterestMatch: 1, ParticipantSignals: []CircleParticipantSignal{{"person", CircleRelationship{Direct: true}, now}, {"person", CircleRelationship{PathCount: 1}, now}, {"future", CircleRelationship{Direct: true}, now.Add(time.Second)}}}}, now, DefaultCircleRankingConfig())
	if err != nil || len(rankingResult.Items) != 1 {
		t.Fatal(err)
	}
	if rankingResult.Items[0].Components.RelationshipStrength != 1 {
		t.Fatal("duplicate signal weakened participant")
	}
	codec, err := NewCircleCursorCodec([]byte(strings.Repeat("s", 32)))
	if err != nil {
		t.Fatal(err)
	}
	cursor := CircleCursor{"snapshot", "generation", "und", 0, now.Add(time.Minute)}
	value, err := codec.Encode(cursor, "did:plc:a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = codec.Decode(value, "did:plc:b", now); !errors.Is(err, ErrViewerMismatch) {
		t.Fatal("viewer cursor isolation failed", err)
	}
	if _, err = codec.Decode(value, "did:plc:a", cursor.ExpiresAt); !errors.Is(err, ErrCursorExpired) {
		t.Fatal("expired cursor accepted", err)
	}
	if _, err = codec.Decode(value+"x", "did:plc:a", now); err == nil {
		t.Fatal("tampered cursor accepted")
	}
}
func TestActorHashNormalizationAndSecretCopy(t *testing.T) {
	secret := []byte(strings.Repeat("s", 32))
	hasher, err := NewActorHasher(secret)
	if err != nil {
		t.Fatal(err)
	}
	leftValue, _ := hasher.Hash(" DID:PLC:ABC ")
	secret[0] = 'x'
	rightValue, _ := hasher.Hash("did:plc:abc")
	if leftValue != rightValue || !strings.HasPrefix(leftValue, "h1:") {
		t.Fatal("unstable actor identity")
	}
	if _, err = hasher.Hash(" "); err == nil {
		t.Fatal("empty actor accepted")
	}
}
