// Package corpuscore provides presentation-only Wire, Finance and Sports serving.
package corpuscore

import (
	"context"
	"errors"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

var (
	ErrUnavailable           = errors.New("corpus unavailable")
	ErrContractMismatch      = errors.New("corpus contract mismatch")
	ErrModerationUnavailable = errors.New("corpus moderation unavailable")
	ErrCursorExpired         = errors.New("corpus cursor expired")
)

type Row struct {
	Ordinal        int               `json:"ordinal"`
	Item           wirecore.FeedItem `json:"item"`
	SourceActorKey *string           `json:"sourceActorKey,omitempty"`
}
type Page struct {
	GenerationID string    `json:"generationId"`
	GeneratedAt  time.Time `json:"generatedAt"`
	Language     string    `json:"language"`
	Source       string    `json:"source"`
	Degraded     bool      `json:"degraded"`
	Rows         []Row     `json:"rows"`
	Exhausted    bool      `json:"exhausted"`
}
type Edition struct {
	wirecore.Edition
	SourceActorKeysByItemID map[string]string `json:"sourceActorKeysByItemID,omitempty"`
	FallbackRows            []Row             `json:"fallbackRows,omitempty"`
}
type Item struct {
	Item           wirecore.FeedItem `json:"item"`
	SourceActorKey *string           `json:"sourceActorKey,omitempty"`
}
type Catalog struct {
	Available          bool       `json:"available"`
	SupportedLanguages []string   `json:"supportedLanguages"`
	LatestGenerationID *string    `json:"latestGenerationId,omitempty"`
	GeneratedAt        *time.Time `json:"generatedAt,omitempty"`
}
type SignalFact struct {
	ActorHash        string    `json:"actorHash"`
	Kind             string    `json:"kind"`
	SourceCollection string    `json:"sourceCollection"`
	SourceAction     string    `json:"sourceAction"`
	SourceURI        string    `json:"sourceURI"`
	OccurredAt       time.Time `json:"occurredAt"`
}
type CandidateStory struct {
	Item      wirecore.FeedItem `json:"item"`
	TopicKeys []string          `json:"topicKeys"`
	Facts     []SignalFact      `json:"facts"`
}
type CandidateRequest struct {
	ActorHashes []string  `json:"actorHashes"`
	Language    string    `json:"language"`
	Since       time.Time `json:"since"`
	Limit       int       `json:"limit"`
}
type CandidateResponse struct {
	GenerationID string           `json:"generationID"`
	GeneratedAt  time.Time        `json:"generatedAt"`
	Language     string           `json:"language"`
	Stories      []CandidateStory `json:"stories"`
	Exhausted    bool             `json:"exhausted"`
}
type FinanceGeneration struct {
	GenerationID string                      `json:"generationId"`
	GeneratedAt  time.Time                   `json:"generatedAt"`
	ExpiresAt    time.Time                   `json:"expiresAt"`
	Language     string                      `json:"language"`
	Source       *string                     `json:"source,omitempty"`
	Instruments  []financecore.Instrument    `json:"instruments"`
	Candidates   []financecore.RankCandidate `json:"candidates"`
}
type SportsGeneration struct {
	GenerationID string                     `json:"generationId"`
	GeneratedAt  time.Time                  `json:"generatedAt"`
	ExpiresAt    time.Time                  `json:"expiresAt"`
	Language     string                     `json:"language"`
	Source       *string                    `json:"source,omitempty"`
	Entities     []sportscore.Entity        `json:"entities"`
	Candidates   []sportscore.RankCandidate `json:"candidates"`
}
type ScheduleStatus struct {
	CompetitionID string    `json:"competitionID"`
	Status        string    `json:"status"`
	UpdatedAt     time.Time `json:"updatedAt"`
}
type FeedQuery struct {
	Language            string
	GenerationID        *string
	StartOrdinal, Limit int
	FallbackLimit       *int
}
type EditionQuery struct {
	Language      string
	Region        *string
	FallbackLimit *int
}
type EventsQuery struct {
	CompetitionIDs, EntityIDs []string
	Global                    bool
	TeamIDs                   []string
	PreferredIDs              []string
	TimeZone                  *time.Location
}

type Store interface {
	Ping(context.Context) error
	RequireFreshBaseline(context.Context, time.Time) error
	Feed(context.Context, FeedQuery, time.Time) (Page, error)
	Edition(context.Context, EditionQuery, time.Time) (Edition, error)
	Item(context.Context, string, time.Time) (*Item, error)
	Catalog(context.Context, time.Time) (Catalog, error)
	CircleCandidates(context.Context, CandidateRequest, time.Time) (CandidateResponse, error)
	Finance(context.Context, string, time.Time) (FinanceGeneration, error)
	Sports(context.Context, string, time.Time) (SportsGeneration, error)
	SportsSchedules(context.Context, time.Time) ([]ScheduleStatus, error)
	SportsStandings(context.Context, []string, time.Time) ([]sportscore.StandingSnapshot, error)
	SportsEvents(context.Context, EventsQuery, time.Time) ([]sportscore.Event, error)
}
