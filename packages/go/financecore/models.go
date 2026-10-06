// Package financecore implements repository-local Finance contracts and ranking.
package financecore

import "github.com/stygian-tech/the-social-wire/packages/go/wirecore"

const ResolverVersion = "finance-resolver-v3.4"

type Association struct {
	InstrumentID    string   `json:"instrumentID"`
	Confidence      float64  `json:"confidence"`
	Evidence        []string `json:"evidence"`
	Prominence      int      `json:"prominence"`
	ResolverVersion string   `json:"resolverVersion"`
}
type ArticleAnalysis struct {
	ResolverVersion *string       `json:"resolverVersion,omitempty"`
	Eligible        bool          `json:"eligible"`
	Materiality     string        `json:"materiality"`
	Associations    []Association `json:"associations"`
	MacroTopics     []string      `json:"macroTopics,omitempty"`
	SectorIDs       []string      `json:"sectorIDs"`
}
type RankCandidate struct {
	Item        wirecore.FeedItem `json:"item"`
	Analysis    ArticleAnalysis   `json:"analysis"`
	BaseScore   float64           `json:"baseScore"`
	MajorGlobal bool              `json:"majorGlobal"`
}
