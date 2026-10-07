package topicreadcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"time"
)

type SportsAvailability struct {
	Enabled       bool                `json:"enabled"`
	Available     bool                `json:"available"`
	EventsEnabled bool                `json:"eventsEnabled"`
	Feeds         []SportsDefinition  `json:"feeds"`
	Entities      []sportscore.Entity `json:"entities"`
	Version       string              `json:"version"`
}
type SportsItem struct {
	Story          wirecore.FeedItem        `json:"story"`
	Entities       []sportscore.Entity      `json:"entities"`
	Associations   []sportscore.Association `json:"associations"`
	Materiality    string                   `json:"materiality"`
	MajorGlobal    bool                     `json:"majorGlobal"`
	SportIDs       []string                 `json:"sportIDs"`
	CompetitionIDs []string                 `json:"competitionIDs"`
}
type SportsPage struct {
	FeedID             string       `json:"feedId"`
	GenerationID       string       `json:"generationId"`
	GeneratedAt        time.Time    `json:"generatedAt"`
	ExpiresAt          time.Time    `json:"expiresAt"`
	Language           string       `json:"language"`
	PreferenceRevision string       `json:"preferenceRevision"`
	Cursor             *string      `json:"cursor,omitempty"`
	Source             string       `json:"source"`
	EventsEnabled      bool         `json:"eventsEnabled"`
	Degraded           bool         `json:"degraded"`
	Items              []SportsItem `json:"items"`
}
