package topicreadcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"time"
)

type CircleSharer struct {
	Identity     CircleIdentity `json:"identity"`
	Relationship string         `json:"relationship"`
	Action       string         `json:"action"`
	SourceURI    string         `json:"sourceUri"`
	Timestamp    time.Time      `json:"timestamp"`
}
type CircleStory struct {
	StoryID           string              `json:"storyId"`
	CanonicalURL      string              `json:"canonicalUrl"`
	RepresentativeURI *string             `json:"representativeUri,omitempty"`
	Title             string              `json:"title"`
	Summary           *string             `json:"summary,omitempty"`
	PublishedAt       *time.Time          `json:"publishedAt,omitempty"`
	ThumbnailURL      *string             `json:"thumbnailUrl,omitempty"`
	Source            wirecore.ItemSource `json:"source"`
	Reasons           []string            `json:"reasons"`
	DiscussionCount   int                 `json:"discussionCount"`
	SharerCount       int                 `json:"sharerCount"`
	Sharers           []CircleSharer      `json:"sharers"`
}
type CircleSpotlight struct {
	ID          string              `json:"id"`
	Publication wirecore.ItemSource `json:"publication"`
	StoryIDs    []string            `json:"storyIds"`
}
type CircleEdition struct {
	EditionVersion        string            `json:"editionVersion"`
	GenerationID          string            `json:"generationId"`
	GeneratedAt           time.Time         `json:"generatedAt"`
	Language              string            `json:"language"`
	Source                string            `json:"source"`
	Degraded              bool              `json:"degraded"`
	Stories               []CircleStory     `json:"stories"`
	TopStoryIDs           []string          `json:"topStoryIds"`
	PublicationSpotlights []CircleSpotlight `json:"publicationSpotlights"`
	StoryRails            []StoryRail       `json:"storyRails"`
	TrendingStoryIDs      []string          `json:"trendingStoryIds"`
	MoreCursor            *string           `json:"moreCursor,omitempty"`
}
