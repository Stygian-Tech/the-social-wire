// Package financecore implements repository-local Finance contracts and ranking.
package financecore

// Defines the evidence and candidate shapes consumed by Finance ranking. These are
// analysis inputs, not an article resolver or a reviewed instrument catalog.

import "github.com/stygian-tech/the-social-wire/packages/go/wirecore"

const ResolverVersion = "finance-resolver-v3.4"

// Association records resolver confidence, prominence, provenance evidence, and the
// resolver version for one associated entity.
type Association struct {
	InstrumentID    string   `json:"instrumentID"`
	Confidence      float64  `json:"confidence"`
	Evidence        []string `json:"evidence"`
	Prominence      int      `json:"prominence"`
	ResolverVersion string   `json:"resolverVersion"`
}

// ArticleAnalysis is supplied resolver evidence used to admit and personalize an article;
// ranking does not create this evidence.
type ArticleAnalysis struct {
	ResolverVersion *string       `json:"resolverVersion,omitempty"`
	Eligible        bool          `json:"eligible"`
	Materiality     string        `json:"materiality"`
	Associations    []Association `json:"associations"`
	MacroTopics     []string      `json:"macroTopics,omitempty"`
	SectorIDs       []string      `json:"sectorIDs"`
}

// RankCandidate pairs a serving item with analysis, an unpersonalized base score, and
// global-reserve eligibility.
type RankCandidate struct {
	Item        wirecore.FeedItem `json:"item"`
	Analysis    ArticleAnalysis   `json:"analysis"`
	BaseScore   float64           `json:"baseScore"`
	MajorGlobal bool              `json:"majorGlobal"`
}
