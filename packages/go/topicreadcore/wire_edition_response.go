package topicreadcore

import (
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"time"
)

type Publication struct {
	Name           string  `json:"name"`
	Domain         string  `json:"domain"`
	Publication    *string `json:"publication,omitempty"`
	PublicationKey string  `json:"publicationKey"`
	HomepageURL    *string `json:"homepageUrl,omitempty"`
	IconURL        *string `json:"iconUrl,omitempty"`
}
type PublicationSpotlight struct {
	ID          string      `json:"id"`
	Publication Publication `json:"publication"`
	StoryIDs    []string    `json:"storyIds"`
}
type StoryRail struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	StoryIDs []string `json:"storyIds"`
}
type Person struct {
	DID         string  `json:"did"`
	Handle      string  `json:"handle"`
	DisplayName string  `json:"displayName"`
	AvatarURL   *string `json:"avatarUrl,omitempty"`
	Description *string `json:"description,omitempty"`
}
type WireEditionResponse struct {
	EditionVersion        string                 `json:"editionVersion"`
	GenerationID          string                 `json:"generationId"`
	GeneratedAt           time.Time              `json:"generatedAt"`
	Language              string                 `json:"language"`
	Source                string                 `json:"source"`
	Degraded              bool                   `json:"degraded"`
	Stories               []wirecore.FeedItem    `json:"stories"`
	TopStoryIDs           []string               `json:"topStoryIds"`
	PublicationSpotlights []PublicationSpotlight `json:"publicationSpotlights"`
	StoryRails            []StoryRail            `json:"storyRails"`
	People                []Person               `json:"people"`
	TrendingStoryIDs      []string               `json:"trendingStoryIds"`
	MoreCursor            *string                `json:"moreCursor,omitempty"`
}

func EditionResponse(e wirecore.Edition) WireEditionResponse {
	r := WireEditionResponse{EditionVersion: e.AlgorithmVersion, GenerationID: e.GenerationID, GeneratedAt: e.GeneratedAt, Language: e.Language, Source: e.Source, Degraded: e.Degraded, Stories: []wirecore.FeedItem{}, PublicationSpotlights: []PublicationSpotlight{}, StoryRails: []StoryRail{}, People: []Person{}, MoreCursor: e.Cursor}
	seen := map[string]bool{}
	appendStories := func(items []wirecore.FeedItem) {
		for _, item := range items {
			if !seen[item.ItemID] {
				seen[item.ItemID] = true
				r.Stories = append(r.Stories, item)
			}
		}
	}
	ids := func(items []wirecore.FeedItem, unique bool) []string {
		result := []string{}
		seen := map[string]bool{}
		for _, item := range items {
			if !unique || !seen[item.ItemID] {
				result = append(result, item.ItemID)
				seen[item.ItemID] = true
			}
		}
		return result
	}
	appendStories(e.LeadStories)
	r.TopStoryIDs = ids(e.LeadStories, false)
	for _, p := range e.PublicationPanels {
		appendStories(p.Stories)
		r.PublicationSpotlights = append(r.PublicationSpotlights, PublicationSpotlight{p.Publication.Key, Publication{p.Publication.Name, p.Publication.Domain, p.Publication.ID, p.Publication.Key, p.Publication.HomepageURL, p.Publication.IconURL}, ids(p.Stories, false)})
	}
	for _, rail := range e.StoryRails {
		appendStories(rail.Stories)
		r.StoryRails = append(r.StoryRails, StoryRail{rail.ID, rail.Title, ids(rail.Stories, true)})
	}
	appendStories(e.GeneralStories)
	if general := ids(e.GeneralStories, true); len(general) > 0 {
		r.StoryRails = append(r.StoryRails, StoryRail{"more-across-the-social-web", "More Across the Social Web", general})
	}
	appendStories(e.TrendingStories)
	r.TrendingStoryIDs = ids(e.TrendingStories, false)
	for _, a := range e.TalkedAboutAccounts {
		handle := a.DID
		if a.Handle != nil {
			handle = *a.Handle
		}
		name := handle
		if a.DisplayName != nil {
			name = *a.DisplayName
		}
		r.People = append(r.People, Person{a.DID, handle, name, a.AvatarURL, a.Description})
	}
	return r
}
