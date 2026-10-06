package wirecore

import (
	"errors"
	"math"
	"strings"
	"testing"
	"time"
)

func pointer[T any](v T) *T { return &v }
func TestRankingAdmissionAndBoundaries(t *testing.T) {
	now := time.Unix(1800000000, 0)
	c := NewCandidate("a", "https://a.example/story", "a.example", now)
	c.SourceConfidence = .75
	c.IsStandardSite = pointer(true)
	c.HasUsableThumbnail = pointer(true)
	c.Shares24h = 1
	r, e := Rank([]Candidate{c}, now, DefaultRankingConfig())
	if e != nil || len(r.Items) != 1 || r.Items[0].ReasonCodes[0] != WidelyDiscussed {
		t.Fatalf("fresh single-share publication: %+v %v", r, e)
	}
	c.FirstSeenAt = now.Add(-72*time.Hour - time.Second)
	r, e = Rank([]Candidate{c}, now, DefaultRankingConfig())
	if e != nil || len(r.Items) != 0 || r.Diagnostics.RejectedForSignalFloor != 1 {
		t.Fatalf("old single-share publication admitted: %+v %v", r, e)
	}
	c.Shares24h = 5
	c.FirstSeenAt = now.Add(-ItemRetention)
	r, e = Rank([]Candidate{c}, now, DefaultRankingConfig())
	if e != nil || len(r.Items) != 1 {
		t.Fatal("inclusive age ceiling rejected", e)
	}
	c.FirstSeenAt = c.FirstSeenAt.Add(-time.Second)
	r, _ = Rank([]Candidate{c}, now, DefaultRankingConfig())
	if r.Diagnostics.RejectedForAge != 1 {
		t.Fatal("expired item admitted")
	}
}
func TestInvalidConfigAndNonfiniteQuality(t *testing.T) {
	c := DefaultRankingConfig()
	c.Weights.Freshness = math.NaN()
	if !errors.Is(c.Validate(), ErrInvalidWeight) {
		t.Fatal("NaN weight accepted")
	}
	c = DefaultRankingConfig()
	c.Weights = RankingWeights{}
	if !errors.Is(c.Validate(), ErrZeroWeightTotal) {
		t.Fatal("zero weight total accepted")
	}
	candidate := NewCandidate("a", "https://a.example", "a.example", time.Now())
	candidate.SourceConfidence = math.Inf(1)
	r, e := Rank([]Candidate{candidate}, time.Now(), DefaultRankingConfig())
	if e != nil || r.Diagnostics.RejectedForQuality != 1 {
		t.Fatal("non-finite confidence accepted")
	}
}
func TestCircleParticipantsAndViewerBoundCursor(t *testing.T) {
	now := time.Unix(1800000000, 0)
	r, e := RankCircle([]CircleRankCandidate{{CanonicalKey: "a", Quality: 1, Presentation: 1, InterestMatch: 1, ParticipantSignals: []CircleParticipantSignal{{"person", CircleRelationship{Direct: true}, now}, {"person", CircleRelationship{PathCount: 1}, now}, {"future", CircleRelationship{Direct: true}, now.Add(time.Second)}}}}, now, DefaultCircleRankingConfig())
	if e != nil || len(r.Items) != 1 {
		t.Fatal(e)
	}
	if r.Items[0].Components.RelationshipStrength != 1 {
		t.Fatal("duplicate signal weakened participant")
	}
	codec, e := NewCircleCursorCodec([]byte(strings.Repeat("s", 32)))
	if e != nil {
		t.Fatal(e)
	}
	cursor := CircleCursor{"snapshot", "generation", "und", 0, now.Add(time.Minute)}
	value, e := codec.Encode(cursor, "did:plc:a")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = codec.Decode(value, "did:plc:b", now); !errors.Is(e, ErrViewerMismatch) {
		t.Fatal("viewer cursor isolation failed", e)
	}
	if _, e = codec.Decode(value, "did:plc:a", cursor.ExpiresAt); !errors.Is(e, ErrCursorExpired) {
		t.Fatal("expired cursor accepted", e)
	}
	if _, e = codec.Decode(value+"x", "did:plc:a", now); e == nil {
		t.Fatal("tampered cursor accepted")
	}
}
func TestActorHashNormalizationAndSecretCopy(t *testing.T) {
	secret := []byte(strings.Repeat("s", 32))
	h, e := NewActorHasher(secret)
	if e != nil {
		t.Fatal(e)
	}
	a, _ := h.Hash(" DID:PLC:ABC ")
	secret[0] = 'x'
	b, _ := h.Hash("did:plc:abc")
	if a != b || !strings.HasPrefix(a, "h1:") {
		t.Fatal("unstable actor identity")
	}
	if _, e = h.Hash(" "); e == nil {
		t.Fatal("empty actor accepted")
	}
}
