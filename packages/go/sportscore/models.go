// Package sportscore implements repository-local Sports ranking and identity contracts.
package sportscore

// Defines supplied catalog entities, follows/mutes, resolver evidence, and ranking
// candidates. The resolver-version constant gates accepted evidence; this package does not
// yet generate that evidence or supply a reviewed catalog.

import "github.com/stygian-tech/the-social-wire/packages/go/wirecore"

const ResolverVersion = "sports-resolver-v14"

// Entity is a supplied catalog identity with hierarchy, provider aliases, and membership
// evidence.
type Entity struct {
	ID             string            `json:"id"`
	Name           string            `json:"name"`
	Kind           string            `json:"kind"`
	SchoolID       *string           `json:"schoolID,omitempty"`
	Gender         *string           `json:"gender,omitempty"`
	Division       *string           `json:"division,omitempty"`
	SportID        *string           `json:"sportID,omitempty"`
	CompetitionIDs []string          `json:"competitionIDs"`
	Aliases        []string          `json:"aliases"`
	ProviderIDs    map[string]string `json:"providerIDs"`
	Abbreviation   *string           `json:"abbreviation,omitempty"`
	Memberships    []Membership      `json:"memberships,omitempty"`
	GroupPath      []string          `json:"groupPath,omitempty"`
	Active         bool              `json:"active"`
}

// Selection records a follow or mute of one entity reference.
type Selection struct {
	Reference string `json:"reference"`
	Action    string `json:"action"`
}

// Association records resolver confidence, prominence, provenance evidence, and the
// resolver version for one associated entity.
type Association struct {
	EntityID        string   `json:"entityID"`
	Confidence      float64  `json:"confidence"`
	Evidence        []string `json:"evidence"`
	Prominence      int      `json:"prominence"`
	ResolverVersion string   `json:"resolverVersion"`
}

// ArticleAnalysis is supplied resolver evidence used to admit and personalize an article;
// ranking does not create this evidence.
type ArticleAnalysis struct {
	ResolverVersion string        `json:"resolverVersion"`
	Eligible        bool          `json:"eligible"`
	Materiality     string        `json:"materiality"`
	Associations    []Association `json:"associations"`
	SportIDs        []string      `json:"sportIDs"`
	CompetitionIDs  []string      `json:"competitionIDs"`
}

// RankCandidate pairs a serving item with analysis, an unpersonalized base score, and
// global-reserve eligibility.
type RankCandidate struct {
	Item        wirecore.FeedItem `json:"item"`
	Analysis    ArticleAnalysis   `json:"analysis"`
	BaseScore   float64           `json:"baseScore"`
	MajorGlobal bool              `json:"majorGlobal"`
}
