// Package wirecore implements the shared Wire and Circle data policies and ranking contracts.
package wirecore

import "time"

type TargetKind string

const (
	ExternalArticle      TargetKind = "external_article"
	StandardSiteDocument TargetKind = "standard_site_document"
	SocialPost           TargetKind = "social_post"
	ProfileOrFeed        TargetKind = "profile_or_feed"
	CommerceOrAd         TargetKind = "commerce_or_ad"
	OperationalStatus    TargetKind = "operational_status"
	Unsupported          TargetKind = "unsupported"
)

func (k TargetKind) CanCreateItem() bool { return k == ExternalArticle || k == StandardSiteDocument }

type CommercialClass string

const (
	Normal     CommercialClass = "normal"
	Limited    CommercialClass = "limited"
	ProbableAd CommercialClass = "probable_ad"
)

type Candidate struct {
	CanonicalKey               string          `json:"canonicalKey"`
	CanonicalURL               string          `json:"canonicalURL"`
	RepresentativeURI          *string         `json:"representativeURI,omitempty"`
	SourceDomain               string          `json:"sourceDomain"`
	PublicationID              *string         `json:"publicationID,omitempty"`
	AuthorKey                  *string         `json:"authorKey,omitempty"`
	TopicKeys                  []string        `json:"topicKeys"`
	PublishedAt                *time.Time      `json:"publishedAt,omitempty"`
	FirstSeenAt                time.Time       `json:"firstSeenAt"`
	LastSignalAt               *time.Time      `json:"lastSignalAt,omitempty"`
	DistinctActors1h           int             `json:"distinctActors1h"`
	DistinctActors24h          int             `json:"distinctActors24h"`
	DistinctActors7d           int             `json:"distinctActors7d"`
	Signals1h                  int             `json:"signals1h"`
	Signals24h                 int             `json:"signals24h"`
	Signals7d                  int             `json:"signals7d"`
	Communities24h             int             `json:"communities24h"`
	PrimaryCommunityKey        *string         `json:"primaryCommunityKey,omitempty"`
	Recommendations24h         int             `json:"recommendations24h"`
	PositiveFeedback24h        int             `json:"positiveFeedback24h"`
	NegativeFeedback24h        int             `json:"negativeFeedback24h"`
	Shares1h                   int             `json:"shares1h"`
	Shares24h                  int             `json:"shares24h"`
	DistinctLikes24h           int             `json:"distinctLikes24h"`
	Likes1h                    int             `json:"likes1h"`
	Likes24h                   int             `json:"likes24h"`
	DistinctReposts24h         int             `json:"distinctReposts24h"`
	Reposts1h                  int             `json:"reposts1h"`
	Reposts24h                 int             `json:"reposts24h"`
	SourceConfidence           float64         `json:"sourceConfidence"`
	IsStandardSite             *bool           `json:"isStandardSite,omitempty"`
	HasUsableOpenGraphMetadata *bool           `json:"hasUsableOpenGraphMetadata,omitempty"`
	HasUsableThumbnail         *bool           `json:"hasUsableThumbnail,omitempty"`
	TargetKind                 TargetKind      `json:"targetKind"`
	CommercialClass            CommercialClass `json:"commercialClass"`
	CommercialScore            float64         `json:"commercialScore"`
}

func NewCandidate(key, url, domain string, firstSeen time.Time) Candidate {
	return Candidate{CanonicalKey: key, CanonicalURL: url, SourceDomain: domain, FirstSeenAt: firstSeen,
		TopicKeys: []string{}, SourceConfidence: 0.5, TargetKind: ExternalArticle, CommercialClass: Normal}
}
func (c Candidate) Age(asOf time.Time) float64 {
	date := c.FirstSeenAt
	if c.PublishedAt != nil {
		date = *c.PublishedAt
	}
	return max(0, asOf.Sub(date).Seconds())
}
func enabled(v *bool) bool { return v != nil && *v }

type ReasonCode string

const (
	BreakingStory           ReasonCode = "breaking_story"
	FreshPublication        ReasonCode = "fresh_publication"
	Resurfacing             ReasonCode = "resurfacing"
	SharedAcrossCommunities ReasonCode = "shared_across_communities"
	WidelyDiscussed         ReasonCode = "widely_discussed"
)

type ScoredCandidate struct {
	Candidate   Candidate    `json:"candidate"`
	Score       float64      `json:"score"`
	ReasonCodes []ReasonCode `json:"reasonCodes"`
}
type RankingDiagnostics struct {
	CandidateCount         int `json:"candidateCount"`
	EligibleCount          int `json:"eligibleCount"`
	RejectedForAge         int `json:"rejectedForAge"`
	RejectedForQuality     int `json:"rejectedForQuality"`
	RejectedForSignalFloor int `json:"rejectedForSignalFloor"`
	QualityBackfillCount   int `json:"qualityBackfillCount"`
	GeneralBackfillCount   int `json:"generalBackfillCount"`
	DiversityDeferrals     int `json:"diversityDeferrals"`
}
type RankingResult struct {
	Items       []ScoredCandidate  `json:"items"`
	Diagnostics RankingDiagnostics `json:"diagnostics"`
}
