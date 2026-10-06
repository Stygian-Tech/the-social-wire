package wirecore

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
)

const EditionVersion = "wire-edition-v2"

type ItemSource struct {
	Name           string  `json:"name"`
	Domain         string  `json:"domain"`
	Publication    *string `json:"publication,omitempty"`
	Author         *string `json:"author,omitempty"`
	PublicationKey *string `json:"publicationKey,omitempty"`
	HomepageURL    *string `json:"homepageUrl,omitempty"`
	IconURL        *string `json:"iconUrl,omitempty"`
}
type FeedItem struct {
	ItemID            string       `json:"itemId"`
	CanonicalURL      string       `json:"canonicalUrl"`
	RepresentativeURI *string      `json:"representativeUri,omitempty"`
	Title             string       `json:"title"`
	Summary           *string      `json:"summary,omitempty"`
	PublishedAt       *time.Time   `json:"publishedAt,omitempty"`
	ThumbnailURL      *string      `json:"thumbnailUrl,omitempty"`
	Source            ItemSource   `json:"source"`
	Reasons           []ReasonCode `json:"reasons"`
	Provenance        []string     `json:"provenance"`
}

func (f *FeedItem) UnmarshalJSON(data []byte) error {
	type raw FeedItem
	var value raw
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*f = FeedItem(value)
	f.Reasons = append([]ReasonCode{}, f.Reasons[:min(2, len(f.Reasons))]...)
	f.Provenance = append([]string{}, f.Provenance[:min(8, len(f.Provenance))]...)
	return nil
}

type EditionPublication struct {
	Key         string  `json:"key"`
	ID          *string `json:"id,omitempty"`
	Name        string  `json:"name"`
	Domain      string  `json:"domain"`
	HomepageURL *string `json:"homepageUrl,omitempty"`
	IconURL     *string `json:"iconUrl,omitempty"`
}
type PublicationPanel struct {
	Publication EditionPublication `json:"publication"`
	Stories     []FeedItem         `json:"stories"`
}
type StoryRail struct {
	ID      string     `json:"id"`
	Title   string     `json:"title"`
	Reason  ReasonCode `json:"reason"`
	Stories []FeedItem `json:"stories"`
}
type TalkedAboutAccount struct {
	DID         string  `json:"did"`
	Handle      *string `json:"handle,omitempty"`
	DisplayName *string `json:"displayName,omitempty"`
	AvatarURL   *string `json:"avatarUrl,omitempty"`
	Description *string `json:"description,omitempty"`
}
type TalkedAboutAccountCandidate struct {
	Account              TalkedAboutAccount `json:"account"`
	DistinctStoryCount   int                `json:"distinctStoryCount"`
	DistinctSpeakerCount int                `json:"distinctSpeakerCount"`
	BestStoryRank        int                `json:"bestStoryRank"`
	LatestMentionAt      *time.Time         `json:"latestMentionAt,omitempty"`
}
type Edition struct {
	AlgorithmVersion    string               `json:"algorithmVersion"`
	GenerationID        string               `json:"generationId"`
	GeneratedAt         time.Time            `json:"generatedAt"`
	Language            string               `json:"language"`
	Cursor              *string              `json:"cursor,omitempty"`
	Source              string               `json:"source"`
	Degraded            bool                 `json:"degraded"`
	LeadStories         []FeedItem           `json:"leadStories"`
	PublicationPanels   []PublicationPanel   `json:"publicationPanels"`
	StoryRails          []StoryRail          `json:"storyRails"`
	GeneralStories      []FeedItem           `json:"generalStories"`
	TrendingStories     []FeedItem           `json:"trendingStories"`
	TalkedAboutAccounts []TalkedAboutAccount `json:"talkedAboutAccounts"`
}

