package topicreadcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"time"
)

type FinanceAvailability struct {
	Enabled        bool                `json:"enabled"`
	Available      bool                `json:"available"`
	WidgetsEnabled bool                `json:"widgetsEnabled"`
	Feeds          []FinanceDefinition `json:"feeds"`
}
type FinanceMatchedInstrument struct {
	Instrument      financecore.Instrument `json:"instrument"`
	ConfidenceBPS   int                    `json:"confidenceBps"`
	Prominence      int                    `json:"prominence"`
	Evidence        []string               `json:"evidence"`
	ResolverVersion string                 `json:"resolverVersion"`
}
type FinanceItem struct {
	Story       wirecore.FeedItem          `json:"story"`
	Instruments []FinanceMatchedInstrument `json:"instruments"`
	MacroTopics []string                   `json:"macroTopics"`
	SectorIDs   []string                   `json:"sectorIDs"`
	MajorGlobal bool                       `json:"majorGlobal"`
	Materiality string                     `json:"materiality"`
}
type FinancePage struct {
	FeedID             string        `json:"feedId"`
	GenerationID       string        `json:"generationId"`
	GeneratedAt        time.Time     `json:"generatedAt"`
	ExpiresAt          time.Time     `json:"expiresAt"`
	Language           string        `json:"language"`
	PreferenceRevision string        `json:"preferenceRevision"`
	Cursor             *string       `json:"cursor,omitempty"`
	Source             string        `json:"source"`
	WidgetsEnabled     bool          `json:"widgetsEnabled"`
	Degraded           bool          `json:"degraded"`
	Items              []FinanceItem `json:"items"`
}
