// Package sportscore implements repository-local Sports ranking and identity contracts.
package sportscore

import "github.com/stygian-tech/the-social-wire/packages/go/wirecore"

const ResolverVersion = "sports-resolver-v14"

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
type Selection struct {
	Reference string `json:"reference"`
	Action    string `json:"action"`
}
type Association struct {
	EntityID        string   `json:"entityID"`
	Confidence      float64  `json:"confidence"`
	Evidence        []string `json:"evidence"`
	Prominence      int      `json:"prominence"`
	ResolverVersion string   `json:"resolverVersion"`
}
type ArticleAnalysis struct {
	ResolverVersion string        `json:"resolverVersion"`
	Eligible        bool          `json:"eligible"`
	Materiality     string        `json:"materiality"`
	Associations    []Association `json:"associations"`
	SportIDs        []string      `json:"sportIDs"`
	CompetitionIDs  []string      `json:"competitionIDs"`
}
type RankCandidate struct {
	Item        wirecore.FeedItem `json:"item"`
	Analysis    ArticleAnalysis   `json:"analysis"`
	BaseScore   float64           `json:"baseScore"`
	MajorGlobal bool              `json:"majorGlobal"`
}