func normalized(value string) string { return strings.ToLower(strings.TrimSpace(value)) }
func hasReason(item FeedItem, reasons ...ReasonCode) bool {
	for _, r := range item.Reasons {
		for _, wanted := range reasons {
			if r == wanted {
				return true
			}
		}
	}
	return false
}
func directStandardStory(item FeedItem) bool {
	if item.RepresentativeURI == nil {
		return false
	}
	uri := strings.ToLower(*item.RepresentativeURI)
	return strings.Contains(uri, "/site.standard.document/") || strings.Contains(uri, "/site.standard.entry/")
}
func publicationKey(item FeedItem) string {
	if item.Source.PublicationKey != nil && normalized(*item.Source.PublicationKey) != "" {
		return normalized(*item.Source.PublicationKey)
	}
	if item.Source.Publication != nil && normalized(*item.Source.Publication) != "" {
		return "publication:" + normalized(*item.Source.Publication)
	}
	return "domain:" + normalized(item.Source.Domain)
}
func AssembleEdition(generation string, at time.Time, language string, cursor *string, source string, degraded bool, ranked []FeedItem, accounts []TalkedAboutAccountCandidate) Edition {
	result := Edition{AlgorithmVersion: EditionVersion, GenerationID: generation, GeneratedAt: at, Language: language, Cursor: cursor, Source: source, Degraded: degraded, LeadStories: []FeedItem{}, PublicationPanels: []PublicationPanel{}, StoryRails: []StoryRail{}, GeneralStories: []FeedItem{}, TrendingStories: []FeedItem{}, TalkedAboutAccounts: []TalkedAboutAccount{}}
	seen, domains, allocated := map[string]bool{}, map[string]bool{}, map[string]bool{}
	stories := []FeedItem{}
	for _, story := range ranked {
		if !seen[story.ItemID] {
			seen[story.ItemID] = true
			stories = append(stories, story)
		}
	}
	for _, story := range stories {
		domain := normalized(story.Source.Domain)
		if domains[domain] {
			continue
		}
		domains[domain] = true
		result.LeadStories = append(result.LeadStories, story)
		if len(result.LeadStories) == 4 {
			break
		}
	}
	hasStandard := false
	for _, story := range result.LeadStories {
		hasStandard = hasStandard || directStandardStory(story)
	}
	if len(result.LeadStories) == 4 && !hasStandard {
		for _, story := range stories[:min(10, len(stories))] {
			if !directStandardStory(story) {
				continue
			}
			conflict := false
			for i, lead := range result.LeadStories {
				if lead.ItemID == story.ItemID || i < 3 && normalized(lead.Source.Domain) == normalized(story.Source.Domain) {
					conflict = true
				}
			}
			if !conflict {
				result.LeadStories[3] = story
				break
			}
		}
	}
	for _, story := range result.LeadStories {
		allocated[story.ItemID] = true
	}
	groups := map[string][]FeedItem{}
	keys := []string{}
	for _, story := range stories {
		if allocated[story.ItemID] {
			continue
		}
		key := publicationKey(story)
		if groups[key] == nil {
			keys = append(keys, key)
		}
		groups[key] = append(groups[key], story)
	}
	for _, key := range keys {
		group := groups[key]
		if len(group) < 2 {
			continue
		}
		selected := group[:min(3, len(group))]
		s := selected[0].Source
		result.PublicationPanels = append(result.PublicationPanels, PublicationPanel{EditionPublication{key, s.Publication, s.Name, s.Domain, s.HomepageURL, s.IconURL}, selected})
		for _, story := range selected {
			allocated[story.ItemID] = true
		}
		if len(result.PublicationPanels) == 6 {
			break
		}
	}
	for _, rail := range []struct {
		id, title string
		reason    ReasonCode
		matches   []ReasonCode
	}{{"breaking-developing", "Breaking & Developing", BreakingStory, []ReasonCode{BreakingStory, WidelyDiscussed}}, {"across-communities", "Across Communities", SharedAcrossCommunities, []ReasonCode{SharedAcrossCommunities}}, {"resurfacing", "Resurfacing", Resurfacing, []ReasonCode{Resurfacing}}} {
		selected := []FeedItem{}
		for _, story := range stories {
			if !allocated[story.ItemID] && hasReason(story, rail.matches...) {
				selected = append(selected, story)
			}
		}
		if len(selected) < 4 {
			continue
		}
		selected = selected[:min(10, len(selected))]
		result.StoryRails = append(result.StoryRails, StoryRail{rail.id, rail.title, rail.reason, selected})
		for _, story := range selected {
			allocated[story.ItemID] = true
		}
	}
	for _, story := range stories {
		if !allocated[story.ItemID] {
			result.GeneralStories = append(result.GeneralStories, story)
		}
		if hasReason(story, BreakingStory, WidelyDiscussed) {
			result.TrendingStories = append(result.TrendingStories, story)
		}
	}
	for _, story := range stories {
		if !hasReason(story, BreakingStory, WidelyDiscussed) {
			result.TrendingStories = append(result.TrendingStories, story)
		}
	}
	result.TrendingStories = result.TrendingStories[:min(10, len(result.TrendingStories))]
	precedes := func(a, b TalkedAboutAccountCandidate) bool {
		if a.DistinctStoryCount != b.DistinctStoryCount {
			return a.DistinctStoryCount > b.DistinctStoryCount
		}
		if a.DistinctSpeakerCount != b.DistinctSpeakerCount {
			return a.DistinctSpeakerCount > b.DistinctSpeakerCount
		}
		if a.BestStoryRank != b.BestStoryRank {
			return a.BestStoryRank < b.BestStoryRank
		}
		if a.LatestMentionAt == nil && b.LatestMentionAt != nil {
			return false
		}
		if a.LatestMentionAt != nil && b.LatestMentionAt == nil {
			return true
		}
		if a.LatestMentionAt != nil && !a.LatestMentionAt.Equal(*b.LatestMentionAt) {
			return a.LatestMentionAt.After(*b.LatestMentionAt)
		}
		return normalized(a.Account.DID) < normalized(b.Account.DID)
	}
	best := map[string]TalkedAboutAccountCandidate{}
	for _, a := range accounts {
		if a.DistinctStoryCount < 2 || a.DistinctSpeakerCount < 3 {
			continue
		}
		key := normalized(a.Account.DID)
		if b, ok := best[key]; !ok || precedes(a, b) {
			best[key] = a
		}
	}
	selected := []TalkedAboutAccountCandidate{}
	for _, a := range best {
		selected = append(selected, a)
	}
	sort.Slice(selected, func(i, j int) bool { return precedes(selected[i], selected[j]) })
	for _, a := range selected[:min(10, len(selected))] {
		result.TalkedAboutAccounts = append(result.TalkedAboutAccounts, a.Account)
	}
	return result
}
